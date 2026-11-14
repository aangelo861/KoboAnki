//! AnkiWeb login, collection sync and media sync, using Anki's own sync client.
//! The Kobo never does a full upload: AnkiWeb stays the source of truth.

use std::fs;
use std::path::Path;
use std::sync::Arc;
use std::sync::Mutex;

use anki::error::AnkiError;
use anki::error::NetworkErrorKind;
use anki::error::SyncErrorKind;
use anki::prelude::I18n;
use anki::progress::Progress;
use anki::progress::ProgressState;
use anki::sync::collection::normal::SyncActionRequired;
use anki::sync::login::sync_login;
use anki::sync::login::SyncAuth;
use anki::timestamp::TimestampSecs;
use reqwest::Client;
use reqwest::Url;
use serde::Deserialize;
use serde::Serialize;
use serde_json::json;
use serde_json::Value;

/// What we keep on disk after logging in. The password is never stored.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct StoredAuth {
    pub username: String,
    pub hkey: String,
    pub endpoint: Option<String>,
}

impl StoredAuth {
    pub fn load(path: &Path) -> Option<StoredAuth> {
        serde_json::from_slice(&fs::read(path).ok()?).ok()
    }

    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        let tmp = path.with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        fs::rename(tmp, path)
    }

    pub fn to_sync_auth(&self) -> SyncAuth {
        SyncAuth {
            hkey: self.hkey.clone(),
            endpoint: self.endpoint.as_deref().and_then(|e| Url::parse(e).ok()),
            io_timeout_secs: None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SyncKind {
    Normal,
    FullDownload,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SyncState {
    Idle,
    Running,
    Done,
    Error,
    FullSyncRequired,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SyncStage {
    Collection,
    Media,
}

pub struct SyncStatus {
    pub state: SyncState,
    pub stage: Option<SyncStage>,
    pub message: String,
    pub server_message: String,
    pub last_success: Option<i64>,
    pub media: (usize, usize, usize, usize),
}

impl Default for SyncStatus {
    fn default() -> Self {
        SyncStatus {
            state: SyncState::Idle,
            stage: None,
            message: String::new(),
            server_message: String::new(),
            last_success: None,
            media: (0, 0, 0, 0),
        }
    }
}

impl SyncStatus {
    /// JSON for the UI, folding in live progress from Anki's progress handler while running.
    pub fn to_json(&self, progress: &Arc<Mutex<ProgressState>>) -> Value {
        let mut message = self.message.clone();
        let mut media = self.media;
        if self.state == SyncState::Running {
            if let Some(p) = progress.lock().unwrap().last_progress {
                match p {
                    Progress::NormalSync(p) => {
                        let changes = p.local_update + p.local_remove + p.remote_update + p.remote_remove;
                        message = if changes > 0 {
                            format!("Syncing collection… {changes} changes")
                        } else {
                            "Syncing collection…".into()
                        };
                    }
                    Progress::FullSync(p) if p.total_bytes > 0 => {
                        message = format!(
                            "Downloading collection… {:.1} of {:.1} MB",
                            p.transferred_bytes as f64 / 1e6,
                            p.total_bytes as f64 / 1e6
                        );
                    }
                    Progress::MediaSync(p) => {
                        media = (
                            p.checked,
                            p.downloaded_files,
                            p.uploaded_files,
                            p.downloaded_deletions + p.uploaded_deletions,
                        );
                        message = format!(
                            "Syncing media… checked {}, downloaded {}, uploaded {}",
                            p.checked, p.downloaded_files, p.uploaded_files
                        );
                    }
                    _ => {}
                }
            }
        }
        json!({
            "state": match self.state {
                SyncState::Idle => "idle",
                SyncState::Running => "running",
                SyncState::Done => "done",
                SyncState::Error => "error",
                SyncState::FullSyncRequired => "full_sync_required",
            },
            "stage": self.stage.map(|s| match s { SyncStage::Collection => "collection", SyncStage::Media => "media" }),
            "message": message,
            "server_message": self.server_message,
            "media": {"checked": media.0, "downloaded": media.1, "uploaded": media.2, "deleted": media.3},
            "last_success": self.last_success,
        })
    }
}

pub fn web_client() -> Client {
    // Same as desktop: http1 only, as AnkiWeb's proxies don't do http2.
    Client::builder().http1_only().build().expect("building http client")
}

pub fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("building tokio runtime")
}

pub fn login(username: &str, password: &str, endpoint: Option<String>) -> anki::error::Result<StoredAuth> {
    let auth = runtime().block_on(sync_login(username, password, endpoint.clone(), web_client()))?;
    Ok(StoredAuth {
        username: username.to_string(),
        hkey: auth.hkey,
        endpoint,
    })
}

/// Outcome of the collection phase.
pub struct CollectionOutcome {
    /// AnkiWeb asked for a one-way sync instead.
    pub full_sync_required: bool,
    pub server_message: String,
    /// AnkiWeb keeps each account on one of several sync servers and only says which in reply to a
    /// normal sync; a full download sent to the generic address fails ("missing original size").
    /// Persist this before any full download.
    pub new_endpoint: Option<String>,
}

/// Normal sync. Always the first step (as on desktop), even before a full download, because it is
/// what discovers the account's sync server.
pub fn normal_sync(
    col: &mut anki::collection::Collection,
    auth: &StoredAuth,
) -> anki::error::Result<CollectionOutcome> {
    let out = runtime().block_on(col.normal_sync(auth.to_sync_auth(), web_client()))?;
    Ok(CollectionOutcome {
        full_sync_required: matches!(out.required, SyncActionRequired::FullSyncRequired { .. }),
        server_message: out.server_message,
        new_endpoint: out.new_endpoint,
    })
}

/// Replace the local collection with AnkiWeb's copy. Consumes and reopens the collection.
pub fn full_download(
    col: anki::collection::Collection,
    auth: &StoredAuth,
) -> anki::error::Result<anki::collection::Collection> {
    let mut builder = col.as_builder();
    let result = runtime().block_on(col.full_download(auth.to_sync_auth(), web_client()));
    // reopen regardless of outcome (a failed download leaves the old file in place)
    let col = builder.build()?;
    result.map(|_| col)
}

pub fn now() -> i64 {
    TimestampSecs::now().0
}

/// (machine kind, human message) for an Anki error.
pub fn describe_error(e: &AnkiError, tr: &I18n) -> (&'static str, String) {
    let kind = match e {
        AnkiError::SyncError { source } if source.kind == SyncErrorKind::AuthFailed => "auth",
        AnkiError::SyncError { .. } => "sync",
        AnkiError::NetworkError { source } => match source.kind {
            NetworkErrorKind::Offline | NetworkErrorKind::Timeout => "network",
            _ => "network",
        },
        AnkiError::Interrupted => "interrupted",
        _ => "internal",
    };
    (kind, e.message(tr))
}
