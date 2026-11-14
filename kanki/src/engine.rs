//! Reviewing: everything that reads or changes the open collection outside of syncing.
//! All scheduling goes through Anki's own code, so results match desktop exactly.

use std::path::Path;
use std::path::PathBuf;

use anki::collection::CollectionBuilder;
use anki::prelude::I18n;
use anki::prelude::*;
use anki::progress::ProgressState;
use anki::scheduler::answering::CardAnswer;
use anki::scheduler::answering::Rating;
use anki::scheduler::states::CardState;
use anki::scheduler::states::NormalState;
use anki::scheduler::states::SchedulingStates;
use anki::search::SortMode;
use anki::services::StatsService;
use anki_proto::decks::DeckTreeNode;
use anki_proto::stats::graphs_response::review_counts_and_times::Reviews;
use anki_proto::stats::graphs_response::true_retention_stats::TrueRetention;
use anki_proto::stats::GraphsRequest;
use anki_proto::scheduler::bury_or_suspend_cards_request::Mode as BuryOrSuspendMode;
use kanki_html::PrepareOptions;
use serde_json::json;
use serde_json::Value;
use std::sync::Arc;
use std::sync::Mutex;

pub struct Engine {
    pub col: Collection,
    media_dir: PathBuf,
    cache_dir: PathBuf,
    /// The card last handed to the UI and the button states it was shown with.
    shown: Option<(CardId, SchedulingStates)>,
}

pub fn open_collection(
    col_path: &Path,
    tr: &I18n,
    progress: &Arc<Mutex<ProgressState>>,
) -> Result<Collection> {
    CollectionBuilder::new(col_path)
        .with_desktop_media_paths()
        .set_tr(tr.clone())
        .set_shared_progress_state(progress.clone())
        .build()
}

impl Engine {
    pub fn new(col: Collection, media_dir: PathBuf, cache_dir: PathBuf) -> Self {
        Engine {
            col,
            media_dir,
            cache_dir,
            shown: None,
        }
    }

    pub fn into_collection(self) -> Collection {
        self.col
    }

    pub fn card_count(&mut self) -> Result<usize> {
        Ok(self.col.search_cards("", SortMode::NoOrder)?.len())
    }

    pub fn note_count(&mut self) -> Result<usize> {
        Ok(self.col.search_notes_unordered("")?.len())
    }

    pub fn undo_label(&self) -> Option<String> {
        self.col.undo_status().undo.map(|op| op.describe(self.col.tr()))
    }

    /// Flattened depth-first deck list with desktop's limited counts.
    pub fn decks(&mut self) -> Result<Value> {
        let tree = self.col.deck_tree(Some(TimestampSecs::now()))?;
        let mut out = vec![];
        let mut path = vec![];
        flatten(&tree, &mut path, &mut out);
        let current = self.col.get_current_deck()?.id.0;
        Ok(json!({"current_id": current, "decks": out}))
    }

    pub fn select_deck(&mut self, id: i64) -> Result<()> {
        self.col.set_current_deck(DeckId(id))?;
        self.shown = None;
        Ok(())
    }

    /// The card at the top of the queue, rendered and cleaned for KOReader.
    pub fn next(&mut self, opts: &PrepareOptions) -> Result<Value> {
        let queued = self.col.get_queued_cards(1, false)?;
        let counts = json!({
            "new": queued.new_count,
            "learning": queued.learning_count,
            "review": queued.review_count,
        });
        let undo = self.undo_label();
        let Some(qc) = queued.cards.into_iter().next() else {
            self.shown = None;
            return Ok(json!({"state": "done", "counts": counts, "undo": undo}));
        };

        let cid = qc.card.id();
        let labels = self.col.describe_next_states(&qc.states)?;
        let rendered = self.col.render_existing_card(cid, false, false)?;
        let deck = self
            .col
            .get_deck(qc.card.deck_id())?
            .map(|d| d.name.human_name())
            .unwrap_or_default();
        let question =
            kanki_html::prepare_card_html(&rendered.question(), &self.media_dir, &self.cache_dir, opts);
        let answer =
            kanki_html::prepare_card_html(&rendered.answer(), &self.media_dir, &self.cache_dir, opts);
        let css = kanki_html::prepare_css(&rendered.css);
        let kind = match qc.states.current {
            CardState::Normal(NormalState::New(_)) => "new",
            CardState::Normal(NormalState::Learning(_)) => "learning",
            CardState::Normal(NormalState::Review(_)) => "review",
            CardState::Normal(NormalState::Relearning(_)) => "relearning",
            // filtered decks: fall back to the queue the card was taken from
            CardState::Filtered(_) => match format!("{:?}", qc.kind).as_str() {
                "New" => "new",
                "Review" => "review",
                _ => "learning",
            },
        };
        // Fluent wraps numbers in invisible bidi isolation marks; KOReader's fonts may draw them as boxes.
        let labels = labels
            .into_iter()
            .map(|l| l.replace(['\u{2068}', '\u{2069}'], ""));
        let buttons: Vec<Value> = ["Again", "Hard", "Good", "Easy"]
            .iter()
            .zip(labels)
            .enumerate()
            .map(|(i, (label, interval))| json!({"rating": i + 1, "label": label, "interval": interval}))
            .collect();

        self.shown = Some((cid, qc.states));
        Ok(json!({
            "state": "card",
            "counts": counts,
            "undo": undo,
            "card": {
                "id": cid.0,
                "ord": qc.card.template_idx() + 1,
                "flag": qc.card.flags(),
                "note_id": qc.card.note_id().0,
                "deck": deck,
                "kind": kind,
                "question": question,
                "answer": answer,
                "css": css,
                "buttons": buttons,
            }
        }))
    }

    /// Render any card without touching the queue (testing and previews).
    pub fn render(&mut self, card_id: i64, opts: &PrepareOptions) -> Result<Value> {
        let rendered = self.col.render_existing_card(CardId(card_id), false, false)?;
        Ok(json!({"card": {
            "id": card_id,
            "question": kanki_html::prepare_card_html(&rendered.question(), &self.media_dir, &self.cache_dir, opts),
            "answer": kanki_html::prepare_card_html(&rendered.answer(), &self.media_dir, &self.cache_dir, opts),
            "css": kanki_html::prepare_css(&rendered.css),
        }}))
    }

    /// Answer a card with Anki's scheduler (SM-2 or FSRS, whatever the deck preset uses).
    pub fn answer(&mut self, card_id: i64, rating: u8, ms_taken: u32) -> Result<()> {
        let cid = CardId(card_id);
        let (states, from_queue) = match self.shown.take() {
            Some((shown, states)) if shown == cid => (states, true),
            _ => (self.col.get_scheduling_states(cid)?, false),
        };
        let (rating, new_state) = match rating {
            1 => (Rating::Again, states.again),
            2 => (Rating::Hard, states.hard),
            4 => (Rating::Easy, states.easy),
            // the HTTP layer only lets 1-4 through
            _ => (Rating::Good, states.good),
        };
        let mut answer = CardAnswer {
            card_id: cid,
            current_state: states.current,
            new_state,
            rating,
            answered_at: TimestampMillis::now(),
            milliseconds_taken: ms_taken,
            custom_data: None,
            from_queue,
        };
        self.col.answer_card(&mut answer)?;
        Ok(())
    }

    pub fn undo(&mut self) -> Result<()> {
        self.shown = None;
        self.col.undo()?;
        Ok(())
    }

    pub fn bury(&mut self, card_id: i64) -> Result<()> {
        self.shown = None;
        self.col
            .bury_or_suspend_cards(&[CardId(card_id)], BuryOrSuspendMode::BuryUser)?;
        Ok(())
    }

    pub fn suspend(&mut self, card_id: i64) -> Result<()> {
        self.shown = None;
        self.col
            .bury_or_suspend_cards(&[CardId(card_id)], BuryOrSuspendMode::Suspend)?;
        Ok(())
    }

    /// Set a card's flag (0 clears; 1-7 = red, orange, green, blue, pink, turquoise, purple).
    /// Doesn't change the queue, so the card on screen stays answerable.
    pub fn flag(&mut self, card_id: i64, flag: u32) -> Result<()> {
        self.col.set_card_flag(&[CardId(card_id)], flag)?;
        Ok(())
    }

    /// Study statistics for the stats and sleep screens, computed by Anki's own graph code
    /// (the same numbers as desktop's Statistics window). Uses the last year of reviews so the
    /// streak can be counted; costs a few hundred ms on the Kobo, so the UI caches it.
    pub fn stats(&mut self) -> Result<Value> {
        let g = self.col.graphs(GraphsRequest {
            search: String::new(),
            days: 365,
        })?;
        let today = g.today.unwrap_or_default();
        let reviews = g.reviews.unwrap_or_default();
        let total = |r: &Reviews| r.learn + r.relearn + r.young + r.mature + r.filtered;
        // day keys: 0 = today, -1 = yesterday, … (Anki days, i.e. after the rollover hour)
        let count_on = |d: i32| reviews.count.get(&d).map(total).unwrap_or(0);
        let millis_on = |d: i32| reviews.time.get(&d).map(total).unwrap_or(0);
        let days: Vec<Value> = (-13..=0)
            .map(|d| json!({"day": d, "count": count_on(d), "seconds": millis_on(d) / 1000}))
            .collect();
        // consecutive days with reviews, ending today (or yesterday, if nothing has been done yet today)
        let mut day = if count_on(0) > 0 { 0 } else { -1 };
        let mut streak = 0;
        while day > -365 && count_on(day) > 0 {
            streak += 1;
            day -= 1;
        }
        let due_tomorrow = g
            .future_due
            .as_ref()
            .and_then(|f| f.future_due.get(&1).copied())
            .unwrap_or(0);
        let rate = |t: Option<TrueRetention>| -> Value {
            let t = t.unwrap_or_default();
            let passed = t.young_passed + t.mature_passed;
            let all = passed + t.young_failed + t.mature_failed;
            if all == 0 {
                Value::Null
            } else {
                json!(passed as f64 / all as f64)
            }
        };
        let retention = g.true_retention.unwrap_or_default();
        let counts = g
            .card_counts
            .and_then(|c| c.excluding_inactive)
            .unwrap_or_default();
        let tree = self.col.deck_tree(Some(TimestampSecs::now()))?;
        let timing = self.col.timing_today()?;
        let studied = self
            .col
            .studied_today()?
            .replace(['\u{2068}', '\u{2069}'], "");
        Ok(json!({
            "today": {
                "answered": today.answer_count,
                "seconds": today.answer_millis / 1000,
                "correct": today.correct_count,
                "learn": today.learn_count,
                "review": today.review_count,
                "relearn": today.relearn_count,
                "mature_correct": today.mature_correct,
                "mature_total": today.mature_count,
            },
            "days": days,
            "streak": streak,
            "due_today": {"new": tree.new_count, "learning": tree.learn_count, "review": tree.review_count},
            "due_tomorrow": due_tomorrow,
            "retention": {
                "today": rate(retention.today),
                "week": rate(retention.week),
                "month": rate(retention.month),
            },
            "cards": {
                "new": counts.new_cards,
                "learn": counts.learn,
                "relearn": counts.relearn,
                "young": counts.young,
                "mature": counts.mature,
                "suspended": counts.suspended,
                "buried": counts.buried,
            },
            "studied_text": studied,
            "next_day_at": timing.next_day_at.0,
            "generated_at": TimestampSecs::now().0,
        }))
    }
}

fn flatten(node: &DeckTreeNode, path: &mut Vec<String>, out: &mut Vec<Value>) {
    for child in &node.children {
        path.push(child.name.clone());
        out.push(json!({
            "id": child.deck_id,
            "name": path.join("::"),
            "short_name": child.name,
            "depth": path.len() - 1,
            "new": child.new_count,
            "learning": child.learn_count,
            "review": child.review_count,
            "collapsed": child.collapsed,
            "has_children": !child.children.is_empty(),
            "filtered": child.filtered,
        }));
        flatten(child, path, out);
        path.pop();
    }
}
