use std::path::{Path, PathBuf};

use base64::Engine as _;
use image::{GenericImageView, Rgb, RgbImage, Rgba, RgbaImage};

use super::*;

/// A fresh, empty scratch dir per test.
fn scratch(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("kanki_html_test_{}_{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn write_jpeg(path: &Path, w: u32, h: u32, color: [u8; 3]) {
    let img = RgbImage::from_pixel(w, h, Rgb(color));
    img.save_with_format(path, image::ImageFormat::Jpeg).unwrap();
}

fn ioe_html(header: &str, mask: &str, image: &str) -> String {
    format!(
        r#"<div id="io-header">{header}</div>
<div id="io-wrapper">
  <div id="io-overlay">{mask}</div>
  <div id="io-original">{image}</div>
</div>
<div id="io-footer"></div>
<script>
var mask = document.querySelector('#io-overlay>img');
</script>"#
    )
}

const MASK_SVG: &str = r##"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100">
 <!-- Created with Image Occlusion Enhanced -->
 <g><title>Labels</title></g>
 <g><title>Masks</title>
  <rect id="x-oa-1" height="20" width="40" y="25" x="50" stroke="#2D2D2D" fill="#FF7E7E" class="qshape"/>
 </g>
</svg>"##;

const EMPTY_SVG: &str = r##"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100">
 <g><title>Labels</title></g>
 <g><title>Masks</title>


 </g>
</svg>"##;

/// Extracts and decodes the first data: URI image in `html`.
fn data_uri_image(html: &str) -> Option<(String, image::DynamicImage)> {
    let start = html.find("src=\"data:")? + 10;
    let rest = &html[start..];
    let end = rest.find('"')?;
    let uri = &rest[..end];
    let (mime, b64) = uri.split_once(";base64,")?;
    let bytes = base64::engine::general_purpose::STANDARD.decode(b64).ok()?;
    Some((mime.to_string(), image::load_from_memory(&bytes).ok()?))
}

fn close(a: [u8; 3], b: [u8; 3], tol: i32) -> bool {
    a.iter()
        .zip(b.iter())
        .all(|(x, y)| (*x as i32 - *y as i32).abs() <= tol)
}

fn px(img: &image::DynamicImage, x: u32, y: u32) -> [u8; 3] {
    let p = img.get_pixel(x, y).0;
    [p[0], p[1], p[2]]
}

#[test]
fn ioe_mask_is_composited_onto_jpeg() {
    let dir = scratch("ioe_jpeg");
    let media = dir.join("media");
    let cache = dir.join("cache");
    std::fs::create_dir_all(&media).unwrap();
    write_jpeg(&media.join("photo one.jpg"), 200, 100, [0, 0, 255]);
    std::fs::write(media.join("m-oa-1-Q.svg"), MASK_SVG).unwrap();
    let html = ioe_html(
        "Name it",
        r#"<img src="m-oa-1-Q.svg" />"#,
        r#"<img src="photo%20one.jpg" />"#,
    );
    let out = prepare_card_html(&html, &media, &cache, &PrepareOptions { img_max_px: Some(150) });
    assert!(!out.contains("<script"), "{out}");
    assert!(!out.contains("io-wrapper"), "{out}");
    assert!(!out.contains("m-oa-1-Q.svg"), "{out}");
    assert!(out.contains("Name it"));
    assert!(out.contains("width=\"150\""), "{}", &out[..300.min(out.len())]);
    let (mime, img) = data_uri_image(&out).expect("data uri");
    assert_eq!(mime, "image/jpeg");
    assert_eq!(img.dimensions(), (200, 100));
    // inside the rect: mask colour; outside: the photo
    assert!(close(px(&img, 70, 35), [0xff, 0x7e, 0x7e], 24), "{:?}", px(&img, 70, 35));
    assert!(close(px(&img, 10, 10), [0, 0, 255], 24), "{:?}", px(&img, 10, 10));
    assert!(close(px(&img, 150, 80), [0, 0, 255], 24));
    // edges of the rect land where the SVG says (x 50..90, y 25..45)
    assert!(close(px(&img, 47, 35), [0, 0, 255], 40), "{:?}", px(&img, 47, 35));
    assert!(close(px(&img, 53, 35), [0xff, 0x7e, 0x7e], 40), "{:?}", px(&img, 53, 35));
    assert!(close(px(&img, 70, 22), [0, 0, 255], 40));
    assert!(close(px(&img, 70, 48), [0, 0, 255], 40));

    // cached: one file, identical output on the second call
    let cached: Vec<_> = std::fs::read_dir(&cache).unwrap().collect();
    assert_eq!(cached.len(), 1);
    let again = prepare_card_html(&html, &media, &cache, &PrepareOptions { img_max_px: Some(150) });
    assert_eq!(out, again);
    // without a width cap the natural width is used
    let natural = prepare_card_html(&html, &media, &cache, &PrepareOptions::default());
    assert!(natural.contains("width=\"200\""));
}

#[test]
fn ioe_empty_or_missing_mask_keeps_original() {
    let dir = scratch("ioe_empty");
    let media = dir.join("media");
    std::fs::create_dir_all(&media).unwrap();
    write_jpeg(&media.join("p.jpg"), 200, 100, [0, 255, 0]);
    std::fs::write(media.join("e-A.svg"), EMPTY_SVG).unwrap();
    let opts = PrepareOptions::default();

    let out = prepare_card_html(
        &ioe_html("", r#"<img src="e-A.svg">"#, r#"<img src="p.jpg">"#),
        &media,
        &dir.join("c"),
        &opts,
    );
    assert!(out.contains(r#"<img src="p.jpg">"#), "{out}");
    assert!(!out.contains("data:"));
    assert!(!out.contains("e-A.svg"));

    let out = prepare_card_html(&ioe_html("", "", r#"<img src="p.jpg">"#), &media, &dir.join("c"), &opts);
    assert!(out.contains(r#"<img src="p.jpg">"#), "{out}");
    assert!(!out.contains("io-overlay"));

    // missing mask file: left as is
    let html = ioe_html("", r#"<img src="nope.svg">"#, r#"<img src="p.jpg">"#);
    let out = prepare_card_html(&html, &media, &dir.join("c"), &opts);
    assert!(out.contains("io-wrapper") && out.contains("nope.svg"));

    // missing base: left as is
    let html = ioe_html("", r#"<img src="e-A.svg">"#, r#"<img src="gone.jpg">"#);
    let out = prepare_card_html(&html, &media, &dir.join("c"), &opts);
    assert!(out.contains("io-wrapper") && out.contains("gone.jpg"));

    // corrupt base: left as is, no panic
    std::fs::write(media.join("bad.png"), b"\x89PNG\r\n\x1a\nnot really").unwrap();
    std::fs::write(media.join("m.svg"), MASK_SVG).unwrap();
    let html = ioe_html("", r#"<img src="m.svg">"#, r#"<img src="bad.png">"#);
    let out = prepare_card_html(&html, &media, &dir.join("c"), &opts);
    assert!(out.contains("io-wrapper") && out.contains("bad.png"));

    // corrupt svg
    std::fs::write(media.join("bad.svg"), b"<svg width='10'").unwrap();
    let html = ioe_html("", r#"<img src="bad.svg">"#, r#"<img src="p.jpg">"#);
    let out = prepare_card_html(&html, &media, &dir.join("c"), &opts);
    assert!(out.contains("io-wrapper"));
}

#[test]
fn ioe_transparent_png_and_large_image() {
    let dir = scratch("ioe_png");
    let media = dir.join("media");
    std::fs::create_dir_all(&media).unwrap();
    // transparent PNG base -> PNG output keeping alpha outside the mask
    let mut img = RgbaImage::from_pixel(200, 100, Rgba([0, 0, 0, 0]));
    img.put_pixel(5, 5, Rgba([10, 20, 30, 255]));
    img.save(media.join("t.png")).unwrap();
    std::fs::write(media.join("m.svg"), MASK_SVG).unwrap();
    let html = ioe_html("", r#"<img src="m.svg">"#, r#"<img src="t.png">"#);
    let out = prepare_card_html(&html, &media, &dir.join("c"), &PrepareOptions::default());
    let (mime, out_img) = data_uri_image(&out).unwrap();
    assert_eq!(mime, "image/png");
    assert_eq!(out_img.get_pixel(150, 80).0[3], 0);
    assert_eq!(out_img.get_pixel(70, 35).0, [0xff, 0x7e, 0x7e, 0xff]);
    assert_eq!(out_img.get_pixel(5, 5).0, [10, 20, 30, 255]);

    // a big image is scaled to MAX_COMPOSITE_SIDE, mask scaled with it
    write_jpeg(&media.join("big.jpg"), 3000, 1500, [255, 255, 255]);
    let svg = r##"<svg xmlns="http://www.w3.org/2000/svg" width="3000" height="1500"><rect x="1500" y="750" width="1500" height="750" fill="#000"/></svg>"##;
    std::fs::write(media.join("big.svg"), svg).unwrap();
    let html = ioe_html("", r#"<img src="big.svg">"#, r#"<img src="big.jpg">"#);
    let out = prepare_card_html(&html, &media, &dir.join("c"), &PrepareOptions { img_max_px: Some(600) });
    assert!(out.contains("width=\"600\""));
    let (_, out_img) = data_uri_image(&out).unwrap();
    assert_eq!(out_img.dimensions(), (2000, 1000));
    assert!(close(px(&out_img, 990, 490), [255, 255, 255], 10));
    assert!(close(px(&out_img, 1010, 510), [0, 0, 0], 10));
}

#[test]
fn native_io_question_and_answer() {
    let dir = scratch("native_io");
    let media = dir.join("media");
    std::fs::create_dir_all(&media).unwrap();
    write_jpeg(&media.join("io.jpg"), 400, 200, [255, 255, 255]);
    // as rendered by rslib (cloze.rs render_image_occlusion), question side of card 1
    let shapes_q = r#"<div class="cloze" data-ordinal="1" data-shape="rect" data-left=".1" data-top=".1" data-width=".2" data-height=".2" data-occludeInactive="1" ></div><div class="cloze-inactive" data-ordinal="2" data-shape="ellipse" data-left=".5" data-top=".5" data-width=".2" data-height=".2" data-rx=".1" data-ry=".2" data-occludeInactive="1" ></div><div class="cloze-inactive" data-ordinal="3" data-shape="polygon" data-left=".8" data-top=".0" data-points=".8,0 1,0 1,.3" ></div>"#;
    let template = |shapes: &str| {
        format!(
            r#"<div>Header</div>
<div style="display: none">{shapes}</div>
<div id="err"></div>
<div id="image-occlusion-container">
    <img src="io.jpg">
    <canvas id="image-occlusion-canvas"></canvas>
</div>
<script>
try {{ anki.imageOcclusion.setup(); }} catch (exc) {{ }}
</script>"#
        )
    };
    let out = prepare_card_html(&template(shapes_q), &media, &dir.join("c"), &PrepareOptions::default());
    assert!(!out.contains("canvas") && !out.contains("<script") && !out.contains("data-shape"), "{out}");
    let (_, img) = data_uri_image(&out).expect("composite");
    assert_eq!(img.dimensions(), (400, 200));
    // active rect: x 40..120, y 20..60
    assert!(close(px(&img, 80, 40), [0xff, 0x8e, 0x8e], 20), "{:?}", px(&img, 80, 40));
    // inactive ellipse with occludeInactive: centre (200+40, 100+40)
    assert!(close(px(&img, 240, 140), [0xff, 0xeb, 0xa2], 20), "{:?}", px(&img, 240, 140));
    // inactive polygon without occludeInactive: not drawn
    assert!(close(px(&img, 390, 10), [255, 255, 255], 10), "{:?}", px(&img, 390, 10));
    assert!(close(px(&img, 10, 190), [255, 255, 255], 10));

    // answer side: the active shape becomes a highlight outline only
    let shapes_a = shapes_q.replacen("class=\"cloze\"", "class=\"cloze-highlight\"", 1);
    let html_a = format!("{}\n<div><button id=\"toggle\">Toggle Masks</button></div>", template(&shapes_a));
    let out = prepare_card_html(&html_a, &media, &dir.join("c"), &PrepareOptions::default());
    assert!(!out.contains("button"));
    let (_, img) = data_uri_image(&out).unwrap();
    assert!(close(px(&img, 80, 40), [255, 255, 255], 12), "{:?}", px(&img, 80, 40));
    assert!(close(px(&img, 40, 40), [0xff, 0x8e, 0x8e], 40), "{:?}", px(&img, 40, 40));
    assert!(close(px(&img, 240, 140), [0xff, 0xeb, 0xa2], 20));
}

#[test]
fn native_io_svg_geometry() {
    let svg = occlusion::test_native_io_svg(
        r##"<div class="cloze" data-shape="rect" data-left=".25" data-top=".5" data-width=".5" data-height=".25" data-angle="2500"></div>
           <div class="cloze-inactive" data-shape="polygon" data-left=".1" data-top=".1" data-points=".2,.2 .4,.2 .3,.4" data-occludeinactive="1" data-fill="#00ff00"></div>
           <div class="cloze-inactive" data-shape="rect" data-left="0" data-top="0" data-width="1" data-height="1" data-fill="x&quot; onload=&quot;bad"></div>"##,
        1000,
        400,
    );
    assert!(svg.contains(r#"<rect x="250" y="200" width="500" height="100""#), "{svg}");
    assert!(svg.contains(r#"rotate(90 250 200)"#), "{svg}");
    // polygon moved so its top-left is at (left, top)
    assert!(svg.contains(r#"points="100,40 300,40 200,120""#), "{svg}");
    assert!(svg.contains("fill=\"#00ff00\""));
    // non-occluding inactive shape not drawn, and attribute injection impossible anyway
    assert!(!svg.contains("onload"));
}

#[test]
fn removes_scripts_buttons_handlers_and_av() {
    let html = r##"<div onclick="x()" class=a>Q [sound:a b.mp3]<script>alert('<div>')</script>
<button id="io-revl-btn" onclick="toggle();">Toggle <b>Masks</b></button>
[anki:play:q:0][anki:play:a:12] [anki:tts lang=en_US voices=Apple]hello <b>x</b>[/anki:tts]
<a href="#" OnMouseOver='y()'>link</a><audio src="x.mp3"><source src="x.mp3"></audio><video controls></video>
<SCRIPT type="text/javascript">var a = "</div>";</SCRIPT>tail</div>"##;
    let out = prepare_card_html(html, Path::new("/nonexistent"), Path::new("/nonexistent"), &PrepareOptions::default());
    for bad in ["script", "SCRIPT", "button", "Toggle", "onclick", "OnMouseOver", "sound:", "anki:play", "anki:tts", "hello", "audio", "video", "alert"] {
        assert!(!out.contains(bad), "{bad} in {out}");
    }
    assert!(out.contains(r#"<div class=a>"#) || out.contains(r#"<div class="a">"#), "{out}");
    assert!(out.contains(r##"<a href="#">link</a>"##), "{out}");
    assert!(out.contains("tail</div>"));
    assert!(out.contains("Q "));
}

#[test]
fn unterminated_script_is_dropped() {
    let out = prepare_card_html("a<script>var x = 1;", Path::new("."), Path::new("."), &PrepareOptions::default());
    assert_eq!(out, "a");
}

#[test]
fn inline_colours_readable_on_white() {
    let html = r##"<span style="color: rgb(255, 255, 255);">ChatGPT dark paste</span><span style="color: red">red</span><font color="#ffffff">w</font><td bgcolor="#000">x</td><span style="color:#fff;background:#c00">label</span>"##;
    let out = prepare_card_html(html, Path::new("."), Path::new("."), &PrepareOptions::default());
    assert!(out.contains("<span>ChatGPT dark paste</span>"), "{out}");
    assert!(out.contains(r#"<span style="color: red">red</span>"#));
    assert!(out.contains("<font>w</font>"), "{out}");
    assert!(out.contains("<td>x</td>"), "{out}");
    assert!(out.contains("color:#fff;background:#c00"));
}

#[test]
fn style_elements_are_cleaned() {
    let html = "<style>.nightMode .x { color: white } .x { color: green }</style><div class=x>hi</div>";
    let out = prepare_card_html(html, Path::new("."), Path::new("."), &PrepareOptions::default());
    assert!(!out.contains("nightMode"), "{out}");
    assert!(out.contains(".x { color: green }"), "{out}");
}

#[test]
fn image_width_capping() {
    let dir = scratch("sizing");
    let media = dir.join("media");
    std::fs::create_dir_all(&media).unwrap();
    write_jpeg(&media.join("wide.jpg"), 1000, 500, [1, 2, 3]);
    write_jpeg(&media.join("small.jpg"), 300, 300, [1, 2, 3]);
    write_jpeg(&media.join("a&b é.jpg"), 900, 100, [1, 2, 3]);
    // PNG content behind a .jpg name: sniffed
    RgbImage::new(800, 10).save_with_format(media.join("liar.jpg"), image::ImageFormat::Png).unwrap();
    std::fs::write(
        media.join("v.svg"),
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="100"></svg>"#,
    )
    .unwrap();
    let opts = PrepareOptions { img_max_px: Some(600) };
    let run = |h: &str| prepare_card_html(h, &media, &dir.join("c"), &opts);

    assert_eq!(run(r#"<img src="wide.jpg">"#), r#"<img src="wide.jpg" width="600">"#);
    assert_eq!(
        run(r#"<img src="wide.jpg" height="500" style="height: 500px; border: 1px solid red">"#),
        r#"<img src="wide.jpg" style="border: 1px solid red" width="600">"#
    );
    assert_eq!(run(r#"<img src="wide.jpg" width="400">"#), r#"<img src="wide.jpg" width="400">"#);
    assert_eq!(run(r#"<img src="wide.jpg" style="width: 50%">"#), r#"<img src="wide.jpg" style="width: 50%">"#);
    assert_eq!(run(r#"<img src="wide.jpg" height="100">"#), r#"<img src="wide.jpg" height="100">"#);
    assert_eq!(
        run(r#"<img src="wide.jpg" width="2000" height="1000">"#),
        r#"<img src="wide.jpg" width="600">"#
    );
    assert_eq!(run(r#"<img src="small.jpg">"#), r#"<img src="small.jpg">"#);
    assert_eq!(run(r#"<img src="a&amp;b%20%C3%A9.jpg">"#), r#"<img src="a&amp;b%20%C3%A9.jpg" width="600">"#);
    assert_eq!(run(r#"<img src='a&amp;b é.jpg'>"#), r#"<img src="a&amp;b é.jpg" width="600">"#);
    assert_eq!(run(r#"<IMG SRC=liar.jpg>"#), r#"<IMG SRC="liar.jpg" width="600">"#);
    assert_eq!(run(r#"<img src="v.svg"/>"#), r#"<img src="v.svg" width="600" />"#);
    // not local / missing / traversal: untouched
    for h in [
        r#"<img src="https://example.com/wide.jpg">"#,
        r#"<img src="data:image/png;base64,AAAA">"#,
        r#"<img src="missing.jpg">"#,
        r#"<img src="../media/wide.jpg">"#,
        r#"<img src="/etc/passwd">"#,
        r#"<img>"#,
    ] {
        assert_eq!(run(h), h);
    }
    // no cap requested: untouched
    assert_eq!(
        prepare_card_html(r#"<img src="wide.jpg">"#, &media, &dir.join("c"), &PrepareOptions::default()),
        r#"<img src="wide.jpg">"#
    );
}

#[test]
fn cloze_markup_untouched_and_css_default() {
    let html = r#"<span class="cloze" data-cloze="x &amp; y" data-ordinal="1">[...]</span>"#;
    assert_eq!(prepare_card_html(html, Path::new("."), Path::new("."), &PrepareOptions::default()), html);
    let css = prepare_css(".card { color: black; }\n.nightMode .cloze { color: lightblue; }");
    assert!(css.contains(".cloze { font-weight: bold; color: blue; }"));
    assert!(!css.contains("lightblue"));
    assert!(css.contains("background-color: #ffffff !important"));
}

#[test]
fn prune_cache_removes_oldest() {
    let dir = scratch("prune");
    for (i, n) in ["io-a.jpg", "io-b.jpg", "io-c.jpg", "other.txt"].iter().enumerate() {
        std::fs::write(dir.join(n), vec![0u8; 100]).unwrap();
        let t = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_000_000 + i as u64 * 10);
        std::fs::File::options().write(true).open(dir.join(n)).unwrap().set_modified(t).unwrap();
    }
    assert_eq!(prune_cache(&dir, 150), 200);
    assert!(!dir.join("io-a.jpg").exists() && !dir.join("io-b.jpg").exists());
    assert!(dir.join("io-c.jpg").exists() && dir.join("other.txt").exists());
}

#[test]
fn weird_input_never_panics() {
    let dir = scratch("fuzz");
    let media = dir.join("media");
    std::fs::create_dir_all(&media).unwrap();
    write_jpeg(&media.join("p.jpg"), 20, 10, [9, 9, 9]);
    std::fs::write(media.join("m.svg"), MASK_SVG).unwrap();
    let frags = [
        "<", ">", "</", "<div", " id=\"io-wrapper\"", " id='io-overlay'", " id=io-original", ">",
        "</div>", "<img src=\"p.jpg\">", "<img src=m.svg>", "<img src=", "\"", "'", "<script>",
        "</script>", "<button>", "</button>", "[sound:", "]", "[anki:tts]", "[/anki:tts]",
        "<!--", "-->", "&amp;", "&#x", ";", "é", "\u{0}", "<style>", ".nightMode{", "}",
        "<div id=\"image-occlusion-container\">", "<div class=\"cloze\" data-shape=\"rect\" data-left=\"NaN\" data-width=\"1e308\">",
        "<div class=cloze-inactive data-shape=polygon data-points=\"1,1 x 2,2\">",
        "<div class=cloze data-shape=ellipse data-rx=-5 data-ry=inf data-angle=nan>", "%", "%%2",
        "<img src=\"p.jpg\" width=\"99999999999999999999\" style=\"width:-1px\">",
    ];
    let mut seed: u64 = 0x1234_5678;
    for _ in 0..400 {
        let mut s = String::new();
        let n = (seed % 24) as usize;
        for _ in 0..n {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            s.push_str(frags[(seed >> 33) as usize % frags.len()]);
        }
        let _ = prepare_card_html(&s, &media, &dir.join("c"), &PrepareOptions { img_max_px: Some(5) });
        let _ = prepare_css(&s);
    }
}

/// Real-media check: `KANKI_TEST_MEDIA=/path/to/collection.media cargo test -p kanki_html`.
/// Uses one of the user's IOE notes (hide-one/guess-one on a 1280x720 JPEG).
#[test]
fn real_media_ioe() {
    let Ok(media) = std::env::var("KANKI_TEST_MEDIA") else {
        eprintln!("KANKI_TEST_MEDIA not set; skipping");
        return;
    };
    let media = PathBuf::from(media);
    let base = "maxresdefault-ed6cab9412fcfdc7a8da7a6e56859ee2d57f9395.jpg";
    let q = "8d4c83877d8d4fcf89f06d05c7f3010d-oa-1-Q.svg";
    let a = "8d4c83877d8d4fcf89f06d05c7f3010d-oa-1-A.svg";
    if !media.join(base).exists() || !media.join(q).exists() {
        eprintln!("test files not in KANKI_TEST_MEDIA; skipping");
        return;
    }
    let dir = scratch("real");
    let opts = PrepareOptions { img_max_px: Some(700) };
    let qh = ioe_html("", &format!(r#"<img src="{q}" />"#), &format!(r#"<img src="{base}" />"#));
    let out = prepare_card_html(&qh, &media, &dir, &opts);
    let (mime, img) = data_uri_image(&out).expect("composite");
    assert_eq!(mime, "image/jpeg");
    assert_eq!(img.dimensions(), (1280, 720));
    assert!(out.contains("width=\"700\""));
    // the mask rect: x 205.4..421.4, y 457.3..528.4, fill #FF7E7E
    assert!(close(px(&img, 313, 492), [0xff, 0x7e, 0x7e], 30), "{:?}", px(&img, 313, 492));
    // answer side (oa): the A mask is empty, so the original image is kept
    let ah = ioe_html("", &format!(r#"<img src="{a}" />"#), &format!(r#"<img src="{base}" />"#));
    let out = prepare_card_html(&ah, &media, &dir, &opts);
    assert!(!out.contains("data:"));
    assert!(out.contains(&format!(r#"<img src="{base}" width="700" />"#)), "{out}");
}
