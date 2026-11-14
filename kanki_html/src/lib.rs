//! Turns Anki-rendered card HTML into something KOReader's MuPDF HTML engine shows well on e-ink.
//!
//! MuPDF has no JavaScript and only simple CSS (no reliable `position:absolute`, no flexbox), so:
//! * scripts, buttons, inline event handlers, audio/video and Anki's `[sound:]`/TTS tags go;
//! * image-occlusion masks (IOE add-on and Anki's native IO) are drawn into the image and the
//!   result is inlined as a `data:` URI;
//! * wide images get a `width` cap;
//! * CSS loses night-mode/dark rules and gets readable defaults.
//!
//! Nothing here panics on bad input; a failing image is left as it was.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::LazyLock;

use regex::Regex;

mod css;
mod html;
mod media;
mod occlusion;

pub use occlusion::{load_system_fonts, set_font_dirs, MAX_COMPOSITE_SIDE};

#[derive(Debug, Clone, Default)]
pub struct PrepareOptions {
    /// Reviewer content width in CSS px; wider images get width-capped.
    pub img_max_px: Option<u32>,
}

/// Clean one side (question or answer) of a rendered card.
///
/// `media_dir` is the collection's media folder; `cache_dir` holds flattened occlusion images
/// (created on demand; safe to delete at any time).
pub fn prepare_card_html(
    html: &str,
    media_dir: &Path,
    cache_dir: &Path,
    opts: &PrepareOptions,
) -> String {
    let mut s = html.to_string();
    s = stage(s, clean_markup);
    s = stage(s, strip_av_tags);
    s = stage(s, |h| occlusion::flatten_ioe(h, media_dir, cache_dir, opts));
    s = stage(s, |h| occlusion::flatten_native_io(h, media_dir, cache_dir, opts));
    s = stage(s, |h| media::size_images(h, media_dir, opts.img_max_px));
    s
}

/// Clean a notetype's CSS for e-ink.
pub fn prepare_css(css: &str) -> String {
    match catch_unwind(AssertUnwindSafe(|| css::prepare_css(css))) {
        Ok(s) => s,
        Err(_) => format!(
            "{}\n{}\n{}\n",
            css::DEFAULT_CLOZE_CSS,
            css,
            css::FORCED_DEFAULTS_CSS
        ),
    }
}

/// Deletes the oldest flattened images (by creation time) until the cache is at most
/// `max_bytes`. Returns the number of bytes freed. Errors are ignored (the cache is disposable;
/// anything deleted is simply re-rendered when next needed).
pub fn prune_cache(cache_dir: &Path, max_bytes: u64) -> u64 {
    let Ok(rd) = std::fs::read_dir(cache_dir) else {
        return 0;
    };
    let mut files: Vec<(std::time::SystemTime, u64, std::path::PathBuf)> = rd
        .filter_map(|e| e.ok())
        .filter(|e| e.file_name().to_string_lossy().starts_with("io-"))
        .filter_map(|e| {
            let m = e.metadata().ok()?;
            m.is_file()
                .then(|| (m.modified().unwrap_or(std::time::UNIX_EPOCH), m.len(), e.path()))
        })
        .collect();
    let mut total: u64 = files.iter().map(|f| f.1).sum();
    files.sort_by_key(|f| f.0);
    let mut freed = 0;
    for (_, len, path) in files {
        if total <= max_bytes {
            break;
        }
        if std::fs::remove_file(&path).is_ok() {
            total = total.saturating_sub(len);
            freed += len;
        }
    }
    freed
}

/// Runs one transformation; if it panics, the input passes through unchanged.
fn stage(input: String, f: impl FnOnce(&str) -> String) -> String {
    match catch_unwind(AssertUnwindSafe(|| f(&input))) {
        Ok(out) => out,
        Err(_) => input,
    }
}

/// Elements removed together with their content.
const REMOVED_ELEMENTS: &[&str] = &[
    "script", "button", "audio", "video", "iframe", "object", "embed", "canvas", "template",
];

/// Removes scripts, buttons, media elements and event handlers; cleans inline colours.
fn clean_markup(src: &str) -> String {
    let toks = html::tokenize(src);
    let mut edits: Vec<(usize, usize, String)> = Vec::new();
    let mut i = 0;
    while i < toks.len() {
        let t = &toks[i];
        if t.kind != html::Kind::StartTag {
            i += 1;
            continue;
        }
        let name = t.name.to_ascii_lowercase();
        if REMOVED_ELEMENTS.contains(&name.as_str()) {
            let void = html::is_void(&name) || (t.self_closing && name != "script");
            match (!void).then(|| html::find_matching_end(&toks, i)).flatten() {
                Some(e) => {
                    edits.push((t.start, toks[e].end, String::new()));
                    i = e + 1;
                }
                None => {
                    // unterminated: a <script> swallows the rest (as a browser would)
                    let end = if name == "script" { src.len() } else { t.end };
                    edits.push((t.start, end, String::new()));
                    i = if name == "script" { toks.len() } else { i + 1 };
                }
            }
            continue;
        }
        if name == "style" {
            if let Some(text) = toks.get(i + 1).filter(|n| n.kind == html::Kind::Text) {
                let css_in = &src[text.start..text.end];
                let cleaned = css::clean_css(css_in);
                if cleaned.trim() != css_in.trim() {
                    edits.push((text.start, text.end, cleaned));
                }
            }
        }
        let mut tb: Option<html::TagBuilder> = None;
        let tb_mut = |tb: &mut Option<html::TagBuilder>| {
            if tb.is_none() {
                *tb = Some(html::TagBuilder::from_token(t));
            }
        };
        for a in &t.attrs {
            let an = a.name.to_ascii_lowercase();
            if an.len() > 2 && an.starts_with("on") {
                tb_mut(&mut tb);
                if let Some(b) = tb.as_mut() {
                    b.remove(a.name);
                }
            } else if an == "style" {
                let v = html::decode_entities(a.value.unwrap_or(""));
                if let Some(new) = css::clean_inline_style(&v) {
                    tb_mut(&mut tb);
                    if let Some(b) = tb.as_mut() {
                        if new.trim().is_empty() {
                            b.remove("style");
                        } else {
                            b.set("style", &html::escape_attr(&new));
                        }
                    }
                }
            } else if (an == "color" && name == "font")
                && css::is_too_light_text(&html::decode_entities(a.value.unwrap_or("")))
            {
                tb_mut(&mut tb);
                if let Some(b) = tb.as_mut() {
                    b.remove(a.name);
                }
            } else if an == "bgcolor"
                && css::is_dark_bg_attr(&html::decode_entities(a.value.unwrap_or("")))
            {
                tb_mut(&mut tb);
                if let Some(b) = tb.as_mut() {
                    b.remove(a.name);
                }
            }
        }
        if let Some(b) = tb {
            edits.push((t.start, t.end, b.build()));
        }
        i += 1;
    }
    html::apply_edits(src, edits)
}

static AV_TAGS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?s)\[anki:tts(?:\]|\s[^\]]*\]).*?\[/anki:tts\]|\[sound:[^\]]*\]|\[anki:play:[qa]:\d+\]",
    )
    .expect("valid regex")
});

/// Removes `[sound:...]`, `[anki:play:q:0]` and `[anki:tts ...]...[/anki:tts]`.
fn strip_av_tags(src: &str) -> String {
    if !src.contains('[') {
        return src.to_string();
    }
    AV_TAGS.replace_all(src, "").into_owned()
}

#[cfg(test)]
mod tests;
