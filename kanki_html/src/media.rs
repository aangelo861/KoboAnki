//! Resolving `<img src>` values to media files, reading image dimensions, and width-capping.

use std::path::{Path, PathBuf};

use crate::html::{self, decode_entities, percent_decode, Kind, TagBuilder};

/// Resolves a raw (entity-encoded) `src` attribute to an existing file in the media folder.
/// Remote URLs, `data:` URIs and anything that could escape the media folder give None.
pub(crate) fn resolve_media(media_dir: &Path, raw_src: &str) -> Option<PathBuf> {
    let decoded = decode_entities(raw_src.trim());
    let src = decoded.trim();
    if src.is_empty() || src.contains(':') || src.starts_with("//") {
        // `data:`, `http:`, ... (Anki never allows ':' in media file names)
        return None;
    }
    let mut candidates = vec![src.to_string()];
    if let Some(p) = percent_decode(src) {
        candidates.push(p);
    }
    for c in candidates {
        let c = c.strip_prefix("./").unwrap_or(&c);
        if !is_safe_name(c) {
            continue;
        }
        let p = media_dir.join(c);
        if p.is_file() {
            return Some(p);
        }
    }
    None
}

fn is_safe_name(n: &str) -> bool {
    !n.is_empty()
        && n != "."
        && n != ".."
        && !n.contains('/')
        && !n.contains('\\')
        && !n.contains('\0')
}

pub(crate) fn is_svg_path(p: &Path) -> bool {
    p.extension()
        .and_then(|e| e.to_str())
        .map(|e| e.eq_ignore_ascii_case("svg") || e.eq_ignore_ascii_case("svgz"))
        .unwrap_or(false)
}

/// Natural pixel size of an image file, reading only its header (SVGs are parsed).
pub(crate) fn image_dims(path: &Path) -> Option<(u32, u32)> {
    if is_svg_path(path) {
        let meta = std::fs::metadata(path).ok()?;
        if meta.len() > 4 * 1024 * 1024 {
            return None;
        }
        let data = std::fs::read(path).ok()?;
        let tree = crate::occlusion::parse_svg(&data).ok()?;
        let s = tree.size();
        return Some((s.width().round().max(1.0) as u32, s.height().round().max(1.0) as u32));
    }
    let reader = image::ImageReader::open(path)
        .ok()?
        .with_guessed_format()
        .ok()?;
    reader.into_dimensions().ok()
}

/// Parses a CSS/HTML length in px ("300", "300px", "300.5px"); None for %, em, auto, ...
fn parse_px(v: &str) -> Option<f32> {
    let v = v.trim();
    let v = v.strip_suffix("px").unwrap_or(v).trim();
    let n = v.parse::<f32>().ok()?;
    (n.is_finite() && n > 0.0).then_some(n)
}

/// Returns (name, value) pairs of an inline style.
fn style_decls(style: &str) -> Vec<(String, String)> {
    style
        .split(';')
        .filter_map(|d| {
            let (n, v) = d.split_once(':')?;
            Some((n.trim().to_ascii_lowercase(), v.trim().to_string()))
        })
        .collect()
}

/// Width-caps local `<img>`s whose rendered width would exceed `max_px`.
pub(crate) fn size_images(src_html: &str, media_dir: &Path, max_px: Option<u32>) -> String {
    let Some(max_px) = max_px.filter(|&m| m > 0) else {
        return src_html.to_string();
    };
    if !src_html.contains("<img") && !src_html.contains("<IMG") {
        return src_html.to_string();
    }
    let toks = html::tokenize(src_html);
    let mut edits = Vec::new();
    for t in &toks {
        if t.kind != Kind::StartTag || !t.name.eq_ignore_ascii_case("img") {
            continue;
        }
        let Some(src) = t.attr("src") else { continue };
        if src
            .trim_start()
            .get(..5)
            .is_some_and(|p| p.eq_ignore_ascii_case("data:"))
        {
            continue;
        }
        let Some(path) = resolve_media(media_dir, src) else {
            continue;
        };
        let Some((nw, nh)) = image_dims(&path) else {
            continue;
        };
        if nw == 0 || nh == 0 {
            continue;
        }
        let style = t.attr_decoded("style").map(|s| s.into_owned()).unwrap_or_default();
        let decls = style_decls(&style);
        let style_w = decls.iter().rev().find(|(n, _)| n == "width").map(|(_, v)| v.clone());
        let style_h = decls.iter().rev().find(|(n, _)| n == "height").map(|(_, v)| v.clone());
        // CSS width beats the width attribute.
        let width_spec = style_w.or_else(|| t.attr_decoded("width").map(|s| s.into_owned()));
        let height_spec = style_h.or_else(|| t.attr_decoded("height").map(|s| s.into_owned()));
        let effective_w = match (&width_spec, &height_spec) {
            (Some(w), _) if w.trim() != "auto" && !w.trim().is_empty() => match parse_px(w) {
                Some(px) => px,
                None => continue, // %, em, ...: relative to the page, leave alone
            },
            (_, Some(h)) if parse_px(h).is_some() => parse_px(h).unwrap_or(nh as f32) * nw as f32 / nh as f32,
            _ => nw as f32,
        };
        if effective_w <= max_px as f32 + 0.5 {
            continue;
        }
        let mut tb = TagBuilder::from_token(t);
        tb.set("width", &max_px.to_string());
        tb.remove("height");
        let kept: Vec<String> = style
            .split(';')
            .filter(|d| {
                let n = d.split(':').next().unwrap_or("").trim().to_ascii_lowercase();
                !d.trim().is_empty()
                    && !matches!(
                        n.as_str(),
                        "width" | "height" | "max-width" | "max-height" | "min-width" | "min-height"
                    )
            })
            .map(|d| d.trim().to_string())
            .collect();
        if t.attr("style").is_some() {
            if kept.is_empty() {
                tb.remove("style");
            } else {
                tb.set("style", &html::escape_attr(&kept.join("; ")));
            }
        }
        edits.push((t.start, t.end, tb.build()));
    }
    html::apply_edits(src_html, edits)
}
