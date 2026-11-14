//! CSS clean-up for e-ink: drop night-mode rules and dark backgrounds, keep emphasis colours.
//!
//! This is a small, forgiving CSS scanner (comments, strings, nested blocks), not a full parser.
//! Anything it cannot make sense of is passed through unchanged.

/// Default cloze style, prepended so the notetype's own `.cloze` rules (if any) win.
pub(crate) const DEFAULT_CLOZE_CSS: &str = ".cloze { font-weight: bold; color: blue; }";

/// Readable defaults, appended so they win over the notetype's base colours.
pub(crate) const FORCED_DEFAULTS_CSS: &str =
    "html, body, .card { background-color: #ffffff !important; color: #000000 !important; }";

// ---------------------------------------------------------------------------------------------
// Colours
// ---------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Rgba {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    /// 0..=1
    pub a: f32,
}

impl Rgba {
    fn rgb(r: u8, g: u8, b: u8) -> Self {
        Rgba {
            r: r as f32,
            g: g as f32,
            b: b as f32,
            a: 1.0,
        }
    }

    /// WCAG relative luminance, 0..=1.
    pub fn luminance(&self) -> f32 {
        fn lin(c: f32) -> f32 {
            let c = (c / 255.0).clamp(0.0, 1.0);
            if c <= 0.04045 {
                c / 12.92
            } else {
                ((c + 0.055) / 1.055).powf(2.4)
            }
        }
        0.2126 * lin(self.r) + 0.7152 * lin(self.g) + 0.0722 * lin(self.b)
    }

    fn chroma(&self) -> f32 {
        let max = self.r.max(self.g).max(self.b);
        let min = self.r.min(self.g).min(self.b);
        ((max - min) / 255.0).clamp(0.0, 1.0)
    }

    /// A background that only makes sense in a dark theme: near-black, or dark and greyish.
    /// Saturated dark-ish colours (a blue header bar, a red label) are kept as emphasis.
    pub fn is_dark_background(&self) -> bool {
        if self.a < 0.5 {
            return false;
        }
        let l = self.luminance();
        l < 0.025 || (l < 0.18 && self.chroma() < 0.25)
    }
}

/// Parses a single CSS colour value.
pub(crate) fn parse_color(s: &str) -> Option<Rgba> {
    let s = s.trim();
    if let Some(hex) = s.strip_prefix('#') {
        return parse_hex(hex);
    }
    let lower = s.to_ascii_lowercase();
    if let Some(open) = lower.find('(') {
        let func = lower[..open].trim();
        let close = lower.rfind(')').unwrap_or(lower.len());
        if close <= open {
            return None;
        }
        let args = &lower[open + 1..close];
        return match func {
            "rgb" | "rgba" => parse_rgb_args(args),
            "hsl" | "hsla" => parse_hsl_args(args),
            _ => None,
        };
    }
    named_color(&lower)
}

fn parse_hex(hex: &str) -> Option<Rgba> {
    if !hex.bytes().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let d = |i: usize, len: usize| u8::from_str_radix(&hex[i..i + len], 16).ok();
    let (r, g, b, a) = match hex.len() {
        3 | 4 => {
            let x = |i| d(i, 1).map(|v| v * 17);
            (x(0)?, x(1)?, x(2)?, if hex.len() == 4 { x(3)? } else { 255 })
        }
        6 | 8 => (
            d(0, 2)?,
            d(2, 2)?,
            d(4, 2)?,
            if hex.len() == 8 { d(6, 2)? } else { 255 },
        ),
        _ => return None,
    };
    let mut c = Rgba::rgb(r, g, b);
    c.a = a as f32 / 255.0;
    Some(c)
}

fn split_color_args(args: &str) -> Vec<&str> {
    args.split(|c: char| c == ',' || c == '/' || c.is_whitespace())
        .filter(|p| !p.is_empty())
        .collect()
}

fn parse_num(p: &str, scale_pct: f32) -> Option<f32> {
    if let Some(v) = p.strip_suffix('%') {
        v.parse::<f32>().ok().map(|v| v / 100.0 * scale_pct)
    } else {
        p.parse::<f32>().ok()
    }
}

fn parse_alpha(p: Option<&&str>) -> Option<f32> {
    match p {
        None => Some(1.0),
        Some(p) => {
            if let Some(v) = p.strip_suffix('%') {
                v.parse::<f32>().ok().map(|v| v / 100.0)
            } else {
                p.parse::<f32>().ok()
            }
        }
    }
}

fn parse_rgb_args(args: &str) -> Option<Rgba> {
    let p = split_color_args(args);
    if p.len() < 3 {
        return None;
    }
    Some(Rgba {
        r: parse_num(p[0], 255.0)?,
        g: parse_num(p[1], 255.0)?,
        b: parse_num(p[2], 255.0)?,
        a: parse_alpha(p.get(3))?.clamp(0.0, 1.0),
    })
}

fn parse_hsl_args(args: &str) -> Option<Rgba> {
    let p = split_color_args(args);
    if p.len() < 3 {
        return None;
    }
    let h = p[0].trim_end_matches("deg").parse::<f32>().ok()?;
    let s = parse_num(p[1].trim_end_matches('%'), 1.0)? / 100.0;
    let l = parse_num(p[2].trim_end_matches('%'), 1.0)? / 100.0;
    let a = parse_alpha(p.get(3))?.clamp(0.0, 1.0);
    let (s, l) = (s.clamp(0.0, 1.0), l.clamp(0.0, 1.0));
    let c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    let hp = (h.rem_euclid(360.0)) / 60.0;
    let x = c * (1.0 - (hp % 2.0 - 1.0).abs());
    let (r1, g1, b1) = match hp as u32 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    let m = l - c / 2.0;
    Some(Rgba {
        r: (r1 + m) * 255.0,
        g: (g1 + m) * 255.0,
        b: (b1 + m) * 255.0,
        a,
    })
}

fn named_color(name: &str) -> Option<Rgba> {
    // CSS named colours (Level 4).
    const NAMED: &[(&str, u32)] = &[
        ("aliceblue", 0xf0f8ff), ("antiquewhite", 0xfaebd7), ("aqua", 0x00ffff),
        ("aquamarine", 0x7fffd4), ("azure", 0xf0ffff), ("beige", 0xf5f5dc), ("bisque", 0xffe4c4),
        ("black", 0x000000), ("blanchedalmond", 0xffebcd), ("blue", 0x0000ff),
        ("blueviolet", 0x8a2be2), ("brown", 0xa52a2a), ("burlywood", 0xdeb887),
        ("cadetblue", 0x5f9ea0), ("chartreuse", 0x7fff00), ("chocolate", 0xd2691e),
        ("coral", 0xff7f50), ("cornflowerblue", 0x6495ed), ("cornsilk", 0xfff8dc),
        ("crimson", 0xdc143c), ("cyan", 0x00ffff), ("darkblue", 0x00008b), ("darkcyan", 0x008b8b),
        ("darkgoldenrod", 0xb8860b), ("darkgray", 0xa9a9a9), ("darkgreen", 0x006400),
        ("darkgrey", 0xa9a9a9), ("darkkhaki", 0xbdb76b), ("darkmagenta", 0x8b008b),
        ("darkolivegreen", 0x556b2f), ("darkorange", 0xff8c00), ("darkorchid", 0x9932cc),
        ("darkred", 0x8b0000), ("darksalmon", 0xe9967a), ("darkseagreen", 0x8fbc8f),
        ("darkslateblue", 0x483d8b), ("darkslategray", 0x2f4f4f), ("darkslategrey", 0x2f4f4f),
        ("darkturquoise", 0x00ced1), ("darkviolet", 0x9400d3), ("deeppink", 0xff1493),
        ("deepskyblue", 0x00bfff), ("dimgray", 0x696969), ("dimgrey", 0x696969),
        ("dodgerblue", 0x1e90ff), ("firebrick", 0xb22222), ("floralwhite", 0xfffaf0),
        ("forestgreen", 0x228b22), ("fuchsia", 0xff00ff), ("gainsboro", 0xdcdcdc),
        ("ghostwhite", 0xf8f8ff), ("gold", 0xffd700), ("goldenrod", 0xdaa520), ("gray", 0x808080),
        ("green", 0x008000), ("greenyellow", 0xadff2f), ("grey", 0x808080),
        ("honeydew", 0xf0fff0), ("hotpink", 0xff69b4), ("indianred", 0xcd5c5c),
        ("indigo", 0x4b0082), ("ivory", 0xfffff0), ("khaki", 0xf0e68c), ("lavender", 0xe6e6fa),
        ("lavenderblush", 0xfff0f5), ("lawngreen", 0x7cfc00), ("lemonchiffon", 0xfffacd),
        ("lightblue", 0xadd8e6), ("lightcoral", 0xf08080), ("lightcyan", 0xe0ffff),
        ("lightgoldenrodyellow", 0xfafad2), ("lightgray", 0xd3d3d3), ("lightgreen", 0x90ee90),
        ("lightgrey", 0xd3d3d3), ("lightpink", 0xffb6c1), ("lightsalmon", 0xffa07a),
        ("lightseagreen", 0x20b2aa), ("lightskyblue", 0x87cefa), ("lightslategray", 0x778899),
        ("lightslategrey", 0x778899), ("lightsteelblue", 0xb0c4de), ("lightyellow", 0xffffe0),
        ("lime", 0x00ff00), ("limegreen", 0x32cd32), ("linen", 0xfaf0e6), ("magenta", 0xff00ff),
        ("maroon", 0x800000), ("mediumaquamarine", 0x66cdaa), ("mediumblue", 0x0000cd),
        ("mediumorchid", 0xba55d3), ("mediumpurple", 0x9370db), ("mediumseagreen", 0x3cb371),
        ("mediumslateblue", 0x7b68ee), ("mediumspringgreen", 0x00fa9a),
        ("mediumturquoise", 0x48d1cc), ("mediumvioletred", 0xc71585),
        ("midnightblue", 0x191970), ("mintcream", 0xf5fffa), ("mistyrose", 0xffe4e1),
        ("moccasin", 0xffe4b5), ("navajowhite", 0xffdead), ("navy", 0x000080),
        ("oldlace", 0xfdf5e6), ("olive", 0x808000), ("olivedrab", 0x6b8e23), ("orange", 0xffa500),
        ("orangered", 0xff4500), ("orchid", 0xda70d6), ("palegoldenrod", 0xeee8aa),
        ("palegreen", 0x98fb98), ("paleturquoise", 0xafeeee), ("palevioletred", 0xdb7093),
        ("papayawhip", 0xffefd5), ("peachpuff", 0xffdab9), ("peru", 0xcd853f), ("pink", 0xffc0cb),
        ("plum", 0xdda0dd), ("powderblue", 0xb0e0e6), ("purple", 0x800080),
        ("rebeccapurple", 0x663399), ("red", 0xff0000), ("rosybrown", 0xbc8f8f),
        ("royalblue", 0x4169e1), ("saddlebrown", 0x8b4513), ("salmon", 0xfa8072),
        ("sandybrown", 0xf4a460), ("seagreen", 0x2e8b57), ("seashell", 0xfff5ee),
        ("sienna", 0xa0522d), ("silver", 0xc0c0c0), ("skyblue", 0x87ceeb), ("slateblue", 0x6a5acd),
        ("slategray", 0x708090), ("slategrey", 0x708090), ("snow", 0xfffafa),
        ("springgreen", 0x00ff7f), ("steelblue", 0x4682b4), ("tan", 0xd2b48c), ("teal", 0x008080),
        ("thistle", 0xd8bfd8), ("tomato", 0xff6347), ("turquoise", 0x40e0d0),
        ("violet", 0xee82ee), ("wheat", 0xf5deb3), ("white", 0xffffff), ("whitesmoke", 0xf5f5f5),
        ("yellow", 0xffff00), ("yellowgreen", 0x9acd32),
    ];
    if name == "transparent" {
        return Some(Rgba {
            r: 0.0,
            g: 0.0,
            b: 0.0,
            a: 0.0,
        });
    }
    NAMED
        .binary_search_by(|(n, _)| (*n).cmp(name))
        .ok()
        .map(|i| {
            let v = NAMED[i].1;
            Rgba::rgb((v >> 16) as u8, (v >> 8) as u8, v as u8)
        })
}

/// All colours mentioned in a declaration value (`#hex`, `rgb()`, `hsl()`, named colours).
pub(crate) fn colors_in(value: &str) -> Vec<Rgba> {
    let mut out = Vec::new();
    let b = value.as_bytes();
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        if c == b'#' {
            let mut j = i + 1;
            while j < b.len() && b[j].is_ascii_hexdigit() {
                j += 1;
            }
            if let Some(col) = parse_hex(&value[i + 1..j]) {
                out.push(col);
            }
            i = j.max(i + 1);
        } else if c.is_ascii_alphabetic() || c == b'-' {
            let mut j = i;
            while j < b.len() && (b[j].is_ascii_alphanumeric() || b[j] == b'-' || b[j] == b'_') {
                j += 1;
            }
            let word = value[i..j].to_ascii_lowercase();
            if j < b.len() && b[j] == b'(' {
                let close = value[j..].find(')').map(|p| p + j).unwrap_or(b.len() - 1);
                if matches!(word.as_str(), "rgb" | "rgba" | "hsl" | "hsla") {
                    if let Some(col) = parse_color(&value[i..=close.min(b.len() - 1)]) {
                        out.push(col);
                    }
                    i = close + 1;
                    continue;
                }
                if word == "url" {
                    // never look for colours inside urls
                    i = close + 1;
                    continue;
                }
                i = j + 1;
                continue;
            }
            if let Some(col) = named_color(&word) {
                out.push(col);
            }
            i = j.max(i + 1);
        } else {
            i += 1;
        }
    }
    out
}

// ---------------------------------------------------------------------------------------------
// Scanner
// ---------------------------------------------------------------------------------------------

/// Skips a comment or string starting at `i`, returning the index after it, or None if `i` does
/// not start one.
fn skip_comment_or_string(b: &[u8], i: usize) -> Option<usize> {
    match b[i] {
        b'/' if b.get(i + 1) == Some(&b'*') => {
            let mut j = i + 2;
            while j + 1 < b.len() && !(b[j] == b'*' && b[j + 1] == b'/') {
                j += 1;
            }
            Some((j + 2).min(b.len()))
        }
        q @ (b'"' | b'\'') => {
            let mut j = i + 1;
            while j < b.len() && b[j] != q {
                if b[j] == b'\\' {
                    j += 1;
                }
                if j < b.len() && b[j] == b'\n' {
                    break;
                }
                j += 1;
            }
            Some((j + 1).min(b.len()))
        }
        _ => None,
    }
}

/// Finds the first of `stops` at nesting depth 0 (outside strings/comments/parens/brackets).
fn find_top_level(b: &[u8], from: usize, stops: &[u8]) -> Option<usize> {
    let mut depth = 0i32;
    let mut i = from;
    while i < b.len() {
        if let Some(j) = skip_comment_or_string(b, i) {
            i = j;
            continue;
        }
        let c = b[i];
        if depth == 0 && stops.contains(&c) {
            return Some(i);
        }
        match c {
            b'(' | b'[' => depth += 1,
            b')' | b']' => depth = (depth - 1).max(0),
            b'\\' => i += 1,
            _ => {}
        }
        i += 1;
    }
    None
}

/// Index of the `}` matching the `{` at `open`.
fn find_matching_brace(b: &[u8], open: usize) -> Option<usize> {
    let mut depth = 0i32;
    let mut i = open;
    while i < b.len() {
        if let Some(j) = skip_comment_or_string(b, i) {
            i = j;
            continue;
        }
        match b[i] {
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(i);
                }
            }
            b'\\' => i += 1,
            _ => {}
        }
        i += 1;
    }
    None
}

/// Splits on `sep` at nesting depth 0.
fn split_top_level(s: &str, sep: u8) -> Vec<&str> {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut start = 0;
    let mut i = 0;
    let mut depth = 0i32;
    while i < b.len() {
        if let Some(j) = skip_comment_or_string(b, i) {
            i = j;
            continue;
        }
        match b[i] {
            b'(' | b'[' | b'{' => depth += 1,
            b')' | b']' | b'}' => depth = (depth - 1).max(0),
            b'\\' => i += 1,
            c if c == sep && depth == 0 => {
                out.push(&s[start..i]);
                start = i + 1;
            }
            _ => {}
        }
        i += 1;
    }
    if start <= s.len() {
        out.push(&s[start.min(s.len())..]);
    }
    out
}

fn strip_comments(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    let mut last = 0;
    while i < b.len() {
        if b[i] == b'/' && b.get(i + 1) == Some(&b'*') {
            out.push_str(&s[last..i]);
            let j = skip_comment_or_string(b, i).unwrap_or(b.len());
            out.push(' ');
            i = j;
            last = j;
            continue;
        }
        if b[i] == b'"' || b[i] == b'\'' {
            i = skip_comment_or_string(b, i).unwrap_or(b.len());
            continue;
        }
        i += 1;
    }
    out.push_str(&s[last.min(s.len())..]);
    out
}

#[derive(Debug)]
enum Item<'a> {
    /// `@import ...;`, `@charset ...;`
    AtStatement(&'a str),
    AtBlock { prelude: &'a str, body: &'a str },
    Rule { prelude: &'a str, body: &'a str },
}

fn parse_items(css: &str) -> Vec<Item<'_>> {
    let b = css.as_bytes();
    let mut items = Vec::new();
    let mut i = 0;
    while i < b.len() {
        // skip whitespace, comments, CDO/CDC and stray `;`/`}`
        let c = b[i];
        if c.is_ascii_whitespace() || c == b';' || c == b'}' {
            i += 1;
            continue;
        }
        if c == b'/' && b.get(i + 1) == Some(&b'*') {
            i = skip_comment_or_string(b, i).unwrap_or(b.len());
            continue;
        }
        if b[i..].starts_with(b"<!--") {
            i += 4;
            continue;
        }
        if b[i..].starts_with(b"-->") {
            i += 3;
            continue;
        }
        let start = i;
        if c == b'@' {
            match find_top_level(b, i, b"{;") {
                Some(p) if b[p] == b';' => {
                    items.push(Item::AtStatement(&css[start..=p]));
                    i = p + 1;
                }
                Some(p) => {
                    let Some(close) = find_matching_brace(b, p) else {
                        // unterminated block: keep the rest verbatim inside it
                        items.push(Item::AtBlock {
                            prelude: &css[start..p],
                            body: &css[p + 1..],
                        });
                        break;
                    };
                    items.push(Item::AtBlock {
                        prelude: &css[start..p],
                        body: &css[p + 1..close],
                    });
                    i = close + 1;
                }
                None => {
                    items.push(Item::AtStatement(&css[start..]));
                    break;
                }
            }
        } else {
            match find_top_level(b, i, b"{") {
                Some(p) => {
                    let close = find_matching_brace(b, p);
                    let body_end = close.unwrap_or(b.len());
                    items.push(Item::Rule {
                        prelude: &css[start..p],
                        body: &css[p + 1..body_end],
                    });
                    i = close.map(|c| c + 1).unwrap_or(b.len());
                }
                None => break, // trailing garbage
            }
        }
    }
    items
}

fn is_night_selector(sel: &str) -> bool {
    let lower = sel.to_ascii_lowercase();
    let b = lower.as_bytes();
    for pat in ["nightmode", "night_mode", "night-mode", "darkmode", "dark_mode", "dark-mode"] {
        let mut from = 0;
        while let Some(p) = lower[from..].find(pat).map(|p| p + from) {
            let before_ok = p > 0 && b[p - 1] == b'.';
            let after = b.get(p + pat.len()).copied();
            let after_ok = !matches!(after, Some(c) if c.is_ascii_alphanumeric() || c == b'-' || c == b'_');
            if before_ok && after_ok {
                return true;
            }
            from = p + 1;
        }
    }
    false
}

fn is_dark_media(prelude: &str) -> bool {
    let p = prelude.to_ascii_lowercase();
    p.contains("prefers-color-scheme") && p.contains("dark")
}

struct Decl {
    name: String,
    text: String,
}

/// Filters declarations for readability on a white e-ink page. Returns None if nothing changed.
fn clean_declarations(body: &str) -> Option<String> {
    let parts = split_top_level(body, b';');
    let mut decls: Vec<Decl> = Vec::new();
    for p in parts {
        let t = p.trim();
        if t.is_empty() {
            continue;
        }
        let name = t
            .split(':')
            .next()
            .unwrap_or("")
            .trim()
            .to_ascii_lowercase();
        decls.push(Decl {
            name,
            text: t.to_string(),
        });
    }
    let value_of = |d: &Decl| -> String {
        let v = d.text.split_once(':').map(|x| x.1).unwrap_or("");
        strip_comments(v)
    };
    let is_bg = |n: &str| matches!(n, "background" | "background-color" | "background-image");

    let mut changed = false;
    let mut had_dark_bg = false;
    decls.retain(|d| {
        if is_bg(&d.name) && colors_in(&value_of(d)).iter().any(|c| c.is_dark_background()) {
            had_dark_bg = true;
            changed = true;
            false
        } else {
            true
        }
    });
    // A remaining background dark enough to carry light text (e.g. a coloured label)?
    let darkish_bg_remains = decls.iter().any(|d| {
        is_bg(&d.name)
            && colors_in(&value_of(d))
                .iter()
                .any(|c| c.a >= 0.5 && c.luminance() < 0.4)
    });
    let light_limit = if had_dark_bg { 0.45 } else { 0.7 };
    decls.retain(|d| {
        if d.name == "color" && !darkish_bg_remains {
            let cols = colors_in(&value_of(d));
            if cols
                .iter()
                .any(|c| c.a >= 0.5 && c.luminance() > light_limit)
            {
                changed = true;
                return false;
            }
        }
        true
    });
    if !changed {
        return None;
    }
    Some(
        decls
            .iter()
            .map(|d| d.text.as_str())
            .collect::<Vec<_>>()
            .join("; "),
    )
}

/// Cleans an inline `style` attribute value (already entity-decoded). None if unchanged.
pub(crate) fn clean_inline_style(style: &str) -> Option<String> {
    clean_declarations(style)
}

/// True if a colour given in an HTML attribute (`<font color>`) is too light to read on white.
pub(crate) fn is_too_light_text(value: &str) -> bool {
    parse_color(value)
        .map(|c| c.a >= 0.5 && c.luminance() > 0.7)
        .unwrap_or(false)
}

/// True if an HTML `bgcolor` attribute only makes sense in a dark theme.
pub(crate) fn is_dark_bg_attr(value: &str) -> bool {
    parse_color(value)
        .map(|c| c.is_dark_background())
        .unwrap_or(false)
}

fn clean_items(css: &str, out: &mut Vec<(bool, String)>) {
    for item in parse_items(css) {
        match item {
            Item::AtStatement(s) => {
                let lower = s.trim_start().to_ascii_lowercase();
                let hoist = lower.starts_with("@import") || lower.starts_with("@charset");
                out.push((hoist, s.trim().to_string()));
            }
            Item::AtBlock { prelude, body } => {
                let pl = prelude.trim().to_ascii_lowercase();
                if pl.starts_with("@media") && is_dark_media(&pl) {
                    continue;
                }
                if pl.starts_with("@media")
                    || pl.starts_with("@supports")
                    || pl.starts_with("@layer")
                    || pl.starts_with("@document")
                    || pl.starts_with("@container")
                {
                    let mut inner = Vec::new();
                    clean_items(body, &mut inner);
                    if inner.is_empty() {
                        continue;
                    }
                    let inner: Vec<String> = inner.into_iter().map(|(_, s)| s).collect();
                    out.push((false, format!("{} {{\n{}\n}}", prelude.trim(), inner.join("\n"))));
                } else {
                    out.push((false, format!("{} {{{}}}", prelude.trim(), body)));
                }
            }
            Item::Rule { prelude, body } => {
                let sels: Vec<&str> = split_top_level(prelude, b',')
                    .into_iter()
                    .map(|s| s.trim())
                    .filter(|s| !s.is_empty())
                    .collect();
                let kept: Vec<&str> = sels
                    .iter()
                    .copied()
                    .filter(|s| !is_night_selector(&strip_comments(s)))
                    .collect();
                if kept.is_empty() {
                    continue;
                }
                let sel_text = if kept.len() == sels.len() {
                    prelude.trim().to_string()
                } else {
                    kept.join(", ")
                };
                // Nested rules (CSS nesting) inside a body: leave the body alone.
                let has_nested = find_top_level(body.as_bytes(), 0, b"{").is_some();
                let body_text = if has_nested {
                    body.to_string()
                } else {
                    match clean_declarations(body) {
                        Some(b) => format!(" {b} "),
                        None => body.to_string(),
                    }
                };
                out.push((false, format!("{sel_text} {{{body_text}}}")));
            }
        }
    }
}

/// Removes night-mode rules, dark-scheme media blocks and dark backgrounds. No defaults added.
pub(crate) fn clean_css(css: &str) -> String {
    let mut items = Vec::new();
    clean_items(css, &mut items);
    items
        .into_iter()
        .map(|(_, s)| s)
        .collect::<Vec<_>>()
        .join("\n")
}

pub(crate) fn prepare_css(css: &str) -> String {
    let mut items = Vec::new();
    clean_items(css, &mut items);
    let mut out = String::with_capacity(css.len() + 256);
    // @charset/@import must stay first
    for (hoist, s) in &items {
        if *hoist {
            out.push_str(s);
            out.push('\n');
        }
    }
    out.push_str(DEFAULT_CLOZE_CSS);
    out.push('\n');
    for (hoist, s) in &items {
        if !*hoist {
            out.push_str(s);
            out.push('\n');
        }
    }
    out.push_str(FORCED_DEFAULTS_CSS);
    out.push('\n');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn named_table_sorted() {
        // binary search needs the table sorted
        assert!(named_color("yellowgreen").is_some());
        assert!(named_color("aliceblue").is_some());
        assert!(named_color("lightgoldenrodyellow").is_some());
        assert!(named_color("notacolor").is_none());
    }

    #[test]
    fn colour_parsing() {
        assert_eq!(parse_color("#fff").unwrap().luminance(), 1.0);
        assert!(parse_color("rgb(30, 30, 30)").unwrap().is_dark_background());
        assert!(parse_color("#202020").unwrap().is_dark_background());
        assert!(!parse_color("#3B53A3").unwrap().is_dark_background()); // blue header bar
        assert!(!parse_color("#c00").unwrap().is_dark_background());
        assert!(!parse_color("rgba(0,0,0,0.1)").unwrap().is_dark_background());
        assert!(parse_color("hsl(0, 0%, 10%)").unwrap().is_dark_background());
        assert!(parse_color("Black").unwrap().is_dark_background());
        assert_eq!(colors_in("url(#000) #123456 no-repeat").len(), 1);
        assert_eq!(colors_in("linear-gradient(black, rgb(1,2,3))").len(), 2);
    }

    #[test]
    fn strips_night_mode_and_dark() {
        let css = r#"
<!--
.card { font-family: arial; color: #F0EAE5; background-color: #202020; }
.nightMode .cloze, .night_mode .cloze { color: lightblue; }
.cloze, .card.nightMode b { color: red }
@media (prefers-color-scheme: dark) { .card { background: black } }
@media screen and (max-width: 500px) { .a { color: blue } .night_mode .a { color: white } }
#header { background: #3B53A3; color: white }
-->
"#;
        let out = prepare_css(css);
        assert!(!out.to_ascii_lowercase().contains("night"), "{out}");
        assert!(!out.contains("prefers-color-scheme"), "{out}");
        assert!(!out.contains("#202020"), "{out}");
        assert!(!out.contains("#F0EAE5"), "{out}");
        assert!(out.contains("font-family: arial"), "{out}");
        assert!(out.contains(".cloze {") || out.contains(".cloze { "), "{out}");
        assert!(out.contains(".cloze { color: red }"), "{out}");
        assert!(out.contains("max-width: 500px"), "{out}");
        assert!(out.contains(".a { color: blue }"), "{out}");
        // coloured header keeps its white text
        assert!(out.contains("#header { background: #3B53A3; color: white }"), "{out}");
        assert!(out.contains(DEFAULT_CLOZE_CSS));
        assert!(out.trim_end().ends_with(FORCED_DEFAULTS_CSS));
        assert!(!out.contains("<!--") && !out.contains("-->"));
    }

    #[test]
    fn keeps_imports_first_and_font_face() {
        let css = "@import url(\"_x.css\");\n@font-face { font-family: X; src: url(_x.ttf); }\n.a{color:green}";
        let out = prepare_css(css);
        assert!(out.starts_with("@import"), "{out}");
        assert!(out.contains("@font-face"));
        assert!(out.contains(".a {color:green}"), "{out}");
    }

    #[test]
    fn inline_styles() {
        assert_eq!(clean_inline_style("color: rgb(255, 255, 255);").as_deref(), Some(""));
        assert_eq!(
            clean_inline_style("color: rgb(255,255,255); background-color: rgb(30,30,30); font-weight: bold").as_deref(),
            Some("font-weight: bold")
        );
        assert_eq!(clean_inline_style("color: red; background: #fff"), None);
        assert_eq!(clean_inline_style("color: white; background: #c00"), None);
        assert_eq!(clean_inline_style("caret-color: rgb(255,255,255)"), None);
    }

    #[test]
    fn garbage_css_never_panics() {
        for s in [
            "", "{", "}", "@", "@media", "@media {", ".a {", ".a { color: ", "/*", "'", "\"",
            "a{b:c}}}}", "@media (prefers-color-scheme: dark) {", "rgb(", "#", "a { color: rgb(1,2 }",
            "a{background: hsl(}", "a{color:#ff}", "é{color:é}", ")", "(((", "a{b:url(}",
        ] {
            let _ = prepare_css(s);
            let _ = clean_inline_style(s);
            let _ = colors_in(s);
        }
    }
}
