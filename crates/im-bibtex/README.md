# im-bibtex

Fast BibTeX parser, formatter, and toolkit for Rust.

## Features

- **Parsing** — Robust nom-based parser: `@string`, `@preamble`, `@comment`, all entry types, braced/quoted values, string concatenation (`#`), nested braces, error recovery
- **Formatting** — Round-trip BibTeX output with proper field formatting, numeric values without braces
- **LaTeX decoding** — Accents, ligatures, Greek letters, math symbols, TeX commands → Unicode
- **Journal macros** — 70+ AASTeX abbreviations (`\apj` → "Astrophysical Journal")
- **BibDesk support** — Decode/encode `Bdsk-File-*` fields (base64 binary plist)
- **Serialization** — All types derive `Serialize`/`Deserialize` for JSON/TOML/etc.

## Library Usage

```rust
use im_bibtex::{parse, format_entry, decode_latex, expand_journal_macro};

// Parse
let result = parse(r#"
@article{Smith2024,
    author = {John Smith and Jane Doe},
    title  = {Dark Matter in the {Milky Way}},
    year   = {2024},
    journal = \apj,
}
"#.into()).unwrap();

let entry = &result.entries[0];
assert_eq!(entry.cite_key, "Smith2024");
assert_eq!(entry.author(), Some("John Smith and Jane Doe"));
assert_eq!(entry.year(), Some("2024"));

// Format back to BibTeX
let bibtex = format_entry(entry.clone());
println!("{bibtex}");

// Decode LaTeX
assert_eq!(decode_latex(r#"Schr\"{o}dinger"#.into()), "Schrödinger");
assert_eq!(decode_latex(r#"caf\'{e}"#.into()), "café");

// Expand journal macros
assert_eq!(expand_journal_macro("\\apj".into()), "Astrophysical Journal");
assert_eq!(expand_journal_macro("mnras".into()), "Monthly Notices of the Royal Astronomical Society");
```

## CLI

Install with:

```sh
cargo install im-bibtex --features cli
```

### Commands

```sh
# Parse a .bib file to JSON
im-bibtex parse refs.bib

# Parse from stdin
cat refs.bib | im-bibtex parse -

# Reformat/normalize a .bib file
im-bibtex format refs.bib

# Validate a .bib file (reports parse errors and missing fields)
im-bibtex validate refs.bib

# Decode LaTeX to Unicode
im-bibtex latex 'Schr\"{o}dinger'

# Expand a journal macro
im-bibtex journal apj

# List all known journal macros
im-bibtex journals
```

## Supported Entry Types

`article`, `book`, `booklet`, `inbook`, `incollection`, `inproceedings`/`conference`, `manual`, `mastersthesis`, `misc`, `phdthesis`, `proceedings`, `techreport`, `unpublished`, `online`/`electronic`/`www`, `software`, `dataset`

## LaTeX Decoding Coverage

| Category | Examples |
|----------|---------|
| Accents | `\"`, `\'`, `` \` ``, `\^`, `\~`, `\c`, `\r`, `\v`, `\u`, `\=`, `\.`, `\k` |
| Special chars | `\ae`, `\oe`, `\ss`, `\aa`, `\l`, `\o`, `\i` |
| Punctuation | `---` → em dash, `--` → en dash, ` `` ` → left quote |
| Greek | `\alpha`…`\omega`, `\Gamma`…`\Omega` |
| Math | `\times`, `\leq`, `\infty`, `\nabla`, `\sum`, `\int`, etc. |
| Formatting | `\textbf{}`, `\emph{}`, `\textrm{}` → content preserved |

## License

MIT
