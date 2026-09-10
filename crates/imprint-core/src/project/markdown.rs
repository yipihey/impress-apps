//! Markdown via Typst (ADR-0030 D10). A Markdown entry is converted to
//! Typst source and compiled by the same engine, so a `.md` manuscript gets
//! the tree, the figures, the bibliographies and the PDF a Typst one has.
//!
//! The conversion is structural (CommonMark + tables, footnotes, task
//! lists, strikethrough, math, YAML front matter through `pulldown-cmark`)
//! and honest about what it cannot carry: raw HTML is dropped with a
//! warning, LaTeX math is translated by a small table and otherwise passed
//! through. Pandoc-style citations (`@key`, `[@a; @b]`) become Typst
//! citations, which is what the projected bibliographies resolve.

use std::collections::HashMap;
use std::sync::OnceLock;

use pulldown_cmark::{Alignment, CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};
use regex::Regex;

/// What a conversion produced.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TypstConversion {
    pub typst: String,
    /// From the front matter, when there was one.
    pub title: Option<String>,
    /// A `bibliography:` front-matter path, emitted as `#bibliography(...)`.
    pub bibliography: Option<String>,
    pub warnings: Vec<String>,
}

/// Convert Markdown to Typst markup.
pub fn to_typst(markdown: &str) -> TypstConversion {
    let mut options = Options::empty();
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_FOOTNOTES);
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TASKLISTS);
    options.insert(Options::ENABLE_MATH);
    options.insert(Options::ENABLE_YAML_STYLE_METADATA_BLOCKS);
    let events: Vec<Event<'_>> = Parser::new_ext(markdown, options).collect();

    // Footnote definitions first, so a reference can inline its text.
    let mut footnotes: HashMap<String, String> = HashMap::new();
    let mut body: Vec<Event<'_>> = Vec::with_capacity(events.len());
    let mut i = 0;
    while i < events.len() {
        if let Event::Start(Tag::FootnoteDefinition(label)) = &events[i] {
            let label = label.to_string();
            let mut depth = 0usize;
            let mut inner: Vec<Event<'_>> = Vec::new();
            i += 1;
            while i < events.len() {
                match &events[i] {
                    Event::Start(Tag::FootnoteDefinition(_)) => depth += 1,
                    Event::End(TagEnd::FootnoteDefinition) => {
                        if depth == 0 {
                            break;
                        }
                        depth -= 1;
                    }
                    _ => {}
                }
                inner.push(events[i].clone());
                i += 1;
            }
            let none: HashMap<String, String> = HashMap::new();
            let mut w = Writer::new(&none);
            w.render(&inner);
            footnotes.insert(label, w.finish().trim().to_string());
        } else {
            body.push(events[i].clone());
        }
        i += 1;
    }

    let mut w = Writer::new(&footnotes);
    w.render(&body);
    let mut typst = w.finish();
    if let Some(bib) = &w.bibliography {
        typst.push_str(&format!("\n#bibliography(\"{}\")\n", escape_string(bib)));
    }
    TypstConversion {
        typst,
        title: w.title.clone(),
        bibliography: w.bibliography.clone(),
        warnings: w.warnings,
    }
}

struct TableState {
    aligns: Vec<Alignment>,
    header: Vec<String>,
    cells: Vec<String>,
    in_head: bool,
}

struct Writer<'f> {
    out: String,
    /// Consecutive text events, joined before escaping, so a citation
    /// pulldown split around its brackets is still seen whole.
    pending: String,
    footnotes: &'f HashMap<String, String>,
    /// (ordered, depth) per open list.
    lists: Vec<bool>,
    /// Buffers captured while inside a table cell / an image's alt text.
    stack: Vec<String>,
    table: Option<TableState>,
    image: Option<String>,
    in_code_block: bool,
    in_metadata: bool,
    title: Option<String>,
    bibliography: Option<String>,
    warnings: Vec<String>,
}

impl<'f> Writer<'f> {
    fn new(footnotes: &'f HashMap<String, String>) -> Self {
        Self {
            out: String::new(),
            pending: String::new(),
            footnotes,
            lists: Vec::new(),
            stack: Vec::new(),
            table: None,
            image: None,
            in_code_block: false,
            in_metadata: false,
            title: None,
            bibliography: None,
            warnings: Vec::new(),
        }
    }

    fn finish(&mut self) -> String {
        self.flush_text();
        let mut s = std::mem::take(&mut self.out);
        while s.ends_with("\n\n\n") {
            s.pop();
        }
        if !s.ends_with('\n') {
            s.push('\n');
        }
        s
    }

    fn push(&mut self, s: &str) {
        self.out.push_str(s);
    }

    /// Start a new block: at most one blank line before it.
    fn block_break(&mut self) {
        if self.out.is_empty() {
            return;
        }
        while self.out.ends_with("\n\n\n") {
            self.out.pop();
        }
        if !self.out.ends_with("\n\n") {
            if !self.out.ends_with('\n') {
                self.out.push('\n');
            }
            self.out.push('\n');
        }
    }

    fn capture_start(&mut self) {
        self.stack.push(std::mem::take(&mut self.out));
    }

    fn capture_end(&mut self) -> String {
        let captured = std::mem::take(&mut self.out);
        self.out = self.stack.pop().unwrap_or_default();
        captured
    }

    fn at_line_start(&self) -> bool {
        self.out.is_empty() || self.out.ends_with('\n')
    }

    fn render(&mut self, events: &[Event<'_>]) {
        for ev in events {
            self.event(ev);
        }
        self.flush_text();
    }

    /// Escape and emit the buffered text run.
    fn flush_text(&mut self) {
        if self.pending.is_empty() {
            return;
        }
        let text = std::mem::take(&mut self.pending);
        let escaped = if self.image.is_some() {
            escape_text(&text, self.at_line_start())
        } else {
            text_with_citations(&text, self.at_line_start())
        };
        self.push(&escaped);
    }

    fn event(&mut self, ev: &Event<'_>) {
        if let Event::Text(t) = ev {
            if self.in_code_block || self.in_metadata {
                self.push(t);
            } else {
                self.pending.push_str(t);
            }
            return;
        }
        self.flush_text();
        match ev {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(tag),
            Event::Code(c) => {
                if c.contains('`') {
                    self.push(&format!("``` {c} ```"));
                } else {
                    self.push(&format!("`{c}`"));
                }
            }
            Event::InlineMath(m) => {
                self.push(&format!("${}$", latex_math_to_typst(m)));
            }
            Event::DisplayMath(m) => {
                self.block_break();
                self.push(&format!("$ {} $\n\n", latex_math_to_typst(m)));
            }
            Event::Html(h) | Event::InlineHtml(h) => {
                let trimmed = h.trim();
                if trimmed.eq_ignore_ascii_case("<br>") || trimmed.eq_ignore_ascii_case("<br/>") {
                    self.push(" \\\n");
                } else if trimmed.starts_with("<!--") {
                    // A comment: nothing to carry.
                } else {
                    self.warnings.push(format!(
                        "raw HTML dropped: {}",
                        trimmed.lines().next().unwrap_or_default()
                    ));
                }
            }
            Event::FootnoteReference(label) => {
                let text = self
                    .footnotes
                    .get(&**label)
                    .cloned()
                    .unwrap_or_else(|| escape_text(label, false));
                self.push(&format!("#footnote[{text}]"));
            }
            Event::SoftBreak => self.push(" "),
            Event::HardBreak => self.push(" \\\n"),
            Event::Rule => {
                self.block_break();
                self.push("#line(length: 100%)\n\n");
            }
            Event::TaskListMarker(done) => self.push(if *done { "☒ " } else { "☐ " }),
            _ => {}
        }
    }

    fn start(&mut self, tag: &Tag<'_>) {
        match tag {
            Tag::Paragraph => {
                // A paragraph opening a block quote starts right after `[`.
                if self.lists.is_empty()
                    && self.table.is_none()
                    && self.stack.is_empty()
                    && !self.out.ends_with("[\n")
                {
                    self.block_break();
                }
            }
            Tag::Heading { level, .. } => {
                self.block_break();
                let n = match level {
                    HeadingLevel::H1 => 1,
                    HeadingLevel::H2 => 2,
                    HeadingLevel::H3 => 3,
                    HeadingLevel::H4 => 4,
                    HeadingLevel::H5 => 5,
                    HeadingLevel::H6 => 6,
                };
                self.push(&"=".repeat(n));
                self.push(" ");
            }
            Tag::BlockQuote(_) => {
                self.block_break();
                self.push("#quote(block: true)[\n");
            }
            Tag::CodeBlock(kind) => {
                self.block_break();
                self.in_code_block = true;
                match kind {
                    CodeBlockKind::Fenced(lang) => {
                        let lang: String = lang
                            .split([',', ' ', '{'])
                            .next()
                            .unwrap_or_default()
                            .to_string();
                        self.push(&format!("```{lang}\n"));
                    }
                    CodeBlockKind::Indented => self.push("```\n"),
                }
            }
            Tag::List(start) => {
                if self.lists.is_empty() {
                    self.block_break();
                } else if !self.out.ends_with('\n') {
                    self.push("\n");
                }
                self.lists.push(start.is_some());
            }
            Tag::Item => {
                let depth = self.lists.len().saturating_sub(1);
                let ordered = self.lists.last().copied().unwrap_or(false);
                if !self.at_line_start() {
                    self.push("\n");
                }
                self.push(&"  ".repeat(depth));
                self.push(if ordered { "+ " } else { "- " });
            }
            Tag::Emphasis => self.push("_"),
            Tag::Strong => self.push("*"),
            Tag::Strikethrough => self.push("#strike["),
            Tag::Link { dest_url, .. } => {
                self.push(&format!("#link(\"{}\")[", escape_string(dest_url)));
            }
            Tag::Image { dest_url, .. } => {
                self.image = Some(dest_url.to_string());
                self.capture_start();
            }
            Tag::Table(aligns) => {
                self.block_break();
                self.table = Some(TableState {
                    aligns: aligns.clone(),
                    header: Vec::new(),
                    cells: Vec::new(),
                    in_head: false,
                });
            }
            Tag::TableHead => {
                if let Some(t) = self.table.as_mut() {
                    t.in_head = true;
                }
            }
            Tag::TableRow => {}
            Tag::TableCell => self.capture_start(),
            Tag::MetadataBlock(_) => {
                self.in_metadata = true;
                self.capture_start();
            }
            _ => {}
        }
    }

    fn end(&mut self, tag: &TagEnd) {
        match tag {
            TagEnd::Paragraph => {
                if self.lists.is_empty() && self.table.is_none() && self.stack.is_empty() {
                    self.push("\n\n");
                } else if !self.lists.is_empty() && self.stack.is_empty() {
                    self.push("\n");
                }
            }
            TagEnd::Heading(_) => self.push("\n\n"),
            TagEnd::BlockQuote(_) => {
                while self.out.ends_with('\n') {
                    self.out.pop();
                }
                self.push("\n]\n\n");
            }
            TagEnd::CodeBlock => {
                self.in_code_block = false;
                if !self.out.ends_with('\n') {
                    self.push("\n");
                }
                self.push("```\n\n");
            }
            TagEnd::List(_) => {
                self.lists.pop();
                if self.lists.is_empty() {
                    if !self.out.ends_with('\n') {
                        self.push("\n");
                    }
                    self.push("\n");
                }
            }
            TagEnd::Item => {
                if !self.out.ends_with('\n') {
                    self.push("\n");
                }
            }
            TagEnd::Emphasis => self.push("_"),
            TagEnd::Strong => self.push("*"),
            TagEnd::Strikethrough => self.push("]"),
            TagEnd::Link => self.push("]"),
            TagEnd::Image => {
                let alt = self.capture_end();
                let url = self.image.take().unwrap_or_default();
                let alt = alt.trim();
                if alt.is_empty() {
                    self.push(&format!("#image(\"{}\")", escape_string(&url)));
                } else {
                    self.push(&format!(
                        "#figure(image(\"{}\"), caption: [{}])",
                        escape_string(&url),
                        alt
                    ));
                }
            }
            TagEnd::TableCell => {
                let cell = self.capture_end();
                if let Some(t) = self.table.as_mut() {
                    let cell = cell.trim().to_string();
                    if t.in_head {
                        t.header.push(cell);
                    } else {
                        t.cells.push(cell);
                    }
                }
            }
            TagEnd::TableHead => {
                if let Some(t) = self.table.as_mut() {
                    t.in_head = false;
                }
            }
            TagEnd::TableRow => {}
            TagEnd::Table => {
                if let Some(t) = self.table.take() {
                    let n = t.aligns.len().max(1);
                    let align: Vec<&str> = t
                        .aligns
                        .iter()
                        .map(|a| match a {
                            Alignment::Center => "center",
                            Alignment::Right => "right",
                            _ => "left",
                        })
                        .collect();
                    let mut s = format!(
                        "#table(\n  columns: {n},\n  align: ({},),\n",
                        align.join(", ")
                    );
                    if !t.header.is_empty() {
                        s.push_str("  table.header(");
                        s.push_str(
                            &t.header
                                .iter()
                                .map(|h| format!("[*{h}*]"))
                                .collect::<Vec<_>>()
                                .join(", "),
                        );
                        s.push_str("),\n");
                    }
                    for row in t.cells.chunks(n) {
                        s.push_str("  ");
                        s.push_str(
                            &row.iter()
                                .map(|c| format!("[{c}]"))
                                .collect::<Vec<_>>()
                                .join(", "),
                        );
                        s.push_str(",\n");
                    }
                    s.push_str(")\n\n");
                    self.push(&s);
                }
            }
            TagEnd::MetadataBlock(_) => {
                self.in_metadata = false;
                let yaml = self.capture_end();
                self.front_matter(&yaml);
            }
            _ => {}
        }
    }

    /// `title`, `author`/`authors`, `date`, `bibliography` from a YAML
    /// front matter (one level, the common case).
    fn front_matter(&mut self, yaml: &str) {
        let mut title = None;
        let mut authors: Vec<String> = Vec::new();
        let mut date = None;
        let mut in_authors = false;
        for line in yaml.lines() {
            let trimmed = line.trim();
            if in_authors {
                if let Some(item) = trimmed.strip_prefix("- ") {
                    authors.push(unquote(item.split(':').next().unwrap_or(item)));
                    continue;
                }
                in_authors = false;
            }
            let Some((key, value)) = trimmed.split_once(':') else {
                continue;
            };
            let value = value.trim();
            match key.trim() {
                "title" => title = Some(unquote(value)),
                "author" | "authors" => {
                    if value.is_empty() {
                        in_authors = true;
                    } else if let Some(list) =
                        value.strip_prefix('[').and_then(|v| v.strip_suffix(']'))
                    {
                        authors.extend(list.split(',').map(unquote));
                    } else {
                        authors.push(unquote(value));
                    }
                }
                "date" => date = Some(unquote(value)),
                "bibliography" => {
                    let v = value.trim_matches(|c| c == '[' || c == ']');
                    self.bibliography = v.split(',').next().map(unquote).filter(|s| !s.is_empty());
                }
                _ => {}
            }
        }
        let authors: Vec<String> = authors.into_iter().filter(|a| !a.is_empty()).collect();
        if title.is_none() && authors.is_empty() && date.is_none() {
            return;
        }
        let mut s = String::from("#set document(");
        let mut parts = Vec::new();
        if let Some(t) = &title {
            parts.push(format!("title: \"{}\"", escape_string(t)));
        }
        if !authors.is_empty() {
            parts.push(format!(
                "author: ({},)",
                authors
                    .iter()
                    .map(|a| format!("\"{}\"", escape_string(a)))
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
        s.push_str(&parts.join(", "));
        s.push_str(")\n#align(center)[\n");
        if let Some(t) = &title {
            s.push_str(&format!(
                "  #text(size: 1.6em, weight: \"bold\")[{}]\n",
                escape_text(t, false)
            ));
        }
        if !authors.is_empty() {
            s.push_str(&format!(
                "  #v(0.5em) {}\n",
                authors
                    .iter()
                    .map(|a| escape_text(a, false))
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
        if let Some(d) = &date {
            s.push_str(&format!("  #v(0.3em) {}\n", escape_text(d, false)));
        }
        s.push_str("]\n\n");
        self.title = title;
        self.push(&s);
    }
}

fn unquote(s: &str) -> String {
    s.trim()
        .trim_matches(|c| c == '"' || c == '\'')
        .trim()
        .to_string()
}

/// Escape for a Typst string literal.
fn escape_string(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

/// Escape plain text for Typst markup. `line_start` guards the markers
/// that only mean something at the start of a line (`=`, `-`, `+`, `/`).
pub fn escape_text(text: &str, line_start: bool) -> String {
    let mut out = String::with_capacity(text.len() + 8);
    let mut at_start = line_start;
    let chars: Vec<char> = text.chars().collect();
    for (i, &c) in chars.iter().enumerate() {
        match c {
            '\\' | '#' | '$' | '*' | '_' | '`' | '~' | '@' | '<' | '>' | '[' | ']' => {
                out.push('\\');
                out.push(c);
            }
            '/' if chars.get(i + 1) == Some(&'/') || chars.get(i + 1) == Some(&'*') => {
                out.push('\\');
                out.push(c);
            }
            '=' | '-' | '+' if at_start => {
                out.push('\\');
                out.push(c);
            }
            _ => out.push(c),
        }
        at_start = c == '\n';
    }
    out
}

/// Pandoc-style citations become Typst citations; everything else is
/// escaped text.
fn text_with_citations(text: &str, line_start: bool) -> String {
    static BRACKET: OnceLock<Regex> = OnceLock::new();
    static BARE: OnceLock<Regex> = OnceLock::new();
    let bracket = BRACKET.get_or_init(|| {
        Regex::new(r"\[(-?@[A-Za-z0-9_:.\-]+(?:\s*;\s*-?@[A-Za-z0-9_:.\-]+)*)(?:,[^\]]*)?\]")
            .expect("valid regex")
    });
    let bare = BARE.get_or_init(|| {
        Regex::new(r"@([A-Za-z][A-Za-z0-9_:.\-]*[A-Za-z0-9])").expect("valid regex")
    });

    let mut out = String::new();
    let mut last = 0;
    let mut at_start = line_start;
    let emit_plain = |out: &mut String, s: &str, at_start: &mut bool| {
        if s.is_empty() {
            return;
        }
        let mut pos = 0;
        for m in bare.find_iter(s) {
            let before = &s[pos..m.start()];
            let preceded_by_word = s[..m.start()]
                .chars()
                .next_back()
                .map(|c| c.is_alphanumeric())
                .unwrap_or(false);
            if preceded_by_word {
                continue;
            }
            out.push_str(&escape_text(before, *at_start));
            *at_start = before.ends_with('\n') || (before.is_empty() && *at_start);
            out.push_str(m.as_str());
            *at_start = false;
            pos = m.end();
        }
        let rest = &s[pos..];
        out.push_str(&escape_text(rest, *at_start && pos == 0));
        if !rest.is_empty() {
            *at_start = rest.ends_with('\n');
        }
    };
    for caps in bracket.captures_iter(text) {
        let whole = caps.get(0).unwrap();
        emit_plain(&mut out, &text[last..whole.start()], &mut at_start);
        let keys: Vec<String> = caps[1]
            .split(';')
            .map(|k| k.trim())
            .filter(|k| !k.is_empty())
            .map(|k| {
                if let Some(key) = k.strip_prefix("-@") {
                    format!("#cite(<{key}>, form: \"year\")")
                } else {
                    k.to_string()
                }
            })
            .collect();
        out.push_str(&keys.join(" "));
        at_start = false;
        last = whole.end();
    }
    emit_plain(&mut out, &text[last..], &mut at_start);
    out
}

/// A small, honest LaTeX-math → Typst-math translation: the commands that
/// cover most manuscripts' inline math, with the rest passed through (Typst
/// reports what it cannot read, naming the file and line).
pub fn latex_math_to_typst(latex: &str) -> String {
    static GROUPED: &[(&str, &str)] = &[
        ("\\sqrt", "sqrt"),
        ("\\hat", "hat"),
        ("\\vec", "arrow"),
        ("\\bar", "overline"),
        ("\\tilde", "tilde"),
        ("\\dot", "dot"),
        ("\\mathrm", "upright"),
        ("\\mathbf", "bold"),
        ("\\mathcal", "cal"),
        ("\\mathbb", "bb"),
        ("\\boldsymbol", "bold"),
        ("\\underline", "underline"),
        ("\\overline", "overline"),
    ];
    static SIMPLE: &[(&str, &str)] = &[
        ("\\cdot", " dot "),
        ("\\times", " times "),
        ("\\pm", " plus.minus "),
        ("\\mp", " minus.plus "),
        ("\\leq", " <= "),
        ("\\geq", " >= "),
        ("\\le", " <= "),
        ("\\ge", " >= "),
        ("\\neq", " != "),
        ("\\ne", " != "),
        ("\\approx", " approx "),
        ("\\sim", " tilde.op "),
        ("\\propto", " prop "),
        ("\\equiv", " equiv "),
        ("\\infty", " oo "),
        ("\\partial", " diff "),
        ("\\nabla", " nabla "),
        ("\\sum", " sum "),
        ("\\prod", " product "),
        ("\\int", " integral "),
        ("\\ldots", " dots "),
        ("\\cdots", " dots "),
        ("\\dots", " dots "),
        ("\\rightarrow", " -> "),
        ("\\to", " -> "),
        ("\\leftarrow", " <- "),
        ("\\Rightarrow", " => "),
        ("\\left", ""),
        ("\\right", ""),
        ("\\,", " thin "),
        ("\\;", " med "),
        ("\\quad", " quad "),
        ("\\!", ""),
    ];
    static GREEK: &[&str] = &[
        "alpha",
        "beta",
        "gamma",
        "delta",
        "epsilon",
        "varepsilon",
        "zeta",
        "eta",
        "theta",
        "vartheta",
        "iota",
        "kappa",
        "lambda",
        "mu",
        "nu",
        "xi",
        "pi",
        "rho",
        "sigma",
        "tau",
        "upsilon",
        "phi",
        "varphi",
        "chi",
        "psi",
        "omega",
        "Gamma",
        "Delta",
        "Theta",
        "Lambda",
        "Xi",
        "Pi",
        "Sigma",
        "Upsilon",
        "Phi",
        "Psi",
        "Omega",
    ];

    let mut s = latex.trim().to_string();
    // \frac{a}{b} → (a)/(b); \sqrt{x} → sqrt(x); \hat{x} → hat(x) …
    s = replace_two_arg(&s, "\\frac", |a, b| format!("({a})/({b})"));
    s = replace_two_arg(&s, "\\dfrac", |a, b| format!("({a})/({b})"));
    s = replace_two_arg(&s, "\\tfrac", |a, b| format!("({a})/({b})"));
    for (cmd, func) in GROUPED {
        s = replace_one_arg(&s, cmd, |a| format!("{func}({a})"));
    }
    s = replace_one_arg(&s, "\\text", |a| format!("\"{}\"", a.trim()));
    s = replace_one_arg(&s, "\\operatorname", |a| format!("op(\"{}\")", a.trim()));
    // ^{...} and _{...} → ^(...) and _(...)
    s = replace_script_groups(&s);
    for (cmd, rep) in SIMPLE {
        s = replace_command(&s, cmd, rep);
    }
    for g in GREEK {
        s = replace_command(&s, &format!("\\{g}"), &format!(" {g} "));
    }
    // Remaining braces are grouping: Typst uses parentheses.
    s = s.replace('{', "(").replace('}', ")");
    // Collapse the spaces the replacements introduced.
    let mut collapsed = String::with_capacity(s.len());
    let mut prev_space = false;
    for c in s.chars() {
        if c == ' ' {
            if !prev_space {
                collapsed.push(c);
            }
            prev_space = true;
        } else {
            collapsed.push(c);
            prev_space = false;
        }
    }
    collapsed
        .replace(" ^", "^")
        .replace(" _", "_")
        .replace(" )", ")")
        .replace("( ", "(")
        .replace(" ,", ",")
        .trim()
        .to_string()
}

/// Replace `cmd` when it is followed by a non-letter (so `\le` does not eat
/// `\left`, which is replaced first anyway).
fn replace_command(s: &str, cmd: &str, rep: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(pos) = rest.find(cmd) {
        let after = &rest[pos + cmd.len()..];
        let boundary = after
            .chars()
            .next()
            .map(|c| !c.is_ascii_alphabetic())
            .unwrap_or(true);
        out.push_str(&rest[..pos]);
        if boundary {
            out.push_str(rep);
        } else {
            out.push_str(cmd);
        }
        rest = after;
    }
    out.push_str(rest);
    out
}

/// The `{…}` group starting at `s[start]`, with nesting. Returns the inner
/// text and the index after the closing brace.
fn brace_group(s: &str, start: usize) -> Option<(String, usize)> {
    let bytes = s.as_bytes();
    if bytes.get(start) != Some(&b'{') {
        return None;
    }
    let mut depth = 0usize;
    for (i, &b) in bytes.iter().enumerate().skip(start) {
        match b {
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return Some((s[start + 1..i].to_string(), i + 1));
                }
            }
            _ => {}
        }
    }
    None
}

fn replace_one_arg(s: &str, cmd: &str, f: impl Fn(&str) -> String) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(pos) = rest.find(cmd) {
        out.push_str(&rest[..pos]);
        let after = pos + cmd.len();
        let arg_start = after + rest[after..].len() - rest[after..].trim_start().len();
        match brace_group(rest, arg_start) {
            Some((inner, end)) => {
                out.push_str(&f(&latex_math_to_typst_inner(&inner)));
                rest = &rest[end..];
            }
            None => {
                out.push_str(cmd);
                rest = &rest[after..];
            }
        }
    }
    out.push_str(rest);
    out
}

fn replace_two_arg(s: &str, cmd: &str, f: impl Fn(&str, &str) -> String) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(pos) = rest.find(cmd) {
        out.push_str(&rest[..pos]);
        let after = pos + cmd.len();
        let a_start = after + rest[after..].len() - rest[after..].trim_start().len();
        let Some((a, a_end)) = brace_group(rest, a_start) else {
            out.push_str(cmd);
            rest = &rest[after..];
            continue;
        };
        let b_start = a_end + rest[a_end..].len() - rest[a_end..].trim_start().len();
        let Some((b, b_end)) = brace_group(rest, b_start) else {
            out.push_str(cmd);
            rest = &rest[after..];
            continue;
        };
        out.push_str(&f(
            &latex_math_to_typst_inner(&a),
            &latex_math_to_typst_inner(&b),
        ));
        rest = &rest[b_end..];
    }
    out.push_str(rest);
    out
}

/// Nested arguments are translated the same way (without the final
/// brace-to-paren pass, which the caller applies once).
fn latex_math_to_typst_inner(s: &str) -> String {
    latex_math_to_typst(s)
}

fn replace_script_groups(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    loop {
        let Some(pos) = rest.find(['^', '_']) else {
            out.push_str(rest);
            break;
        };
        out.push_str(&rest[..=pos]);
        match brace_group(rest, pos + 1) {
            Some((inner, end)) => {
                out.push('(');
                out.push_str(&inner);
                out.push(')');
                rest = &rest[end..];
            }
            None => rest = &rest[pos + 1..],
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blocks_convert_to_typst_markup() {
        let md = "---\ntitle: A Paper\nauthor: Ada\nbibliography: refs.bib\n---\n\n# Intro\n\nSome *emphasis* and **strong** text with `code` and a [link](https://x.org).\n\n## List\n\n- one\n- two\n  - nested\n\n1. first\n2. second\n\n> quoted\n\n```python\nprint(1)\n```\n\n| a | b |\n|:--|--:|\n| 1 | 2 |\n\n---\n\n![A figure](figures/f.png)\n";
        let c = to_typst(md);
        assert_eq!(c.title.as_deref(), Some("A Paper"));
        assert_eq!(c.bibliography.as_deref(), Some("refs.bib"));
        let t = &c.typst;
        assert!(
            t.contains("#set document(title: \"A Paper\", author: (\"Ada\",))"),
            "{t}"
        );
        assert!(t.contains("= Intro\n"), "{t}");
        assert!(t.contains("== List\n"), "{t}");
        assert!(
            t.contains(
                "_emphasis_ and *strong* text with `code` and a #link(\"https://x.org\")[link]"
            ),
            "{t}"
        );
        assert!(t.contains("- one\n- two\n  - nested\n"), "{t}");
        assert!(t.contains("+ first\n+ second\n"), "{t}");
        assert!(t.contains("#quote(block: true)[\nquoted\n]"), "{t}");
        assert!(t.contains("```python\nprint(1)\n```"), "{t}");
        assert!(t.contains("#table(\n  columns: 2,\n  align: (left, right,),\n  table.header([*a*], [*b*]),\n  [1], [2],\n)"), "{t}");
        assert!(t.contains("#line(length: 100%)"), "{t}");
        assert!(
            t.contains("#figure(image(\"figures/f.png\"), caption: [A figure])"),
            "{t}"
        );
        assert!(t.trim_end().ends_with("#bibliography(\"refs.bib\")"), "{t}");
        assert!(c.warnings.is_empty(), "{:?}", c.warnings);
    }

    #[test]
    fn text_is_escaped_and_citations_survive() {
        let c = to_typst(
            "Costs #1 are 5$ *not* [@knuth84; @smith20] and @doe21 says [-@doe21], mail a@b.c.\n",
        );
        let t = c.typst.trim();
        assert_eq!(
            t,
            "Costs \\#1 are 5\\$ _not_ @knuth84 @smith20 and @doe21 says #cite(<doe21>, form: \"year\"), mail a\\@b.c."
        );
        let m = to_typst(
            "Inline $\\alpha^{2} + \\frac{a}{b}$ and\n\n$$\\sum_{i=1}^{n} x_i \\leq \\infty$$\n",
        );
        assert!(m.typst.contains("$alpha^(2) + (a)/(b)$"), "{}", m.typst);
        assert!(
            m.typst.contains("$ sum_(i=1)^(n) x_i <= oo $"),
            "{}",
            m.typst
        );
    }

    #[test]
    fn footnotes_and_html() {
        let c = to_typst("A claim[^1] here.<br>Next\n\n<div>raw</div>\n\n[^1]: The note text.\n");
        assert!(
            c.typst
                .contains("A claim#footnote[The note text.] here. \\\nNext"),
            "{}",
            c.typst
        );
        assert_eq!(c.warnings.len(), 1, "{:?}", c.warnings);
        assert!(c.warnings[0].contains("<div>"));
    }
}
