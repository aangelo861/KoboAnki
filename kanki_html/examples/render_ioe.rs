//! Renders Image Occlusion Enhanced notes through `prepare_card_html` so the flattened images
//! can be eyeballed.
//!
//! ```text
//! cargo run --release -p kanki_html --example render_ioe -- \
//!     --col collection.anki2 --media collection.media --out /tmp/ioe [--max-px 700] [--fonts] NOTE_ID...
//! cargo run --release -p kanki_html --example render_ioe -- --col ... --media ... --out ... --all
//! ```
//! `--col`/`--media` default to `$KANKI_TEST_COL`/`$KANKI_TEST_MEDIA`. The collection is read with
//! the `sqlite3` command-line tool (read-only, `immutable=1`), so no SQLite crate is needed.
//! Per note it writes `<id>-q.html`, `<id>-a.html` and the decoded composites `<id>-q.jpg|png`.
//! `--native IMAGE` renders a demo note of Anki's native Image Occlusion on a media image instead;
//! `--css FILE` prints `prepare_css` of a CSS file.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

use base64::Engine as _;
use kanki_html::{prepare_card_html, PrepareOptions};

const IOE_NOTETYPE: &str = "1593689915064";

fn main() {
    if let Err(e) = run() {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let mut col = std::env::var("KANKI_TEST_COL").ok().map(PathBuf::from);
    let mut media = std::env::var("KANKI_TEST_MEDIA").ok().map(PathBuf::from);
    let mut out = PathBuf::from("ioe-out");
    let mut max_px: Option<u32> = Some(700);
    let mut all = false;
    let mut native: Option<String> = None;
    let mut ids: Vec<String> = Vec::new();
    while let Some(a) = args.next() {
        match a.as_str() {
            "--col" => col = args.next().map(PathBuf::from),
            "--media" => media = args.next().map(PathBuf::from),
            "--out" => out = args.next().map(PathBuf::from).ok_or("--out needs a value")?,
            "--max-px" => {
                max_px = args.next().and_then(|v| v.parse().ok()).filter(|&v: &u32| v > 0)
            }
            "--fonts" => kanki_html::load_system_fonts(),
            "--all" => all = true,
            "--native" => native = args.next(),
            "--css" => {
                // debugging aid: print prepare_css() of a CSS file
                let f = args.next().ok_or("--css needs a file")?;
                let css = std::fs::read_to_string(&f).map_err(|e| e.to_string())?;
                print!("{}", kanki_html::prepare_css(&css));
                return Ok(());
            }
            _ if a.chars().all(|c| c.is_ascii_digit()) => ids.push(a),
            _ => return Err(format!("unknown argument {a}")),
        }
    }
    let media = media.ok_or("need --media or KANKI_TEST_MEDIA")?;
    std::fs::create_dir_all(&out).map_err(|e| e.to_string())?;
    let cache = out.join("cache");
    let opts = PrepareOptions { img_max_px: max_px };
    if let Some(image) = native {
        return native_demo(&image, &media, &out, &cache, &opts);
    }
    let col = col.ok_or("need --col or KANKI_TEST_COL")?;

    if all {
        ids = sql(&col, &format!("select id from notes where mid={IOE_NOTETYPE} order by id"))?;
    }
    if ids.is_empty() {
        return Err("no note ids given".into());
    }

    let mut slowest: Vec<(f64, String)> = Vec::new();
    let mut cold = Vec::new();
    let mut warm = Vec::new();
    let mut sizes = Vec::new();
    let mut problems = Vec::new();
    for id in &ids {
        let hex = sql(&col, &format!("select hex(flds) from notes where id={id}"))?;
        let Some(hex) = hex.first() else {
            problems.push(format!("{id}: no such note"));
            continue;
        };
        let flds = String::from_utf8_lossy(&unhex(hex)).into_owned();
        let f: Vec<&str> = flds.split('\x1f').collect();
        let get = |i: usize| f.get(i).copied().unwrap_or("");
        let (q, a) = ioe_card(get(1), get(2), get(3), get(4), get(9), [get(5), get(6), get(7), get(8)]);
        for (side, html) in [("q", q), ("a", a)] {
            let t = Instant::now();
            let res = prepare_card_html(&html, &media, &cache, &opts);
            let ms_cold = t.elapsed().as_secs_f64() * 1000.0;
            let t = Instant::now();
            let res2 = prepare_card_html(&html, &media, &cache, &opts);
            let ms_warm = t.elapsed().as_secs_f64() * 1000.0;
            if res != res2 {
                problems.push(format!("{id}-{side}: cached output differs"));
            }
            let uri = data_uri(&res);
            let mask_field = if side == "q" { get(3) } else { get(9) };
            match &uri {
                Some((mime, bytes)) => {
                    cold.push(ms_cold);
                    slowest.push((ms_cold, format!("{id}-{side} {mime} {} KB", bytes.len() / 1024)));
                    warm.push(ms_warm);
                    sizes.push(bytes.len());
                    if !all {
                        let ext = if mime == "image/jpeg" { "jpg" } else { "png" };
                        let p = out.join(format!("{id}-{side}.{ext}"));
                        std::fs::write(&p, bytes).map_err(|e| e.to_string())?;
                        let dims = image::load_from_memory(bytes)
                            .map(|i| (i.width(), i.height()))
                            .unwrap_or((0, 0));
                        println!(
                            "{id} {side}: {:>7.1} ms cold, {:>5.2} ms cached, {} {}x{}, {} KB image, {} KB html -> {}",
                            ms_cold,
                            ms_warm,
                            mime,
                            dims.0,
                            dims.1,
                            bytes.len() / 1024,
                            res.len() / 1024,
                            p.display()
                        );
                    }
                }
                None => {
                    if res.contains("io-wrapper") {
                        problems.push(format!("{id}-{side}: not flattened (mask {mask_field:?})"));
                    } else if !all {
                        println!("{id} {side}: {ms_cold:>7.1} ms, mask empty -> original image kept");
                    }
                }
            }
            if !all {
                std::fs::write(out.join(format!("{id}-{side}.html")), &res).map_err(|e| e.to_string())?;
            }
        }
    }
    if !cold.is_empty() {
        let stats = |v: &mut Vec<f64>| {
            v.sort_by(|a, b| a.partial_cmp(b).unwrap());
            let mean = v.iter().sum::<f64>() / v.len() as f64;
            format!(
                "mean {:.1} / median {:.1} / p95 {:.1} / max {:.1} ms",
                mean,
                v[v.len() / 2],
                v[(v.len() * 95 / 100).min(v.len() - 1)],
                v[v.len() - 1]
            )
        };
        sizes.sort();
        let total: usize = sizes.iter().sum();
        println!(
            "\n{} composites from {} notes\n  cold:   {}\n  cached: {}\n  image bytes: mean {} KB, median {} KB, max {} KB (data URI is 4/3 of that), total {} MB",
            cold.len(),
            ids.len(),
            stats(&mut cold),
            stats(&mut warm),
            total / sizes.len() / 1024,
            sizes[sizes.len() / 2] / 1024,
            sizes[sizes.len() - 1] / 1024,
            total / 1024 / 1024
        );
    }
    if all {
        slowest.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap());
        println!("  slowest:");
        for (ms, what) in slowest.iter().take(8) {
            println!("    {ms:>7.1} ms  {what}");
        }
    }
    if problems.is_empty() {
        println!("no problems");
    } else {
        println!("{} problems:", problems.len());
        for p in &problems {
            println!("  {p}");
        }
    }
    Ok(())
}

/// Anki's native Image Occlusion: renders cards 1 and 2 of a demo note on `image` the way
/// rslib does (stock template + `{{cloze:Occlusion}}`), with rect/ellipse/polygon shapes.
fn native_demo(
    image: &str,
    media: &Path,
    out: &Path,
    cache: &Path,
    opts: &PrepareOptions,
) -> Result<(), String> {
    // (ordinals, shape spec) as stored in the Occlusion field
    let occlusions = [
        (1, "rect:left=.075:top=.455:width=.21:height=.05:oi=1"),
        (2, "ellipse:left=.62:top=-.01:width=.27:height=.06:rx=.135:ry=.03:oi=1"),
        (3, "polygon:left=.445:top=.94:points=.445,.94 .565,.94 .565,1 .445,1:oi=1"),
        (4, "rect:left=.55:top=.25:width=.15:height=.05:angle=500:fill=#7fb3ff:oi=1"),
    ];
    for card in [1u16, 2] {
        for question in [true, false] {
            let mut clozes = String::new();
            for (ord, spec) in occlusions {
                let active = ord == card;
                let class = if question && active {
                    "cloze"
                } else if !active {
                    "cloze-inactive"
                } else {
                    "cloze-highlight"
                };
                clozes.push_str(&format!(
                    r#"<div class="{class}" data-ordinal="{ord}" {}></div>"#,
                    cloze_data(spec)
                ));
            }
            let q = format!(
                r#"<div>Native IO demo</div>
<div style="display: none">{clozes}</div>
<div id="err"></div>
<div id="image-occlusion-container">
    <img src="{image}">
    <canvas id="image-occlusion-canvas"></canvas>
</div>
<script>
try {{ anki.imageOcclusion.setup(); }} catch (exc) {{ document.getElementById("err").innerHTML = `${{exc}}`; }}
</script>
"#
            );
            let html = if question {
                q
            } else {
                format!("{q}\n<div><button id=\"toggle\">Toggle Masks</button></div>\n")
            };
            let t = Instant::now();
            let res = prepare_card_html(&html, media, cache, opts);
            let ms = t.elapsed().as_secs_f64() * 1000.0;
            let side = if question { "q" } else { "a" };
            let name = format!("native-c{card}-{side}");
            std::fs::write(out.join(format!("{name}.html")), &res).map_err(|e| e.to_string())?;
            match data_uri(&res) {
                Some((mime, bytes)) => {
                    let ext = if mime == "image/jpeg" { "jpg" } else { "png" };
                    let p = out.join(format!("{name}.{ext}"));
                    std::fs::write(&p, &bytes).map_err(|e| e.to_string())?;
                    println!("{name}: {ms:.1} ms, {} KB -> {}", bytes.len() / 1024, p.display());
                }
                None => println!("{name}: {ms:.1} ms, not flattened"),
            }
        }
    }
    Ok(())
}

/// Mirrors rslib's `get_image_cloze_data` for the demo.
fn cloze_data(spec: &str) -> String {
    let mut parts = spec.split(':');
    let shape = parts.next().unwrap_or("");
    let mut out = format!(r#"data-shape="{shape}" "#);
    for p in parts {
        if let Some((k, v)) = p.split_once('=') {
            let k = match k {
                "oi" => "occludeInactive",
                k => k,
            };
            out.push_str(&format!(r#"data-{k}="{v}" "#));
        }
    }
    out
}

/// The user's IOE templates (front/back) with the fields substituted.
fn ioe_card(
    header: &str,
    image: &str,
    qmask: &str,
    footer: &str,
    amask: &str,
    extras: [&str; 4],
) -> (String, String) {
    let script = r#"<script>
// Prevent original image from loading before mask
aFade = 50, qFade = 0;
var mask = document.querySelector('#io-overlay>img');
function loaded() {
    var original = document.querySelector('#io-original');
    original.style.visibility = "visible";
}
if (mask === null || mask.complete) {
    loaded();
} else {
    mask.addEventListener('load', loaded);
}
</script>"#;
    if image.is_empty() {
        return (String::new(), String::new());
    }
    let q = format!(
        r#"
<div id="io-header">{header}</div>
<div id="io-wrapper">
  <div id="io-overlay">{qmask}</div>
  <div id="io-original">{image}</div>
</div>
<div id="io-footer">{footer}</div>

{script}
"#
    );
    let footer_html = if footer.is_empty() {
        String::new()
    } else {
        format!(r#"<div id="io-footer">{footer}</div>"#)
    };
    let mut extra = String::new();
    for (name, v) in ["Remarks", "Sources", "Extra 1", "Extra 2"].iter().zip(extras) {
        if !v.is_empty() {
            extra.push_str(&format!(
                r#"<div class="io-extra-entry"><div class="io-field-descr">{name}</div>{v}</div>"#
            ));
        }
    }
    let a = format!(
        r#"
<div id="io-header">{header}</div>
<div id="io-wrapper">
  <div id="io-overlay">{amask}</div>
  <div id="io-original">{image}</div>
</div>
{footer_html}
<button id="io-revl-btn" onclick="toggle();">Toggle Masks</button>
<div id="io-extra-wrapper"><div id="io-extra">{extra}</div></div>
{script}
"#
    );
    (q, a)
}

fn sql(col: &Path, query: &str) -> Result<Vec<String>, String> {
    let uri = format!("file:{}?immutable=1", col.display());
    let out = Command::new("sqlite3")
        .arg("-readonly")
        .arg("-noheader")
        .arg(&uri)
        .arg(query)
        .output()
        .map_err(|e| format!("running sqlite3: {e}"))?;
    if !out.status.success() {
        return Err(format!("sqlite3: {}", String::from_utf8_lossy(&out.stderr)));
    }
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect())
}

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2)
        .filter_map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).ok())
        .collect()
}

fn data_uri(html: &str) -> Option<(String, Vec<u8>)> {
    let start = html.find("src=\"data:")? + 10;
    let rest = &html[start..];
    let uri = &rest[..rest.find('"')?];
    let (mime, b64) = uri.split_once(";base64,")?;
    let bytes = base64::engine::general_purpose::STANDARD.decode(b64).ok()?;
    Some((mime.to_string(), bytes))
}
