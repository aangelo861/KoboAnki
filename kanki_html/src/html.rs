//! A tiny, forgiving HTML tokenizer: just enough structure (tags, attributes, text, comments,
//! raw-text elements) to rewrite Anki card HTML without a full DOM. It never fails: anything it
//! does not understand is passed through as text.

use std::borrow::Cow;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Kind {
    Text,
    /// `<!-- -->`, `<!DOCTYPE>`, `<?...?>`
    Comment,
    StartTag,
    EndTag,
}

#[derive(Debug, Clone)]
pub(crate) struct Attr<'a> {
    pub name: &'a str,
    /// Raw value as written (entities not decoded), without the quotes.
    pub value: Option<&'a str>,
}

#[derive(Debug, Clone)]
pub(crate) struct Token<'a> {
    pub kind: Kind,
    /// Byte range of the whole token in the source.
    pub start: usize,
    pub end: usize,
    /// Tag name as written (empty for text/comments).
    pub name: &'a str,
    pub attrs: Vec<Attr<'a>>,
    pub self_closing: bool,
}

impl<'a> Token<'a> {
    pub fn is_start(&self, name: &str) -> bool {
        self.kind == Kind::StartTag && self.name.eq_ignore_ascii_case(name)
    }

    pub fn is_end(&self, name: &str) -> bool {
        self.kind == Kind::EndTag && self.name.eq_ignore_ascii_case(name)
    }

    /// Raw (entity-encoded) value of an attribute; `Some("")` for a valueless attribute.
    pub fn attr(&self, name: &str) -> Option<&'a str> {
        self.attrs
            .iter()
            .find(|a| a.name.eq_ignore_ascii_case(name))
            .map(|a| a.value.unwrap_or(""))
    }

    /// Attribute value with HTML entities decoded.
    pub fn attr_decoded(&self, name: &str) -> Option<Cow<'a, str>> {
        self.attr(name).map(decode_entities)
    }

    pub fn has_class(&self, class: &str) -> bool {
        self.attr("class")
            .map(|c| c.split_ascii_whitespace().any(|c| c == class))
            .unwrap_or(false)
    }

    pub fn id_is(&self, id: &str) -> bool {
        self.attr("id").map(|v| v.trim() == id).unwrap_or(false)
    }
}

const RAW_TEXT_ELEMENTS: &[&str] = &["script", "style", "textarea", "title", "xmp"];

/// Void elements never have an end tag.
pub(crate) fn is_void(name: &str) -> bool {
    const VOID: &[&str] = &[
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param",
        "source", "track", "wbr",
    ];
    VOID.iter().any(|v| v.eq_ignore_ascii_case(name))
}

pub(crate) fn tokenize(s: &str) -> Vec<Token<'_>> {
    let b = s.as_bytes();
    let n = b.len();
    let mut out = Vec::new();
    let mut i = 0;
    let mut text_start = 0;
    while i < n {
        let Some(lt) = memchr(b'<', b, i) else {
            break;
        };
        i = lt;
        match parse_markup(s, i) {
            Some(tok) => {
                if text_start < i {
                    out.push(text_token(text_start, i));
                }
                let next = tok.end;
                let raw = tok.kind == Kind::StartTag
                    && RAW_TEXT_ELEMENTS
                        .iter()
                        .any(|r| r.eq_ignore_ascii_case(tok.name));
                let name = tok.name;
                out.push(tok);
                i = next;
                text_start = i;
                if raw {
                    let mut needle = Vec::with_capacity(name.len() + 2);
                    needle.extend_from_slice(b"</");
                    needle.extend_from_slice(name.as_bytes());
                    let end = find_ci(b, i, &needle).unwrap_or(n);
                    if end > i {
                        out.push(text_token(i, end));
                    }
                    i = end;
                    text_start = end;
                    if end < n {
                        // The closing tag itself; if it is malformed, emit it as text.
                        match parse_markup(s, end) {
                            Some(t) => {
                                i = t.end;
                                out.push(t);
                                text_start = i;
                            }
                            None => {
                                i = end + 2;
                            }
                        }
                    }
                }
            }
            None => i += 1,
        }
    }
    if text_start < n {
        out.push(text_token(text_start, n));
    }
    out
}

fn text_token<'a>(start: usize, end: usize) -> Token<'a> {
    Token {
        kind: Kind::Text,
        start,
        end,
        name: "",
        attrs: Vec::new(),
        self_closing: false,
    }
}

fn memchr(needle: u8, hay: &[u8], from: usize) -> Option<usize> {
    hay.get(from..)?
        .iter()
        .position(|&c| c == needle)
        .map(|p| p + from)
}

fn find_bytes(hay: &[u8], from: usize, needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || from > hay.len() {
        return None;
    }
    hay[from..]
        .windows(needle.len())
        .position(|w| w == needle)
        .map(|p| p + from)
}

/// Case-insensitive (ASCII) search.
pub(crate) fn find_ci(hay: &[u8], from: usize, needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || from > hay.len() {
        return None;
    }
    hay[from..]
        .windows(needle.len())
        .position(|w| w.eq_ignore_ascii_case(needle))
        .map(|p| p + from)
}

fn is_ws(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | b'\r' | b'\x0c')
}

/// Parses markup starting at `i` (which holds `<`). Returns None if this `<` is just text.
fn parse_markup(s: &str, i: usize) -> Option<Token<'_>> {
    let b = s.as_bytes();
    let n = b.len();
    let next = *b.get(i + 1)?;
    if b[i..].starts_with(b"<!--") {
        let end = find_bytes(b, i + 4, b"-->").map(|p| p + 3).unwrap_or(n);
        return Some(Token {
            kind: Kind::Comment,
            start: i,
            end,
            name: "",
            attrs: Vec::new(),
            self_closing: false,
        });
    }
    if next == b'!' || next == b'?' {
        let end = memchr(b'>', b, i + 2).map(|p| p + 1).unwrap_or(n);
        return Some(Token {
            kind: Kind::Comment,
            start: i,
            end,
            name: "",
            attrs: Vec::new(),
            self_closing: false,
        });
    }
    if next == b'/' {
        let c = *b.get(i + 2)?;
        if !c.is_ascii_alphabetic() {
            return None;
        }
        let name_start = i + 2;
        let mut j = name_start;
        while j < n && !is_ws(b[j]) && b[j] != b'/' && b[j] != b'>' {
            j += 1;
        }
        let gt = memchr(b'>', b, j)?;
        return Some(Token {
            kind: Kind::EndTag,
            start: i,
            end: gt + 1,
            name: &s[name_start..j],
            attrs: Vec::new(),
            self_closing: false,
        });
    }
    if !next.is_ascii_alphabetic() {
        return None;
    }
    let name_start = i + 1;
    let mut j = name_start;
    while j < n && !is_ws(b[j]) && b[j] != b'/' && b[j] != b'>' {
        j += 1;
    }
    let name = &s[name_start..j];
    let mut attrs = Vec::new();
    let mut self_closing = false;
    loop {
        while j < n && is_ws(b[j]) {
            j += 1;
        }
        if j >= n {
            return None;
        }
        match b[j] {
            b'>' => {
                j += 1;
                break;
            }
            b'/' => {
                if b.get(j + 1) == Some(&b'>') {
                    self_closing = true;
                    j += 2;
                    break;
                }
                j += 1;
                continue;
            }
            _ => {}
        }
        // attribute name (at least one byte, so we always make progress)
        let an_start = j;
        j += 1;
        while j < n && !is_ws(b[j]) && b[j] != b'/' && b[j] != b'>' && b[j] != b'=' {
            j += 1;
        }
        // `j` only ever stops on ASCII bytes or the end, so slicing is on char boundaries,
        // except for the first byte, which may start a multi-byte char: extend to a boundary.
        let mut an_end = j;
        while an_end < n && !s.is_char_boundary(an_end) {
            an_end += 1;
        }
        j = an_end;
        let attr_name = &s[an_start..an_end];
        let mut k = j;
        while k < n && is_ws(b[k]) {
            k += 1;
        }
        if k < n && b[k] == b'=' {
            k += 1;
            while k < n && is_ws(b[k]) {
                k += 1;
            }
            if k >= n {
                return None;
            }
            let q = b[k];
            if q == b'"' || q == b'\'' {
                let close = memchr(q, b, k + 1)?;
                attrs.push(Attr {
                    name: attr_name,
                    value: Some(&s[k + 1..close]),
                });
                j = close + 1;
            } else {
                let v_start = k;
                while k < n && !is_ws(b[k]) && b[k] != b'>' {
                    k += 1;
                }
                attrs.push(Attr {
                    name: attr_name,
                    value: Some(&s[v_start..k]),
                });
                j = k;
            }
        } else {
            attrs.push(Attr {
                name: attr_name,
                value: None,
            });
        }
    }
    Some(Token {
        kind: Kind::StartTag,
        start: i,
        end: j,
        name,
        attrs,
        self_closing,
    })
}

/// Index of the end tag matching the start tag at `open`, honouring nesting of the same name.
pub(crate) fn find_matching_end(toks: &[Token], open: usize) -> Option<usize> {
    let name = toks.get(open)?.name;
    let mut depth = 0usize;
    for (j, t) in toks.iter().enumerate().skip(open + 1) {
        if t.is_start(name) {
            depth += 1;
        } else if t.is_end(name) {
            if depth == 0 {
                return Some(j);
            }
            depth -= 1;
        }
    }
    None
}

/// An owned, editable start tag.
#[derive(Debug, Clone)]
pub(crate) struct TagBuilder {
    pub name: String,
    /// (name, raw value)
    pub attrs: Vec<(String, Option<String>)>,
    pub self_closing: bool,
}

impl TagBuilder {
    pub fn from_token(t: &Token) -> Self {
        TagBuilder {
            name: t.name.to_string(),
            attrs: t
                .attrs
                .iter()
                .map(|a| (a.name.to_string(), a.value.map(|v| v.to_string())))
                .collect(),
            self_closing: t.self_closing,
        }
    }

    pub fn remove(&mut self, name: &str) {
        self.attrs.retain(|(n, _)| !n.eq_ignore_ascii_case(name));
    }

    /// Sets an attribute; `raw_value` must already be entity-encoded where needed.
    pub fn set(&mut self, name: &str, raw_value: &str) {
        if let Some(a) = self
            .attrs
            .iter_mut()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
        {
            a.1 = Some(raw_value.to_string());
        } else {
            self.attrs.push((name.to_string(), Some(raw_value.to_string())));
        }
    }

    pub fn build(&self) -> String {
        let mut s = String::with_capacity(16 + self.attrs.len() * 16);
        s.push('<');
        s.push_str(&self.name);
        for (n, v) in &self.attrs {
            s.push(' ');
            s.push_str(n);
            if let Some(v) = v {
                s.push_str("=\"");
                // values from single-quoted attributes may contain a literal `"`
                s.push_str(&v.replace('"', "&quot;"));
                s.push('"');
            }
        }
        if self.self_closing {
            s.push_str(" /");
        }
        s.push('>');
        s
    }
}

/// Applies non-overlapping `(start, end, replacement)` edits. Overlapping edits (later in
/// sort order) are dropped.
pub(crate) fn apply_edits(s: &str, mut edits: Vec<(usize, usize, String)>) -> String {
    if edits.is_empty() {
        return s.to_string();
    }
    edits.sort_by_key(|e| (e.0, e.1));
    let mut out = String::with_capacity(s.len() + edits.iter().map(|e| e.2.len()).sum::<usize>());
    let mut pos = 0;
    for (start, end, rep) in edits {
        if start < pos || end < start || end > s.len() {
            continue;
        }
        out.push_str(&s[pos..start]);
        out.push_str(&rep);
        pos = end;
    }
    out.push_str(&s[pos..]);
    out
}

/// Decodes the HTML character references that matter for attribute values (named basics plus
/// numeric references). Unknown references are kept verbatim.
pub(crate) fn decode_entities(s: &str) -> Cow<'_, str> {
    if !s.contains('&') {
        return Cow::Borrowed(s);
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        rest = &rest[amp..];
        let semi = rest[1..].find(';').map(|p| p + 1);
        let decoded = semi.filter(|&p| p <= 12).and_then(|p| {
            let ent = &rest[1..p];
            let ch = if let Some(num) = ent.strip_prefix('#') {
                let v = if let Some(hex) = num.strip_prefix(['x', 'X']) {
                    u32::from_str_radix(hex, 16).ok()
                } else {
                    num.parse::<u32>().ok()
                };
                v.and_then(char::from_u32)
            } else {
                match ent {
                    "amp" => Some('&'),
                    "lt" => Some('<'),
                    "gt" => Some('>'),
                    "quot" => Some('"'),
                    "apos" => Some('\''),
                    "nbsp" => Some('\u{a0}'),
                    _ => None,
                }
            };
            ch.map(|c| (c, p + 1))
        });
        match decoded {
            Some((c, len)) => {
                out.push(c);
                rest = &rest[len..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    Cow::Owned(out)
}

/// Escapes text for use inside a double-quoted attribute value.
pub(crate) fn escape_attr(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('"', "&quot;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// Percent-decodes `%XX` sequences; None if nothing to decode or the result is not UTF-8.
pub(crate) fn percent_decode(s: &str) -> Option<String> {
    if !s.contains('%') {
        return None;
    }
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    let mut changed = false;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hex = std::str::from_utf8(&b[i + 1..i + 3]).ok();
            if let Some(v) = hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(v);
                i += 3;
                changed = true;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    if !changed {
        return None;
    }
    String::from_utf8(out).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokenizes_basic() {
        let s = r#"a<div id="x" class='a b' data-y=3 hidden>t</div><!-- c --><br/>"#;
        let t = tokenize(s);
        let kinds: Vec<_> = t.iter().map(|t| t.kind).collect();
        assert_eq!(
            kinds,
            vec![
                Kind::Text,
                Kind::StartTag,
                Kind::Text,
                Kind::EndTag,
                Kind::Comment,
                Kind::StartTag
            ]
        );
        assert_eq!(t[1].attr("id"), Some("x"));
        assert!(t[1].has_class("b"));
        assert_eq!(t[1].attr("data-y"), Some("3"));
        assert_eq!(t[1].attr("hidden"), Some(""));
        assert!(t[5].self_closing);
    }

    #[test]
    fn raw_text_and_gt_in_attr() {
        let s = r#"<script>if (a<b) x="</div>";</script><img alt="a>b" src=x.jpg>"#;
        let t = tokenize(s);
        assert!(t[0].is_start("script"));
        assert_eq!(t[1].kind, Kind::Text);
        assert!(t[2].is_end("script"));
        assert!(t[3].is_start("img"));
        assert_eq!(t[3].attr("src"), Some("x.jpg"));
        assert_eq!(t[3].attr("alt"), Some("a>b"));
    }

    #[test]
    fn garbage_never_panics() {
        for s in [
            "<", "<<", "</", "<a", "<a b", "<a b=", "<a b='", "<a b=\"x", "<!--", "<!", "<?",
            "<script>", "<script", "</script", "<é>", "<aé=1>", "<a é>", "<a\u{fffd}=\"\">",
            "&#xFFFFFFFF;", "&#;", "&", "&amp", "<div><div></div>", "%", "%4", "%zz",
        ] {
            let t = tokenize(s);
            let _ = apply_edits(s, vec![(0, s.len(), String::new())]);
            for tok in &t {
                let _ = &s[tok.start..tok.end];
            }
            let _ = decode_entities(s);
            let _ = percent_decode(s);
        }
    }

    #[test]
    fn entities_and_percent() {
        assert_eq!(decode_entities("a&amp;b&#39;c&#x41;&bogus;"), "a&b'cA&bogus;");
        assert_eq!(percent_decode("my%20file%C3%A9.jpg").as_deref(), Some("my fileé.jpg"));
        assert_eq!(percent_decode("100%"), None);
    }
}
