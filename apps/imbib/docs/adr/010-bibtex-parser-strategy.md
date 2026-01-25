# ADR-010: BibTeX Parser Strategy

## Status

Accepted

## Date

2026-01-04

## Context

We need to parse BibTeX files with high fidelity to maintain BibDesk compatibility. Options:

1. **Wrap btparse** - The C library used by many BibTeX tools
2. **Write custom Swift parser** - From scratch or using parser combinator library
3. **Port existing parser** - Adapt implementation from another language
4. **Use BibDesk's parser** - Extract/wrap the Objective-C implementation

### btparse Analysis

[btparse](https://metacpan.org/dist/Text-BibTeX/view/btparse/doc/btparse.pod) is a mature C library from the [btOOL project](https://www.gerg.ca/software/btOOL/):

**Pros:**
- Battle-tested (20+ years)
- Handles edge cases (macros, crossref, nested braces)
- Used by many tools

**Cons:**
- **Not thread-safe**: Uses global variables extensively. From the documentation: "the scanner and parser are both heavily dependent on global variables, meaning that thread safety -- or even the ability to have two files open and being parsed at the same time -- is well-nigh impossible."
- **Static stack limits**: "entries with a large number of fields (more than about 90) will cause the parser to crash"
- Requires C bridging
- No async support
- Last substantial update was years ago

The thread-safety issue is critical: Swift's `actor` model and structured concurrency assume components can run concurrently. btparse cannot.

### Custom Swift Parser Analysis

**Pros:**
- 100% Swift (no bridging)
- Thread-safe by design
- Can use modern parser combinators ([swift-parsing](https://github.com/pointfreeco/swift-parsing))
- Async-friendly
- Tailored to our exact needs
- Claude Code generates reliable Swift

**Cons:**
- Development effort
- Risk of edge case bugs
- No existing test suite

### BibDesk Parser Analysis

[BibDesk](https://bibdesk.sourceforge.io/) is open source (BSD license) and has an Objective-C parser:

**Pros:**
- Same parsing behavior as BibDesk (compatibility)
- Handles real-world files
- Has test coverage

**Cons:**
- Objective-C (need bridging or port)
- Tightly coupled to BibDesk's data model
- May have same thread-safety issues

## Decision

**Write a custom Swift parser** using [swift-parsing](https://github.com/pointfreeco/swift-parsing) from Point-Free, with extensive test fixtures derived from BibDesk's test files.

## Rationale

### Thread Safety is Non-Negotiable

Our architecture uses `actor` for services and expects concurrent operations. btparse's global state would require a single serial queue for all parsing, creating a bottleneck.

### BibTeX is a Well-Defined Format

While BibTeX has quirks, it's documented and finite:
- Entry types: `@article{...}`, `@book{...}`, etc.
- Field syntax: `name = {value}` or `name = "value"` or `name = 123`
- String macros: `@string{name = "value"}`
- Concatenation: `field = macro # "literal"`
- Preamble: `@preamble{...}`
- Comments: `@comment{...}` and implicit comments

This is tractable for a custom parser.

### swift-parsing Provides Solid Foundation

Point-Free's swift-parsing library offers:
- Composable parser combinators
- Excellent error messages
- Good performance
- Well-tested
- Swift 6 concurrency compatible

### Test-Driven Development Mitigates Risk

We will:
1. Collect test fixtures from BibDesk's source repository
2. Add fixtures from problematic real-world `.bib` files
3. Aim for 100% test coverage of parser
4. Validate round-trip: parse → export → parse produces identical result

## Implementation

### Parser Architecture

```swift
import Parsing

// Top-level parser
struct BibTeXFileParser: Parser {
    var body: some Parser<Substring, [BibTeXItem]> {
        Many {
            OneOf {
                EntryParser()
                StringMacroParser()
                PreambleParser()
                CommentParser()
            }
        } separator: {
            Whitespace()
        }
    }
}

// Individual item types
enum BibTeXItem {
    case entry(BibTeXEntry)
    case stringMacro(name: String, value: FieldValue)
    case preamble(String)
    case comment(String)
}
```

### Entry Parser

```swift
struct EntryParser: Parser {
    var body: some Parser<Substring, BibTeXEntry> {
        Parse(BibTeXEntry.init) {
            "@"
            EntryTypeParser()      // article, book, etc.
            "{"
            Whitespace()
            CiteKeyParser()        // Einstein1905
            ","
            Whitespace()
            FieldListParser()      // author = {...}, title = {...}
            Whitespace()
            "}"
        }
    }
}
```

### Field Value Parser (handles complexity)

```swift
struct FieldValueParser: Parser {
    var body: some Parser<Substring, FieldValue> {
        // Values can be:
        // 1. Braced: {Some text with {nested} braces}
        // 2. Quoted: "Some text"
        // 3. Number: 2023
        // 4. Macro: journalname
        // 5. Concatenated: macro # " suffix"

        Many {
            OneOf {
                BracedValueParser()
                QuotedValueParser()
                NumberValueParser()
                MacroReferenceParser()
            }
        } separator: {
            Whitespace()
            "#"
            Whitespace()
        }
    }
}
```

### Nested Brace Handling

The tricky part of BibTeX parsing:

```swift
struct BracedValueParser: Parser {
    var body: some Parser<Substring, String> {
        "{"
        NestedBraceContent()
        "}"
    }
}

struct NestedBraceContent: Parser {
    var body: some Parser<Substring, String> {
        Many {
            OneOf {
                // Escaped characters
                Parse { "\\" ; First() }.map { "\\\($0)" }

                // Nested braces (recursive)
                Parse {
                    "{"
                    Lazy { NestedBraceContent() }
                    "}"
                }.map { "{\($0)}" }

                // Regular characters (not braces)
                Prefix(1...) { $0 != "{" && $0 != "}" && $0 != "\\" }
                    .map(String.init)
            }
        }.map { $0.joined() }
    }
}
```

### Macro Expansion

```swift
actor BibTeXProcessor {
    private var macros: [String: FieldValue] = [:]

    // Built-in month macros
    private static let defaultMacros: [String: String] = [
        "jan": "January", "feb": "February", "mar": "March",
        "apr": "April", "may": "May", "jun": "June",
        "jul": "July", "aug": "August", "sep": "September",
        "oct": "October", "nov": "November", "dec": "December"
    ]

    func process(_ items: [BibTeXItem]) -> [BibTeXEntry] {
        var entries: [BibTeXEntry] = []

        for item in items {
            switch item {
            case .stringMacro(let name, let value):
                macros[name.lowercased()] = value

            case .entry(var entry):
                entry.fields = expandMacros(in: entry.fields)
                entries.append(entry)

            case .preamble, .comment:
                break
            }
        }

        return entries
    }

    private func expandMacros(in fields: [String: FieldValue]) -> [String: String] {
        fields.mapValues { value in
            value.components.map { component in
                switch component {
                case .literal(let s): return s
                case .macro(let name): return macros[name.lowercased()]?.asString ?? name
                case .number(let n): return String(n)
                }
            }.joined()
        }
    }
}
```

### LaTeX Character Decoding

```swift
struct LaTeXDecoder {
    private static let replacements: [(pattern: String, replacement: String)] = [
        // Accents
        (#"\{\\\"([aeiouAEIOU])\}"#, "äëïöüÄËÏÖÜ"),  // Needs per-char handling
        (#"\\\"([aeiouAEIOU])"#, "äëïöüÄËÏÖÜ"),
        (#"\{\\'([aeiouAEIOU])\}"#, "áéíóúÁÉÍÓÚ"),
        (#"\\'([aeiouAEIOU])"#, "áéíóúÁÉÍÓÚ"),
        // Special characters
        (#"\\&"#, "&"),
        (#"\\%"#, "%"),
        (#"\\#"#, "#"),
        (#"~"#, "\u{00A0}"),  // Non-breaking space
        (#"--"#, "–"),        // En-dash
        (#"---"#, "—"),       // Em-dash
    ]

    static func decode(_ input: String) -> String {
        var result = input
        // Apply replacements...
        return result
    }
}
```

### Crossref Resolution

```swift
extension BibTeXProcessor {
    func resolveCrossrefs(_ entries: inout [BibTeXEntry]) {
        let byKey = Dictionary(entries.map { ($0.citeKey.lowercased(), $0) }) { first, _ in first }

        for i in entries.indices {
            guard let crossref = entries[i].fields["crossref"]?.lowercased(),
                  let parent = byKey[crossref] else {
                continue
            }

            // Inherit missing fields from parent
            for (key, value) in parent.fields where entries[i].fields[key] == nil {
                entries[i].fields[key] = value
            }
        }
    }
}
```

## Test Strategy

### Test Fixtures Sources

1. **BibDesk test suite**: Extract from SourceForge repository
2. **Real-world files**: Collect from Overleaf, arXiv submissions
3. **Edge cases**: Manually crafted for specific parser behaviors
4. **Fuzzing**: Use swift-parsing's error recovery testing

### Test Categories

```swift
final class BibTeXParserTests: XCTestCase {

    // MARK: - Basic Parsing

    func testParseSimpleArticle() throws {
        let input = """
        @article{Einstein1905,
            author = {Albert Einstein},
            title = {On the Electrodynamics of Moving Bodies},
            year = 1905
        }
        """
        let entries = try BibTeXParser.parse(input)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].citeKey, "Einstein1905")
    }

    // MARK: - Nested Braces

    func testNestedBraces() throws {
        let input = """
        @article{key,
            title = {The {DNA} of {E. coli} in {vitro}}
        }
        """
        let entries = try BibTeXParser.parse(input)
        XCTAssertEqual(entries[0].fields["title"], "The {DNA} of {E. coli} in {vitro}")
    }

    // MARK: - String Macros

    func testStringMacroExpansion() throws {
        let input = """
        @string{nature = "Nature"}
        @article{key,
            journal = nature
        }
        """
        let entries = try BibTeXParser.parse(input)
        XCTAssertEqual(entries[0].fields["journal"], "Nature")
    }

    // MARK: - Concatenation

    func testStringConcatenation() throws {
        let input = """
        @string{jnl = "Journal of"}
        @article{key,
            journal = jnl # " Physics"
        }
        """
        let entries = try BibTeXParser.parse(input)
        XCTAssertEqual(entries[0].fields["journal"], "Journal of Physics")
    }

    // MARK: - Crossref

    func testCrossrefInheritance() throws {
        let input = """
        @inproceedings{paper,
            author = {Smith},
            crossref = {conf}
        }
        @proceedings{conf,
            booktitle = {Conference 2023},
            year = 2023
        }
        """
        let entries = try BibTeXParser.parse(input)
        let paper = entries.first { $0.citeKey == "paper" }!
        XCTAssertEqual(paper.fields["booktitle"], "Conference 2023")
    }

    // MARK: - Round-Trip

    func testRoundTrip() throws {
        let original = try String(contentsOfFile: "fixtures/complex.bib")
        let entries = try BibTeXParser.parse(original)
        let exported = BibTeXExporter.export(entries)
        let reparsed = try BibTeXParser.parse(exported)

        XCTAssertEqual(entries.count, reparsed.count)
        for (e1, e2) in zip(entries, reparsed) {
            XCTAssertEqual(e1.citeKey, e2.citeKey)
            XCTAssertEqual(e1.fields, e2.fields)
        }
    }
}
```

## Consequences

### Positive

- Thread-safe, works with Swift concurrency
- No C dependencies
- Full control over parsing behavior
- Can add features (better error messages, streaming)
- Testable in isolation

### Negative

- Development effort (estimated: 1-2 weeks)
- Potential for edge case bugs
- No existing user base validating correctness

### Mitigations

- Extensive test fixtures from BibDesk
- Round-trip testing for every fixture
- Gradual rollout with "strict mode" that flags suspicious parses
- User bug reports for edge cases

## Alternatives Considered

### Wrap btparse

Rejected due to thread-safety issues. Would require serial queue for all parsing, creating bottleneck.

### Use BibDesk's Parser Directly

Would require significant Objective-C bridging and may have similar thread-safety concerns. Also tightly coupled to BibDesk's data model.

### Port bibtexparser (Python)

The Python library [bibtexparser](https://github.com/sciunto-org/python-bibtexparser) is well-maintained but uses a different parsing approach (pyparsing → lark). Would need complete rewrite, not port.

### Use ANTLR with Swift Target

ANTLR can generate Swift parsers from grammar files. However:
- Generated code is verbose
- Runtime dependency
- Less composable than swift-parsing
- Overkill for BibTeX complexity

## References

- [btparse documentation](https://metacpan.org/dist/Text-BibTeX/view/btparse/doc/btparse.pod)
- [swift-parsing](https://github.com/pointfreeco/swift-parsing)
- [BibTeX format specification](http://www.bibtex.org/Format/)
- [BibDesk source](https://sourceforge.net/projects/bibdesk/)
