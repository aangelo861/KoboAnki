//! kanki: Anki on a Kobo. A small local HTTP server (127.0.0.1 only) that the KOReader plugin talks to.
//! See DESIGN.md for the API.

mod engine;
mod sync;

use std::fs;
use std::io::Read;
use std::net::TcpStream;
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::sync::Mutex;
use std::thread::JoinHandle;
use std::time::Duration;
use std::time::Instant;

use anki::error::AnkiError;
use anki::prelude::I18n;
use anki::progress::ProgressState;
use engine::Engine;
use kanki_html::PrepareOptions;
use serde_json::json;
use serde_json::Value;
use sync::StoredAuth;
use sync::SyncKind;
use sync::SyncStage;
use sync::SyncState;
use sync::SyncStatus;
use tiny_http::Header;
use tiny_http::Method;
use tiny_http::Request;
use tiny_http::Response;

const DEFAULT_PORT: u16 = 47321;
const IDLE_EXIT: Duration = Duration::from_secs(30 * 60);
const CACHE_MAX_BYTES: u64 = 300 * 1024 * 1024;
/// How often an idle server wakes up to check its parent is alive and whether it's been idle too long.
const WAKE_INTERVAL: Duration = Duration::from_secs(30);

struct App {
    data_dir: PathBuf,
    tr: I18n,
    progress: Arc<Mutex<ProgressState>>,
    /// None before the first download, and while a collection sync has it checked out.
    engine: Mutex<Option<Engine>>,
    sync: Mutex<SyncStatus>,
    sync_thread: Mutex<Option<JoinHandle<()>>>,
    auth: Mutex<Option<StoredAuth>>,
    shutdown: AtomicBool,
    /// KOReader's pid; the server exits when it disappears. Updated by POST /adopt.
    parent_pid: Mutex<Option<u32>>,
}

impl App {
    fn col_path(&self) -> PathBuf {
        self.data_dir.join("collection.anki2")
    }
    fn media_dir(&self) -> PathBuf {
        self.data_dir.join("collection.media")
    }
    fn cache_dir(&self) -> PathBuf {
        self.data_dir.join("cache")
    }
    fn auth_path(&self) -> PathBuf {
        self.data_dir.join("auth.json")
    }

    fn open_engine(&self) -> anki::error::Result<Engine> {
        let col = engine::open_collection(&self.col_path(), &self.tr, &self.progress)?;
        Ok(Engine::new(col, self.media_dir(), self.cache_dir()))
    }

    fn collection_sync_running(&self) -> bool {
        let s = self.sync.lock().unwrap();
        s.state == SyncState::Running && s.stage == Some(SyncStage::Collection)
    }
}

/// An error the UI can show: HTTP status, machine kind, human message.
struct ApiError(u16, &'static str, String);

impl ApiError {
    fn bad(msg: impl Into<String>) -> Self {
        ApiError(400, "bad_request", msg.into())
    }
}

type ApiResult = Result<(u16, Value), ApiError>;

fn anki_err(app: &App) -> impl Fn(AnkiError) -> ApiError + '_ {
    move |e| {
        let (kind, msg) = sync::describe_error(&e, &app.tr);
        let status = if kind == "auth" { 401 } else { 500 };
        eprintln!("[kanki] error ({kind}): {msg}");
        ApiError(status, kind, msg)
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("serve") => serve(&args[2..]),
        Some("version") => println!("kanki {} (anki {})", env!("CARGO_PKG_VERSION"), anki::version::version()),
        _ => {
            eprintln!("usage: kanki serve --data-dir DIR [--port N] [--parent-pid PID]\n       kanki version");
            std::process::exit(2);
        }
    }
}

fn arg_value(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1).cloned())
}

fn serve(args: &[String]) {
    close_inherited_fds();
    let data_dir = PathBuf::from(arg_value(args, "--data-dir").unwrap_or_else(|| {
        eprintln!("--data-dir is required");
        std::process::exit(2)
    }));
    let port: u16 = arg_value(args, "--port")
        .and_then(|p| p.parse().ok())
        .unwrap_or(DEFAULT_PORT);
    let parent_pid: Option<u32> = arg_value(args, "--parent-pid").and_then(|p| p.parse().ok());

    let listener = match bind_loopback(port) {
        Ok(l) => l,
        Err(e) => {
            if already_running(port) {
                eprintln!("[kanki] already running on port {port}");
                std::process::exit(3);
            }
            eprintln!("[kanki] cannot listen on 127.0.0.1:{port}: {e}");
            std::process::exit(1);
        }
    };
    let server = tiny_http::Server::from_listener(listener, None).unwrap_or_else(|e| {
        eprintln!("[kanki] cannot start http server: {e}");
        std::process::exit(1)
    });

    fs::create_dir_all(data_dir.join("collection.media")).expect("creating data dir");
    fs::create_dir_all(data_dir.join("cache")).expect("creating cache dir");

    // Fonts for the few image-occlusion masks that contain text labels (KOReader's own fonts on the Kobo),
    // and a cap on the flattened-image cache. Both in the background so the UI isn't kept waiting.
    let font_dir = arg_value(args, "--font-dir")
        .map(PathBuf::from)
        .unwrap_or_else(|| data_dir.join("../koreader/fonts"));
    let cache_dir = data_dir.join("cache");
    std::thread::spawn(move || {
        if font_dir.is_dir() {
            kanki_html::set_font_dirs(&[font_dir]);
        }
        let freed = kanki_html::prune_cache(&cache_dir, CACHE_MAX_BYTES);
        if freed > 0 {
            eprintln!("[kanki] pruned {} MB from the image cache", freed / 1_000_000);
        }
    });

    let app = Arc::new(App {
        tr: I18n::new(&["en"]),
        progress: Arc::new(Mutex::new(ProgressState {
            want_abort: false,
            last_progress: None,
        })),
        engine: Mutex::new(None),
        sync: Mutex::new(SyncStatus::default()),
        sync_thread: Mutex::new(None),
        auth: Mutex::new(StoredAuth::load(&data_dir.join("auth.json"))),
        shutdown: AtomicBool::new(false),
        parent_pid: Mutex::new(parent_pid),
        data_dir,
    });

    if app.col_path().exists() {
        match app.open_engine() {
            Ok(e) => *app.engine.lock().unwrap() = Some(e),
            Err(e) => eprintln!("[kanki] could not open collection: {e:?}"),
        }
    }
    eprintln!(
        "[kanki] {} listening on 127.0.0.1:{port}, data {}",
        env!("CARGO_PKG_VERSION"),
        app.data_dir.display()
    );

    let mut last_request = Instant::now();
    let mut last_parent_check = Instant::now();
    while !app.shutdown.load(Ordering::SeqCst) {
        // Blocks until a request arrives; wakes up on its own only every WAKE_INTERVAL for the
        // parent/idle checks, so an idle server costs (almost) no CPU wakeups on the Kobo.
        match server.recv_timeout(WAKE_INTERVAL) {
            Ok(Some(req)) => {
                last_request = Instant::now();
                handle(&app, req);
            }
            Ok(None) => {}
            Err(e) => eprintln!("[kanki] recv error: {e}"),
        }
        if last_parent_check.elapsed() >= WAKE_INTERVAL {
            last_parent_check = Instant::now();
            let parent = *app.parent_pid.lock().unwrap();
            if let Some(pid) = parent {
                let proc = PathBuf::from("/proc");
                if proc.exists() && !proc.join(pid.to_string()).exists() {
                    eprintln!("[kanki] parent {pid} gone, exiting");
                    break;
                }
            }
            let syncing = app.sync.lock().unwrap().state == SyncState::Running;
            if !syncing && last_request.elapsed() > IDLE_EXIT {
                eprintln!("[kanki] idle, exiting");
                break;
            }
        }
    }
    shutdown(&app);
}

/// KOReader starts us with its own files still open (some on /mnt/onboard). Close everything but
/// stdin/stdout/stderr so we never keep the user partition busy, e.g. when USB storage starts.
fn close_inherited_fds() {
    #[cfg(target_os = "linux")]
    {
        let Ok(dir) = fs::read_dir("/proc/self/fd") else { return };
        let fds: Vec<i32> = dir
            .flatten()
            .filter_map(|e| e.file_name().to_str()?.parse().ok())
            .filter(|&fd| fd > 2)
            .collect();
        for fd in fds {
            // includes the now-closed read_dir handle; EBADF there is harmless
            unsafe { libc::close(fd) };
        }
    }
}

/// Bind 127.0.0.1:port. Kobo firmware leaves the loopback interface down (Nickel never needs it), which
/// makes the bind fail with EADDRNOTAVAIL; in that case bring `lo` up (we run as root) and try again.
fn bind_loopback(port: u16) -> std::io::Result<std::net::TcpListener> {
    let addr = ("127.0.0.1", port);
    match std::net::TcpListener::bind(addr) {
        Err(e) if e.kind() == std::io::ErrorKind::AddrNotAvailable => {
            eprintln!("[kanki] loopback interface is down; bringing it up");
            if let Err(e) = bring_up_loopback() {
                eprintln!("[kanki] could not bring up loopback: {e}");
            }
            let mut last = e;
            for _ in 0..10 {
                match std::net::TcpListener::bind(addr) {
                    Ok(l) => return Ok(l),
                    Err(e) => last = e,
                }
                std::thread::sleep(Duration::from_millis(200));
            }
            Err(last)
        }
        other => other,
    }
}

#[cfg(target_os = "linux")]
fn bring_up_loopback() -> std::io::Result<()> {
    // SIOCSIFFLAGS IFF_UP on "lo"; the kernel then assigns 127.0.0.1/8 to it by itself.
    unsafe {
        let fd = libc::socket(libc::AF_INET, libc::SOCK_DGRAM, 0);
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        let mut ifr: libc::ifreq = std::mem::zeroed();
        for (i, b) in b"lo".iter().enumerate() {
            ifr.ifr_name[i] = *b as libc::c_char;
        }
        let mut result = Ok(());
        if libc::ioctl(fd, libc::SIOCGIFFLAGS as _, &mut ifr) < 0 {
            result = Err(std::io::Error::last_os_error());
        } else {
            ifr.ifr_ifru.ifru_flags |= (libc::IFF_UP | libc::IFF_RUNNING) as libc::c_short;
            if libc::ioctl(fd, libc::SIOCSIFFLAGS as _, &ifr) < 0 {
                result = Err(std::io::Error::last_os_error());
            }
        }
        libc::close(fd);
        if result.is_err() {
            // fall back to busybox, as KOReader's own wifi scripts use it
            if std::process::Command::new("ifconfig").args(["lo", "up"]).status().is_ok_and(|s| s.success()) {
                return Ok(());
            }
        }
        result
    }
}

#[cfg(not(target_os = "linux"))]
fn bring_up_loopback() -> std::io::Result<()> {
    Ok(())
}

fn already_running(port: u16) -> bool {
    // With loopback down a plain connect can hang for minutes, so always bound it.
    let addr = std::net::SocketAddr::from(([127, 0, 0, 1], port));
    let Ok(mut s) = TcpStream::connect_timeout(&addr, Duration::from_secs(1)) else { return false };
    let _ = s.set_write_timeout(Some(Duration::from_secs(2)));
    let _ = s.set_read_timeout(Some(Duration::from_secs(2)));
    use std::io::Write;
    if s.write_all(b"GET /status HTTP/1.0\r\nHost: localhost\r\n\r\n").is_err() {
        return false;
    }
    let mut buf = String::new();
    let _ = s.read_to_string(&mut buf);
    buf.contains("\"anki_version\"")
}

fn shutdown(app: &Arc<App>) {
    // Ask any running sync to stop, give it a moment, then close the collection cleanly.
    app.progress.lock().unwrap().want_abort = true;
    if let Some(handle) = app.sync_thread.lock().unwrap().take() {
        let deadline = Instant::now() + Duration::from_secs(15);
        while !handle.is_finished() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(100));
        }
    }
    if let Some(engine) = app.engine.lock().unwrap().take() {
        if let Err(e) = engine.into_collection().close(None) {
            eprintln!("[kanki] error closing collection: {e:?}");
        }
    }
    eprintln!("[kanki] stopped");
}

fn handle(app: &Arc<App>, mut req: Request) {
    let url = req.url().to_string();
    let (path, query) = url.split_once('?').unwrap_or((&url, ""));
    let method = req.method().clone();
    let mut body = String::new();
    let _ = req.as_reader().take(1 << 20).read_to_string(&mut body);
    let body: Value = if body.trim().is_empty() {
        json!({})
    } else {
        serde_json::from_str(&body).unwrap_or(Value::Null)
    };

    let result = route(app, &method, path, query, &body);
    let (status, value) = match result {
        Ok(ok) => ok,
        Err(ApiError(status, kind, msg)) => (status, json!({"error": msg, "kind": kind})),
    };
    let response = Response::from_string(value.to_string())
        .with_status_code(status)
        .with_header(Header::from_bytes(&b"Content-Type"[..], &b"application/json; charset=utf-8"[..]).unwrap());
    let _ = req.respond(response);
}

fn query_u32(query: &str, key: &str) -> Option<u32> {
    query
        .split('&')
        .filter_map(|kv| kv.split_once('='))
        .find(|(k, _)| *k == key)
        .and_then(|(_, v)| v.parse().ok())
}

fn route(app: &Arc<App>, method: &Method, path: &str, query: &str, body: &Value) -> ApiResult {
    let opts = PrepareOptions {
        img_max_px: query_u32(query, "img_max_px")
            .or_else(|| body.get("img_max_px").and_then(Value::as_u64).map(|v| v as u32)),
    };
    match (method, path) {
        (Method::Get, "/status") => status(app),
        (Method::Post, "/login") => login(app, body),
        (Method::Post, "/logout") => {
            *app.auth.lock().unwrap() = None;
            let _ = fs::remove_file(app.auth_path());
            Ok((200, json!({"ok": true})))
        }
        (Method::Post, "/sync") => start_sync(app, body),
        (Method::Get, "/sync") => Ok((200, app.sync.lock().unwrap().to_json(&app.progress))),
        (Method::Get, "/decks") => with_engine(app, |e| e.decks()),
        (Method::Post, "/deck/select") => {
            let id = body.get("id").and_then(Value::as_i64).ok_or_else(|| ApiError::bad("missing id"))?;
            with_engine(app, |e| e.select_deck(id).map(|_| json!({"ok": true})))
        }
        (Method::Get, "/next") => with_engine(app, |e| e.next(&opts)),
        (Method::Post, "/answer") => {
            let cid = body.get("card_id").and_then(Value::as_i64).ok_or_else(|| ApiError::bad("missing card_id"))?;
            let rating = body
                .get("rating")
                .and_then(Value::as_u64)
                .filter(|r| (1..=4).contains(r))
                .ok_or_else(|| ApiError::bad("rating must be 1-4"))?;
            let ms = body.get("ms_taken").and_then(Value::as_u64).unwrap_or(0).min(u32::MAX as u64) as u32;
            with_engine(app, |e| {
                e.answer(cid, rating as u8, ms)?;
                e.next(&opts)
            })
        }
        (Method::Post, "/undo") => with_engine(app, |e| {
            e.undo()?;
            e.next(&opts)
        }),
        (Method::Post, "/bury") | (Method::Post, "/suspend") => {
            let cid = body.get("card_id").and_then(Value::as_i64).ok_or_else(|| ApiError::bad("missing card_id"))?;
            let bury = path == "/bury";
            with_engine(app, |e| {
                if bury { e.bury(cid)? } else { e.suspend(cid)? }
                e.next(&opts)
            })
        }
        (Method::Get, "/verify") => verify(app),
        (Method::Get, "/stats") => with_engine(app, |e| e.stats()),
        (Method::Post, "/flag") => {
            let cid = body.get("card_id").and_then(Value::as_i64).ok_or_else(|| ApiError::bad("missing card_id"))?;
            let flag = body
                .get("flag")
                .and_then(Value::as_u64)
                .filter(|f| *f <= 7)
                .ok_or_else(|| ApiError::bad("flag must be 0-7"))?;
            with_engine(app, |e| e.flag(cid, flag as u32).map(|_| json!({"ok": true, "flag": flag})))
        }
        (Method::Get, "/card") => {
            let id = query
                .split('&')
                .filter_map(|kv| kv.split_once('='))
                .find(|(k, _)| *k == "id")
                .and_then(|(_, v)| v.parse().ok())
                .ok_or_else(|| ApiError::bad("missing id"))?;
            with_engine(app, |e| e.render(id, &opts))
        }
        (Method::Post, "/shutdown") => {
            // Close the collection before replying: USB mass storage may start right after.
            shutdown(app);
            app.shutdown.store(true, Ordering::SeqCst);
            Ok((200, json!({"ok": true})))
        }
        (Method::Post, "/adopt") => {
            let pid = body.get("parent_pid").and_then(Value::as_u64).ok_or_else(|| ApiError::bad("missing parent_pid"))?;
            *app.parent_pid.lock().unwrap() = Some(pid as u32);
            Ok((200, json!({"ok": true})))
        }
        _ => Err(ApiError(404, "bad_request", format!("no route {method} {path}"))),
    }
}

/// Run f against the open collection, or explain why there isn't one.
fn with_engine(app: &App, f: impl FnOnce(&mut Engine) -> anki::error::Result<Value>) -> ApiResult {
    let mut guard = app.engine.lock().unwrap();
    match guard.as_mut() {
        Some(engine) => f(engine).map(|v| (200, v)).map_err(anki_err(app)),
        None if app.collection_sync_running() => Err(ApiError(409, "busy", "Sync in progress".into())),
        None if app.auth.lock().unwrap().is_none() => {
            Err(ApiError(401, "need_login", "Log in to AnkiWeb to download your cards".into()))
        }
        None => Err(ApiError(404, "no_collection", "No collection yet: sync to download it from AnkiWeb".into())),
    }
}

fn status(app: &App) -> ApiResult {
    let auth = app.auth.lock().unwrap().clone();
    // card_count tells the UI whether the first download has happened (an empty collection file
    // exists before it). null while a collection sync has the collection checked out.
    let (has_collection, undo, card_count) = match app.engine.lock().unwrap().as_mut() {
        Some(e) => (true, e.undo_label(), e.card_count().ok()),
        None => (false, None, None),
    };
    Ok((
        200,
        json!({
            "version": env!("CARGO_PKG_VERSION"),
            "anki_version": anki::version::version(),
            "logged_in": auth.is_some(),
            "username": auth.map(|a| a.username),
            "has_collection": has_collection,
            "card_count": card_count,
            "media_dir": app.media_dir(),
            "sync": app.sync.lock().unwrap().to_json(&app.progress),
            "undo": undo,
        }),
    ))
}

/// Counts used to confirm the whole collection made it onto the device.
fn verify(app: &App) -> ApiResult {
    // Use the type from the directory listing: a stat by path per file is a linear directory scan
    // on FAT32, which made this take minutes for ~14k media files on the Kobo.
    let media_files = fs::read_dir(app.media_dir())
        .map(|d| d.filter_map(|e| e.ok()).filter(|e| e.file_type().is_ok_and(|t| t.is_file())).count())
        .unwrap_or(0);
    let (cards, notes) = with_engine(app, |e| Ok(json!([e.card_count()?, e.note_count()?])))
        .map(|(_, v)| (v[0].clone(), v[1].clone()))?;
    Ok((200, json!({"cards": cards, "notes": notes, "media_files": media_files})))
}

fn login(app: &App, body: &Value) -> ApiResult {
    let username = body.get("username").and_then(Value::as_str).unwrap_or("").trim();
    let password = body.get("password").and_then(Value::as_str).unwrap_or("");
    if username.is_empty() || password.is_empty() {
        return Err(ApiError::bad("Enter your AnkiWeb email and password"));
    }
    // Optional custom sync server (self-hosted, or a local test server).
    let endpoint = body
        .get("endpoint")
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| std::env::var("KANKI_SYNC_ENDPOINT").ok())
        .filter(|e| !e.is_empty());
    let auth = sync::login(username, password, endpoint).map_err(anki_err(app))?;
    auth.save(&app.auth_path())
        .map_err(|e| ApiError(500, "internal", format!("saving login: {e}")))?;
    *app.auth.lock().unwrap() = Some(auth);
    eprintln!("[kanki] logged in as {username}");
    Ok((200, json!({"ok": true})))
}

fn start_sync(app: &Arc<App>, body: &Value) -> ApiResult {
    let kind = match body.get("kind").and_then(Value::as_str).unwrap_or("normal") {
        "normal" => SyncKind::Normal,
        "full_download" => SyncKind::FullDownload,
        other => return Err(ApiError::bad(format!("unknown sync kind {other}"))),
    };
    let Some(auth) = app.auth.lock().unwrap().clone() else {
        return Err(ApiError(401, "need_login", "Log in to AnkiWeb first".into()));
    };
    {
        let mut s = app.sync.lock().unwrap();
        if s.state == SyncState::Running {
            return Ok((202, json!({"started": false, "already_running": true})));
        }
        s.state = SyncState::Running;
        s.stage = Some(SyncStage::Collection);
        s.message = "Connecting to AnkiWeb…".into();
        s.server_message.clear();
        s.media = (0, 0, 0, 0);
    }
    {
        let mut p = app.progress.lock().unwrap();
        p.want_abort = false;
        p.last_progress = None;
    }
    eprintln!("[kanki] sync started ({kind:?})");
    let app2 = app.clone();
    let handle = std::thread::spawn(move || run_sync(&app2, kind, auth));
    *app.sync_thread.lock().unwrap() = Some(handle);
    Ok((202, json!({"started": true})))
}

fn set_sync(app: &App, f: impl FnOnce(&mut SyncStatus)) {
    f(&mut app.sync.lock().unwrap());
}

fn run_sync(app: &App, kind: SyncKind, mut auth: StoredAuth) {
    match sync_collection(app, kind, &mut auth) {
        Ok(true) => {}
        Ok(false) => return, // full sync required; UI asks the user
        Err(e) => {
            let (_, msg) = sync::describe_error(&e, &app.tr);
            eprintln!("[kanki] collection sync failed: {msg}");
            set_sync(app, |s| {
                s.state = SyncState::Error;
                s.message = msg;
            });
            return;
        }
    }

    // Media: runs without holding the collection lock, so reviewing can continue meanwhile.
    set_sync(app, |s| {
        s.stage = Some(SyncStage::Media);
        s.message = "Syncing media…".into();
    });
    remove_appledouble_files(&app.media_dir());
    let media = {
        let guard = app.engine.lock().unwrap();
        match guard.as_ref() {
            Some(e) => e.col.media().map(|m| (m, e.col.new_progress_handler())),
            None => return,
        }
    };
    let result = media.and_then(|(mgr, progress)| {
        sync::runtime().block_on(mgr.sync_media(progress, auth.to_sync_auth(), sync::web_client(), None))
    });
    let last = app.progress.lock().unwrap().last_progress;
    set_sync(app, |s| {
        if let Some(anki::progress::Progress::MediaSync(p)) = last {
            s.media = (p.checked, p.downloaded_files, p.uploaded_files, p.downloaded_deletions + p.uploaded_deletions);
        }
        match result {
            Ok(()) => {
                s.state = SyncState::Done;
                s.stage = None;
                s.message = "Sync complete".into();
                s.last_success = Some(sync::now());
            }
            Err(e) => {
                let (_, msg) = sync::describe_error(&e, &app.tr);
                eprintln!("[kanki] media sync failed: {msg}");
                s.state = SyncState::Error;
                s.message = format!("Cards synced, but media failed: {msg}");
            }
        }
    });
}

/// macOS writes a `._name` metadata file next to every file it copies onto FAT32. Anki's media sync
/// doesn't skip them, so without this they'd be uploaded to AnkiWeb as if they were media.
fn remove_appledouble_files(media_dir: &std::path::Path) {
    let Ok(entries) = fs::read_dir(media_dir) else { return };
    let mut removed = 0;
    for entry in entries.flatten() {
        if entry.file_name().to_string_lossy().starts_with("._") && fs::remove_file(entry.path()).is_ok() {
            removed += 1;
        }
    }
    if removed > 0 {
        eprintln!("[kanki] removed {removed} macOS ._ files from the media folder");
    }
}

/// Collection phase. Ok(true) = synced and engine is back in place; Ok(false) = full sync required.
fn sync_collection(app: &App, kind: SyncKind, auth: &mut StoredAuth) -> anki::error::Result<bool> {
    // Check the collection out of the shared slot; requests get "busy" until we put it back.
    let engine = app.engine.lock().unwrap().take();
    let mut col = match engine {
        Some(e) => e.into_collection(),
        None => engine::open_collection(&app.col_path(), &app.tr, &app.progress)?,
    };
    let put_back = |col: anki::collection::Collection| {
        *app.engine.lock().unwrap() = Some(Engine::new(col, app.media_dir(), app.cache_dir()));
    };

    let empty = match col.search_cards("", anki::search::SortMode::NoOrder) {
        Ok(cards) => cards.is_empty(),
        Err(e) => {
            put_back(col);
            return Err(e);
        }
    };

    // Always start with a normal sync, as desktop does: it is what tells us which AnkiWeb server holds
    // this account, which a full download needs.
    let outcome = match sync::normal_sync(&mut col, auth) {
        Ok(o) => o,
        Err(e) => {
            put_back(col);
            return Err(e);
        }
    };
    if let Some(ep) = &outcome.new_endpoint {
        eprintln!("[kanki] AnkiWeb sync server for this account: {ep}");
        auth.endpoint = Some(ep.clone());
        let _ = auth.save(&app.auth_path());
        *app.auth.lock().unwrap() = Some(auth.clone());
    }
    set_sync(app, |s| s.server_message = outcome.server_message.clone());

    if outcome.full_sync_required {
        if kind == SyncKind::FullDownload || empty {
            set_sync(app, |s| s.message = "Downloading your collection from AnkiWeb…".into());
            eprintln!("[kanki] full download (requested: {}, local empty: {empty})", kind == SyncKind::FullDownload);
            // full_download reopens the collection whatever happens
            match sync::full_download(col, auth) {
                Ok(col) => put_back(col),
                Err(e) => {
                    if let Ok(e2) = app.open_engine() {
                        *app.engine.lock().unwrap() = Some(e2);
                    }
                    return Err(e);
                }
            }
            return Ok(true);
        }
        put_back(col);
        set_sync(app, |s| {
            s.state = SyncState::FullSyncRequired;
            s.stage = None;
            s.message = "AnkiWeb needs a one-way sync. Download AnkiWeb's copy to this Kobo?".into();
        });
        return Ok(false);
    }

    // Reopen so study queues and caches reflect what came down from AnkiWeb.
    let mut builder = col.as_builder();
    col.close(None)?;
    put_back(builder.build()?);
    Ok(true)
}
