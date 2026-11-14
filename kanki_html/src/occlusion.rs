//! Image-occlusion flattening: draw the masks into the image so a renderer without
//! `position:absolute`/canvas/JS (MuPDF) shows exactly what desktop Anki shows.
//!
//! * Image Occlusion Enhanced (add-on): `#io-wrapper` holding `#io-overlay` (an SVG mask the size
//!   of the image) and `#io-original` (the image).
//! * Anki's native Image Occlusion: `#image-occlusion-container` with an `<img>` and a canvas,
//!   shapes given as `<div class="cloze|cloze-inactive|cloze-highlight" data-shape=...>`.
//!
//! Composites are cached in `cache_dir`, keyed by the inputs' names, sizes and mtimes.

use std::fmt::Write as _;
use std::fs;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};
use std::time::UNIX_EPOCH;

use anyhow::{anyhow, Context, Result};
use base64::Engine as _;
use image::{DynamicImage, GenericImageView, ImageDecoder as _, ImageFormat};
use resvg::{tiny_skia, usvg};

use crate::html::{self, find_matching_end, tokenize, Token};
use crate::media::{image_dims, resolve_media};
use crate::PrepareOptions;

/// Longest side of a composite, in pixels.
pub const MAX_COMPOSITE_SIDE: u32 = 2000;
const JPEG_QUALITY: u8 = 85;
/// Bump to invalidate old cache entries when the output changes.
const CACHE_VERSION: u32 = 2;

// ---------------------------------------------------------------------------------------------
// Fonts (only needed for the rare text labels in masks)
// ---------------------------------------------------------------------------------------------

struct Fonts {
    db: Arc<usvg::fontdb::Database>,
    family: String,
    generation: u64,
}

static FONTS: RwLock<Option<Fonts>> = RwLock::new(None);

fn install_fonts(mut db: usvg::fontdb::Database) {
    // pick a sans family that exists, for `sans-serif` and for text without a font-family
    let families: Vec<String> = db
        .faces()
        .flat_map(|f| f.families.iter().map(|(n, _)| n.clone()))
        .collect();
    let pick = ["Arial", "Helvetica", "Liberation Sans", "Noto Sans", "DejaVu Sans", "FreeSans"]
        .iter()
        .find(|p| families.iter().any(|f| f == *p))
        .map(|s| s.to_string())
        .or_else(|| families.iter().find(|f| f.contains("Sans")).cloned())
        .or_else(|| families.first().cloned())
        .unwrap_or_else(|| "Arial".to_string());
    db.set_sans_serif_family(pick.clone());
    db.set_serif_family(pick.clone());
    db.set_monospace_family(pick.clone());
    db.set_cursive_family(pick.clone());
    db.set_fantasy_family(pick.clone());
    let mut g = FONTS.write().unwrap_or_else(|e| e.into_inner());
    let generation = g.as_ref().map(|f| f.generation + 1).unwrap_or(1);
    *g = Some(Fonts {
        db: Arc::new(db),
        family: pick,
        generation,
    });
}

/// Loads fonts (recursively) from these directories for text labels inside occlusion masks.
/// Without fonts, mask text is skipped (shapes are still drawn). On the Kobo, KOReader's
/// `fonts/` folder is a good choice.
pub fn set_font_dirs(dirs: &[PathBuf]) {
    let mut db = usvg::fontdb::Database::new();
    for d in dirs {
        db.load_fonts_dir(d);
    }
    install_fonts(db);
}

/// Loads the operating system's fonts (useful on a desktop; slow-ish, call once).
pub fn load_system_fonts() {
    let mut db = usvg::fontdb::Database::new();
    db.load_system_fonts();
    install_fonts(db);
}

fn fonts() -> (Arc<usvg::fontdb::Database>, String, u64) {
    let g = FONTS.read().unwrap_or_else(|e| e.into_inner());
    match g.as_ref() {
        Some(f) => (f.db.clone(), f.family.clone(), f.generation),
        None => (Arc::new(usvg::fontdb::Database::new()), "Arial".into(), 0),
    }
}

fn have_fonts() -> bool {
    let g = FONTS.read().unwrap_or_else(|e| e.into_inner());
    g.as_ref().map(|f| !f.db.is_empty()).unwrap_or(false)
}

/// Parses SVG with no access to external files (only `data:` images) and the configured fonts.
pub(crate) fn parse_svg(data: &[u8]) -> Result<usvg::Tree> {
    let (db, family, _) = fonts();
    let opt = usvg::Options {
        fontdb: db,
        font_family: family,
        image_href_resolver: usvg::ImageHrefResolver {
            resolve_data: usvg::ImageHrefResolver::default_data_resolver(),
            resolve_string: Box::new(|_, _| None),
        },
        ..Default::default()
    };
    usvg::Tree::from_data(data, &opt).map_err(|e| anyhow!("svg: {e}"))
}

// ---------------------------------------------------------------------------------------------
// Compositing + cache
// ---------------------------------------------------------------------------------------------

pub(crate) enum Overlay<'a> {
    File(&'a Path),
    Svg(String),
}

pub(crate) struct Flattened {
    pub mime: &'static str,
    pub data: Vec<u8>,
    /// Width the image should be shown at, in CSS px (the original image's natural width).
    pub natural_width: u32,
}

/// FNV-1a, 64 bit: stable across runs and Rust versions (unlike `DefaultHasher`).
struct Fnv(u64);

impl Fnv {
    fn new() -> Self {
        Fnv(0xcbf29ce484222325)
    }
    fn bytes(&mut self, b: &[u8]) -> &mut Self {
        for &x in b {
            self.0 ^= x as u64;
            self.0 = self.0.wrapping_mul(0x100000001b3);
        }
        // field separator so ("ab","c") != ("a","bc")
        self.0 ^= 0xff;
        self.0 = self.0.wrapping_mul(0x100000001b3);
        self
    }
    fn u64(&mut self, v: u64) -> &mut Self {
        self.bytes(&v.to_le_bytes())
    }
}

fn hash_file_meta(h: &mut Fnv, p: &Path) -> Result<()> {
    let m = fs::metadata(p).with_context(|| format!("stat {}", p.display()))?;
    let mtime = m
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    h.bytes(name.as_bytes()).u64(m.len()).u64(mtime);
    Ok(())
}

fn cache_paths(cache_dir: &Path, key: u64) -> [(PathBuf, &'static str); 2] {
    [
        (cache_dir.join(format!("io-{key:016x}.jpg")), "image/jpeg"),
        (cache_dir.join(format!("io-{key:016x}.png")), "image/png"),
    ]
}

/// Natural width (CSS px) of the base, matched to the composite's orientation.
fn display_width(base: &Path, composite_w: u32, composite_h: u32) -> u32 {
    match image_dims(base) {
        Some((bw, bh)) => {
            if (composite_w >= composite_h) == (bw >= bh) || bw == bh {
                bw
            } else {
                bh
            }
        }
        None => composite_w,
    }
}

/// Draws `overlay` over `base`. Ok(None) if the overlay has nothing visible.
pub(crate) fn composite_cached(
    base: &Path,
    overlay: Overlay,
    cache_dir: &Path,
) -> Result<Option<Flattened>> {
    let mut h = Fnv::new();
    h.u64(CACHE_VERSION as u64).u64(MAX_COMPOSITE_SIDE as u64).u64(JPEG_QUALITY as u64);
    hash_file_meta(&mut h, base)?;
    let svg: Vec<u8> = match overlay {
        Overlay::File(p) => {
            h.bytes(b"file");
            hash_file_meta(&mut h, p)?;
            fs::read(p).with_context(|| format!("read {}", p.display()))?
        }
        Overlay::Svg(s) => {
            h.bytes(b"svg").bytes(s.as_bytes());
            s.into_bytes()
        }
    };
    // Text in a mask renders differently once fonts are configured.
    let (_, _, font_gen) = fonts();
    if contains_bytes(&svg, b"<text") {
        h.bytes(b"fonts").u64(font_gen);
    }
    let key = h.0;

    for (p, mime) in cache_paths(cache_dir, key) {
        if let Ok(data) = fs::read(&p) {
            if let Ok((w, hh)) = image::ImageReader::new(Cursor::new(&data))
                .with_guessed_format()
                .map_err(anyhow::Error::from)
                .and_then(|r| r.into_dimensions().map_err(anyhow::Error::from))
            {
                return Ok(Some(Flattened {
                    mime,
                    data,
                    natural_width: display_width(base, w, hh),
                }));
            }
        }
    }

    let tree = parse_svg(&svg)?;
    if !has_visible_content(tree.root()) {
        return Ok(None);
    }
    let (data, mime, natural_width) = render_composite(base, &tree)?;

    // cache (best effort)
    if fs::create_dir_all(cache_dir).is_ok() {
        let ext = if mime == "image/jpeg" { "jpg" } else { "png" };
        let final_path = cache_dir.join(format!("io-{key:016x}.{ext}"));
        let tmp = cache_dir.join(format!("io-{key:016x}.{ext}.tmp{}", std::process::id()));
        if fs::write(&tmp, &data).is_err() || fs::rename(&tmp, &final_path).is_err() {
            let _ = fs::remove_file(&tmp);
        }
    }
    Ok(Some(Flattened {
        mime,
        data,
        natural_width,
    }))
}

/// True if the group draws anything (IOE answer masks are often just empty `<g>`s).
fn has_visible_content(g: &usvg::Group) -> bool {
    g.children().iter().any(|n| match n {
        usvg::Node::Group(g) => has_visible_content(g),
        usvg::Node::Path(p) => p.is_visible() && (p.fill().is_some() || p.stroke().is_some()),
        usvg::Node::Image(i) => i.is_visible(),
        // without fonts a text node has no glyphs
        usvg::Node::Text(t) => has_visible_content(t.flattened()),
    })
}

fn contains_bytes(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

fn fit_within(w: u32, h: u32, max_side: u32) -> (u32, u32) {
    let long = w.max(h);
    if long <= max_side {
        return (w, h);
    }
    let s = max_side as f64 / long as f64;
    (
        ((w as f64 * s).round() as u32).max(1),
        ((h as f64 * s).round() as u32).max(1),
    )
}

fn swaps_dims(o: image::metadata::Orientation) -> bool {
    use image::metadata::Orientation::*;
    matches!(o, Rotate90 | Rotate270 | Rotate90FlipH | Rotate270FlipH)
}

/// Decodes the base, renders the SVG over it and encodes the result.
fn render_composite(base: &Path, tree: &usvg::Tree) -> Result<(Vec<u8>, &'static str, u32)> {
    let mut reader = image::ImageReader::open(base)?.with_guessed_format()?;
    let format = reader.format().ok_or_else(|| anyhow!("unknown image format"))?;
    let mut limits = image::Limits::default();
    limits.max_alloc = Some(384 * 1024 * 1024);
    limits.max_image_width = Some(16384);
    limits.max_image_height = Some(16384);
    reader.limits(limits);
    let mut decoder = reader.into_decoder()?;
    let orientation = decoder
        .orientation()
        .unwrap_or(image::metadata::Orientation::NoTransforms);
    let mut img = DynamicImage::from_decoder(decoder)?;

    let svg_size = tree.size();
    let (sw, sh) = (svg_size.width() as f64, svg_size.height() as f64);
    let svg_aspect = sw / sh;
    // Apply EXIF orientation if that is how the mask was drawn (browsers apply it).
    if orientation != image::metadata::Orientation::NoTransforms {
        let (w, h) = img.dimensions();
        let raw_aspect = w as f64 / h as f64;
        let oriented_aspect = if swaps_dims(orientation) {
            h as f64 / w as f64
        } else {
            raw_aspect
        };
        if (oriented_aspect - svg_aspect).abs() <= (raw_aspect - svg_aspect).abs() {
            img.apply_orientation(orientation);
        }
    }
    let (w, h) = img.dimensions();
    if w == 0 || h == 0 {
        return Err(anyhow!("empty image"));
    }
    let (tw, th) = fit_within(w, h, MAX_COMPOSITE_SIDE);
    if (tw, th) != (w, h) {
        img = img.thumbnail_exact(tw, th);
    }
    let had_alpha = img.color().has_alpha();
    let mut rgba = img.into_rgba8();

    // tiny-skia wants premultiplied RGBA
    let opaque_before = !had_alpha || rgba.pixels().all(|p| p.0[3] == 255);
    if !opaque_before {
        for p in rgba.pixels_mut() {
            let a = p.0[3] as u16;
            if a < 255 {
                for c in &mut p.0[..3] {
                    *c = ((*c as u16 * a + 127) / 255) as u8;
                }
            }
        }
    }

    // Map SVG user units onto the image: stretch when the aspect ratios agree (the normal
    // case: IOE masks are the image's size), otherwise 1 SVG unit = 1 original image pixel,
    // anchored top-left like the HTML overlay.
    let image_aspect = w as f64 / h as f64;
    let (sx, sy) = if (svg_aspect / image_aspect - 1.0).abs() < 0.01 {
        (tw as f64 / sw, th as f64 / sh)
    } else {
        let s = tw as f64 / w as f64;
        (s, s)
    };
    {
        let mut pm = tiny_skia::PixmapMut::from_bytes(rgba.as_mut(), tw, th)
            .ok_or_else(|| anyhow!("pixmap"))?;
        resvg::render(
            tree,
            tiny_skia::Transform::from_scale(sx as f32, sy as f32),
            &mut pm,
        );
    }

    let opaque = rgba.pixels().all(|p| p.0[3] == 255);
    if !opaque {
        for p in rgba.pixels_mut() {
            let a = p.0[3] as u16;
            if a > 0 && a < 255 {
                for c in &mut p.0[..3] {
                    *c = ((*c as u16 * 255 + a / 2) / a).min(255) as u8;
                }
            }
        }
    }

    let (data, mime) = if opaque {
        let rgb = DynamicImage::ImageRgba8(rgba).into_rgb8();
        // A non-JPEG base that compresses badly is a photo: JPEG straight away.
        let base_len = fs::metadata(base).map(|m| m.len()).unwrap_or(0);
        let photo_like = base_len as f64 / (w as f64 * h as f64) > 0.6;
        if format == ImageFormat::Jpeg || photo_like {
            (encode_jpeg(&rgb)?, "image/jpeg")
        } else {
            let png = encode_png(rgb.as_raw(), tw, th, image::ExtendedColorType::Rgb8)?;
            // Photos stored as PNG make huge payloads; use JPEG when it is much smaller.
            if png.len() > 1_000_000 {
                let jpg = encode_jpeg(&rgb)?;
                if jpg.len() * 2 < png.len() {
                    (jpg, "image/jpeg")
                } else {
                    (png, "image/png")
                }
            } else {
                (png, "image/png")
            }
        }
    } else {
        (
            encode_png(rgba.as_raw(), tw, th, image::ExtendedColorType::Rgba8)?,
            "image/png",
        )
    };
    Ok((data, mime, w))
}

fn encode_jpeg(rgb: &image::RgbImage) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, JPEG_QUALITY);
    enc.encode(
        rgb.as_raw(),
        rgb.width(),
        rgb.height(),
        image::ExtendedColorType::Rgb8,
    )?;
    Ok(out)
}

fn encode_png(raw: &[u8], w: u32, h: u32, color: image::ExtendedColorType) -> Result<Vec<u8>> {
    use image::ImageEncoder as _;
    let mut out = Vec::new();
    let enc = image::codecs::png::PngEncoder::new_with_quality(
        &mut out,
        // fdeflate: ~3x faster than the default level for ~3% bigger files
        image::codecs::png::CompressionType::Fast,
        image::codecs::png::FilterType::Adaptive,
    );
    enc.write_image(raw, w, h, color)?;
    Ok(out)
}

fn img_tag(f: &Flattened, opts: &PrepareOptions) -> String {
    let w = match opts.img_max_px {
        Some(m) if m > 0 => f.natural_width.min(m),
        _ => f.natural_width,
    };
    let b64 = base64::engine::general_purpose::STANDARD.encode(&f.data);
    format!(
        "<div class=\"kanki-io\"><img src=\"data:{};base64,{}\" width=\"{}\" alt=\"\"></div>",
        f.mime, b64, w
    )
}

fn keep_original(img_html: &str) -> String {
    format!("<div class=\"kanki-io\">{img_html}</div>")
}

/// Runs a per-image job, turning panics into errors so one bad file cannot take the card down.
fn guarded<T>(f: impl FnOnce() -> Result<T>) -> Result<T> {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(r) => r,
        Err(_) => Err(anyhow!("panic while compositing")),
    }
}

// ---------------------------------------------------------------------------------------------
// Image Occlusion Enhanced
// ---------------------------------------------------------------------------------------------

pub(crate) fn flatten_ioe(
    src: &str,
    media_dir: &Path,
    cache_dir: &Path,
    opts: &PrepareOptions,
) -> String {
    if !src.contains("io-wrapper") {
        return src.to_string();
    }
    let toks = tokenize(src);
    let mut edits = Vec::new();
    let mut i = 0;
    while i < toks.len() {
        let t = &toks[i];
        if t.is_start("div") && t.id_is("io-wrapper") {
            if let Some(close) = find_matching_end(&toks, i) {
                if let Some(rep) =
                    flatten_one_ioe(src, &toks[i + 1..close], media_dir, cache_dir, opts)
                {
                    edits.push((t.start, toks[close].end, rep));
                }
                i = close + 1;
                continue;
            }
        }
        i += 1;
    }
    html::apply_edits(src, edits)
}

fn first_img_in<'a, 'b>(toks: &'b [Token<'a>], id: &str) -> Option<Option<&'b Token<'a>>> {
    let pos = toks.iter().position(|t| t.is_start("div") && t.id_is(id))?;
    let end = find_matching_end(toks, pos).unwrap_or(toks.len());
    Some(toks[pos + 1..end].iter().find(|t| t.is_start("img")))
}

fn flatten_one_ioe(
    src: &str,
    inner: &[Token],
    media_dir: &Path,
    cache_dir: &Path,
    opts: &PrepareOptions,
) -> Option<String> {
    let base_img = match first_img_in(inner, "io-original") {
        Some(found) => found?,
        // no #io-original: take the first image outside the overlay
        None => {
            let ov = inner
                .iter()
                .position(|t| t.is_start("div") && t.id_is("io-overlay"));
            let ov_range = ov.map(|p| (p, find_matching_end(inner, p).unwrap_or(inner.len())));
            inner.iter().enumerate().find_map(|(k, t)| {
                let in_overlay = ov_range.map(|(a, b)| k > a && k < b).unwrap_or(false);
                (t.is_start("img") && !in_overlay).then_some(t)
            })?
        }
    };
    let base_html = &src[base_img.start..base_img.end];
    let base_path = resolve_media(media_dir, base_img.attr("src")?)?;
    let mask_img = first_img_in(inner, "io-overlay").flatten();
    let Some(mask_img) = mask_img else {
        return Some(keep_original(base_html));
    };
    let mask_src = mask_img.attr("src").unwrap_or("");
    if mask_src.trim().is_empty() {
        return Some(keep_original(base_html));
    }
    let mask_path = resolve_media(media_dir, mask_src)?;
    match guarded(|| composite_cached(&base_path, Overlay::File(&mask_path), cache_dir)) {
        Ok(Some(f)) => Some(img_tag(&f, opts)),
        Ok(None) => Some(keep_original(base_html)),
        Err(_) => None,
    }
}

// ---------------------------------------------------------------------------------------------
// Native Image Occlusion (Anki 23.10+)
// ---------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq)]
enum Role {
    /// `.cloze`: the shape being asked (question side), or ordinal 0 (always shown)
    Active,
    /// `.cloze-inactive`: other clozes; drawn only with occludeInactive
    Inactive,
    /// `.cloze-highlight`: the answered shape, outlined on the answer side
    Highlight,
}

#[derive(Debug, Clone)]
enum Geometry {
    Rect { w: f64, h: f64 },
    Ellipse { rx: f64, ry: f64 },
    Polygon { points: Vec<(f64, f64)>, has_pos: bool },
    Text { text: String, scale: f64, font_size: Option<f64> },
}

#[derive(Debug, Clone)]
struct Shape {
    role: Role,
    geom: Geometry,
    left: f64,
    top: f64,
    /// degrees
    angle: f64,
    fill: Option<String>,
    occlude_inactive: bool,
}

// Desktop defaults (ts/routes/image-occlusion/review.ts, notetype.css)
const ACTIVE_FILL: &str = "#ff8e8e";
const INACTIVE_FILL: &str = "#ffeba2";
const BORDER: &str = "#212121";
const HIGHLIGHT_BORDER: &str = "#ff8e8e";
const TEXT_BG: &str = "#ffffff";
const TEXT_FONT_SIZE: f64 = 40.0;
const TEXT_PADDING: f64 = 5.0;

fn num(t: &Token, name: &str) -> Option<f64> {
    t.attr_decoded(name)
        .and_then(|v| v.trim().parse::<f64>().ok())
        .filter(|v| v.is_finite())
}

fn parse_shape(t: &Token, role: Role) -> Option<Shape> {
    let kind = t.attr("data-shape")?.trim().to_ascii_lowercase();
    let left = num(t, "data-left");
    let top = num(t, "data-top");
    // stored angle is in 1/10000ths of a turn
    let angle = num(t, "data-angle")
        .map(|a| (a % 10000.0) / 10000.0 * 360.0)
        .unwrap_or(0.0);
    let geom = match kind.as_str() {
        "rect" => Geometry::Rect {
            w: num(t, "data-width").unwrap_or(0.0),
            h: num(t, "data-height").unwrap_or(0.0),
        },
        "ellipse" => Geometry::Ellipse {
            rx: num(t, "data-rx").unwrap_or(0.0),
            ry: num(t, "data-ry").unwrap_or(0.0),
        },
        "polygon" => {
            let pts = t.attr_decoded("data-points").unwrap_or_default();
            let points: Vec<(f64, f64)> = pts
                .split_ascii_whitespace()
                .filter_map(|p| {
                    let (x, y) = p.split_once(',')?;
                    let (x, y) = (x.trim().parse::<f64>().ok()?, y.trim().parse::<f64>().ok()?);
                    (x.is_finite() && y.is_finite()).then_some((x, y))
                })
                .collect();
            if points.len() < 2 {
                return None;
            }
            Geometry::Polygon {
                points,
                has_pos: left.is_some() && top.is_some(),
            }
        }
        "text" => Geometry::Text {
            text: t
                .attr_decoded("data-text")
                .map(|s| s.into_owned())
                .unwrap_or_default(),
            scale: num(t, "data-scale").filter(|s| *s > 0.0).unwrap_or(1.0),
            font_size: num(t, "data-font-size").filter(|s| *s > 0.0),
        },
        _ => return None,
    };
    Some(Shape {
        role,
        geom,
        left: left.unwrap_or(0.0),
        top: top.unwrap_or(0.0),
        angle,
        fill: t
            .attr_decoded("data-fill")
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()),
        occlude_inactive: t.attr("data-occludeinactive").map(|v| v.trim() == "1").unwrap_or(false),
    })
}

fn xml_escape(s: &str) -> String {
    html::escape_attr(s).replace('\'', "&apos;")
}

/// Builds an SVG overlay (in the image's pixel space) reproducing desktop's canvas drawing.
fn native_io_svg(shapes: &[Shape], w: u32, h: u32) -> String {
    let (wf, hf) = (w as f64, h as f64);
    // desktop draws 1 canvas px borders at screen resolution; scale up for big images
    let border = (wf.max(hf) / 800.0).max(1.0);
    let highlight = (wf.max(hf) / 400.0).max(2.0);
    let draw_text = have_fonts();
    let mut s = String::new();
    let _ = write!(
        s,
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">"#
    );
    let ordered = shapes
        .iter()
        .filter(|s| s.role == Role::Active)
        .chain(
            shapes
                .iter()
                .filter(|s| s.role == Role::Inactive && s.occlude_inactive),
        )
        .chain(shapes.iter().filter(|s| s.role == Role::Highlight));
    for sh in ordered {
        let (fill, stroke, sw) = match sh.role {
            Role::Active => (ACTIVE_FILL.to_string(), BORDER, border),
            Role::Inactive => (
                sh.fill
                    .clone()
                    .filter(|f| !f.eq_ignore_ascii_case(INACTIVE_FILL))
                    .unwrap_or_else(|| INACTIVE_FILL.to_string()),
                BORDER,
                border,
            ),
            Role::Highlight => ("none".to_string(), HIGHLIGHT_BORDER, highlight),
        };
        let fill = xml_escape(&fill);
        let left = (sh.left * wf).round();
        let top = (sh.top * hf).round();
        let rot = if sh.angle != 0.0 {
            format!(r#" transform="rotate({} {} {})""#, sh.angle, left, top)
        } else {
            String::new()
        };
        match &sh.geom {
            Geometry::Rect { w: rw, h: rh } => {
                let _ = write!(
                    s,
                    r#"<rect x="{left}" y="{top}" width="{}" height="{}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{rot}/>"#,
                    (rw * wf).round(),
                    (rh * hf).round()
                );
            }
            Geometry::Ellipse { rx, ry } => {
                let (rx, ry) = ((rx * wf).round(), (ry * hf).round());
                let _ = write!(
                    s,
                    r#"<ellipse cx="{}" cy="{}" rx="{rx}" ry="{ry}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{rot}/>"#,
                    left + rx,
                    top + ry
                );
            }
            Geometry::Polygon { points, has_pos } => {
                let abs: Vec<(f64, f64)> = points
                    .iter()
                    .map(|(x, y)| ((x * wf).round(), (y * hf).round()))
                    .collect();
                let (minx, miny) = abs.iter().fold((f64::MAX, f64::MAX), |(a, b), (x, y)| {
                    (a.min(*x), b.min(*y))
                });
                let (ox, oy) = if *has_pos {
                    (left - minx, top - miny)
                } else {
                    (0.0, 0.0)
                };
                let pts: Vec<String> = abs
                    .iter()
                    .map(|(x, y)| format!("{},{}", x + ox, y + oy))
                    .collect();
                let _ = write!(
                    s,
                    r#"<polygon points="{}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}" stroke-linejoin="round"/>"#,
                    pts.join(" ")
                );
            }
            Geometry::Text {
                text,
                scale,
                font_size,
            } => {
                if !draw_text || text.trim().is_empty() {
                    continue;
                }
                let fs = font_size.map(|f| f * hf).unwrap_or(TEXT_FONT_SIZE) * scale;
                let lines: Vec<&str> = text.split('\n').collect();
                let line_h = fs * 1.07;
                let longest = lines.iter().map(|l| l.chars().count()).max().unwrap_or(0) as f64;
                let pad = TEXT_PADDING * scale;
                let color = xml_escape(sh.fill.as_deref().unwrap_or("#000000"));
                let _ = write!(
                    s,
                    r#"<g{rot}><rect x="{left}" y="{top}" width="{}" height="{}" fill="{TEXT_BG}"/>"#,
                    longest * fs * 0.56 + pad,
                    line_h * lines.len() as f64 + pad
                );
                for (k, line) in lines.iter().enumerate() {
                    let _ = write!(
                        s,
                        r#"<text x="{left}" y="{}" font-family="Arial, sans-serif" font-size="{fs}" fill="{color}" xml:space="preserve">{}</text>"#,
                        top + k as f64 * line_h + fs * 0.9,
                        xml_escape(line)
                    );
                }
                s.push_str("</g>");
            }
        }
    }
    s.push_str("</svg>");
    s
}

pub(crate) fn flatten_native_io(
    src: &str,
    media_dir: &Path,
    cache_dir: &Path,
    opts: &PrepareOptions,
) -> String {
    if !src.contains("image-occlusion-container") {
        return src.to_string();
    }
    let toks = tokenize(src);
    let mut shapes = Vec::new();
    let mut shape_divs = Vec::new();
    for (k, t) in toks.iter().enumerate() {
        if !t.is_start("div") || t.attr("data-shape").is_none() {
            continue;
        }
        let role = if t.has_class("cloze") {
            Role::Active
        } else if t.has_class("cloze-inactive") {
            Role::Inactive
        } else if t.has_class("cloze-highlight") {
            Role::Highlight
        } else {
            continue;
        };
        if let Some(sh) = parse_shape(t, role) {
            shapes.push(sh);
        }
        let end = match toks.get(k + 1) {
            Some(n) if n.is_end("div") => n.end,
            _ => t.end,
        };
        shape_divs.push((t.start, end));
    }

    let mut edits: Vec<(usize, usize, String)> = Vec::new();
    let mut i = 0;
    while i < toks.len() {
        let t = &toks[i];
        if t.is_start("div") && t.id_is("image-occlusion-container") {
            if let Some(close) = find_matching_end(&toks, i) {
                if let Some(img) = toks[i + 1..close].iter().find(|x| x.is_start("img")) {
                    let img_html = &src[img.start..img.end];
                    let rep = img.attr("src").and_then(|s| resolve_media(media_dir, s)).and_then(
                        |base| {
                            if shapes.is_empty() {
                                return Some(keep_original(img_html));
                            }
                            let (w, h) = image_dims(&base)?;
                            let svg = native_io_svg(&shapes, w, h);
                            match guarded(|| composite_cached(&base, Overlay::Svg(svg), cache_dir))
                            {
                                Ok(Some(f)) => Some(img_tag(&f, opts)),
                                Ok(None) => Some(keep_original(img_html)),
                                Err(_) => None,
                            }
                        },
                    );
                    if let Some(rep) = rep {
                        edits.push((t.start, toks[close].end, rep));
                    }
                }
                i = close + 1;
                continue;
            }
        }
        i += 1;
    }
    if !edits.is_empty() {
        // the shape data is now baked into the image; drop the (hidden) shape divs. Any inside a
        // replaced container overlap it and are skipped by apply_edits.
        for &(a, b) in &shape_divs {
            edits.push((a, b, String::new()));
        }
    }
    html::apply_edits(src, edits)
}

#[cfg(test)]
pub(crate) fn test_native_io_svg(html: &str, w: u32, h: u32) -> String {
    let toks = tokenize(html);
    let shapes: Vec<Shape> = toks
        .iter()
        .filter(|t| t.is_start("div") && t.attr("data-shape").is_some())
        .filter_map(|t| {
            let role = if t.has_class("cloze") {
                Role::Active
            } else if t.has_class("cloze-inactive") {
                Role::Inactive
            } else {
                Role::Highlight
            };
            parse_shape(t, role)
        })
        .collect();
    native_io_svg(&shapes, w, h)
}
