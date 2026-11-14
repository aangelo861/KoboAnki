//! Dev-only helper (never shipped to the Kobo).
//!   kanki_devsync server                                   # Anki's own sync server; needs SYNC_USER1=user:pass SYNC_BASE=dir SYNC_PORT=8080
//!   kanki_devsync upload <collection.anki2> <endpoint> <user> <pass>   # full upload, like a desktop's first sync
//!   kanki_devsync sync <collection.anki2> <endpoint> <user> <pass>     # normal sync, like desktop
//!   kanki_devsync review <collection.anki2> <n>            # answer n cards "Good" like a desktop session

use anki::collection::CollectionBuilder;
use anki::scheduler::answering::{CardAnswer, Rating};
use anki::sync::login::sync_login;
use anki::timestamp::TimestampMillis;

fn rt() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap()
}

fn client() -> reqwest::Client {
    reqwest::Client::builder().http1_only().build().unwrap()
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    match a.get(1).map(String::as_str) {
        Some("server") => {
            let r = anki::sync::http_server::SimpleServer::run();
            println!("{r:?}");
        }
        Some("media") => {
            let (path, endpoint, user, pass) = (&a[2], &a[3], &a[4], &a[5]);
            let mut auth = rt()
                .block_on(sync_login(user.as_str(), pass.as_str(), Some(endpoint.clone()), client()))
                .expect("login");
            auth.endpoint = Some(reqwest::Url::parse(endpoint).expect("endpoint url"));
            let col = CollectionBuilder::new(path).with_desktop_media_paths().build().expect("open");
            let mgr = col.media().expect("media");
            rt().block_on(mgr.sync_media(col.new_progress_handler(), auth, client(), None))
                .expect("media sync");
            println!("media synced");
        }
        Some("upload") | Some("sync") => {
            let (path, endpoint, user, pass) = (&a[2], &a[3], &a[4], &a[5]);
            let mut auth = rt()
                .block_on(sync_login(user.as_str(), pass.as_str(), Some(endpoint.clone()), client()))
                .expect("login");
            // sync_login doesn't carry the endpoint over; without this, requests go to AnkiWeb.
            auth.endpoint = Some(reqwest::Url::parse(endpoint).expect("endpoint url"));
            let mut col = CollectionBuilder::new(path).build().expect("open");
            if a[1] == "upload" {
                rt().block_on(col.full_upload(auth, client())).expect("full upload");
                println!("uploaded");
            } else {
                let out = rt().block_on(col.normal_sync(auth, client())).expect("normal sync");
                println!("synced: {:?}", out.required);
            }
        }
        Some("review") => {
            let n: usize = a[3].parse().unwrap();
            let mut col = CollectionBuilder::new(&a[2]).build().expect("open");
            for _ in 0..n {
                let q = col.get_queued_cards(1, false).unwrap();
                let Some(qc) = q.cards.into_iter().next() else { break };
                let mut ans = CardAnswer {
                    card_id: qc.card.id(),
                    current_state: qc.states.current,
                    new_state: qc.states.good,
                    rating: Rating::Good,
                    answered_at: TimestampMillis::now(),
                    milliseconds_taken: 3000,
                    custom_data: None,
                    from_queue: true,
                };
                col.answer_card(&mut ans).unwrap();
                println!("answered {}", qc.card.id());
            }
            col.close(None).unwrap();
        }
        _ => eprintln!("see source for usage"),
    }
}
