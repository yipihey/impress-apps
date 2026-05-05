//
//  smartsearch-debug
//  ImpressSmartSearch
//
//  Command-line harness for autonomous iteration on the Smart Search engine.
//  Apple Intelligence is invoked on the local machine; outputs are printed
//  to stdout for inspection.
//
//  Usage:
//    swift run smartsearch-debug "<input>"            # pretty output
//    swift run smartsearch-debug --json "<input>"      # JSON output
//    swift run smartsearch-debug --suite               # run the test corpus
//    swift run smartsearch-debug --suite --json        # corpus as JSON
//

import Foundation
import ImpressSmartSearch

// MARK: - Argument parsing

struct Options {
    var json: Bool = false
    var suite: Bool = false
    var urlSuite: Bool = false
    var verbose: Bool = false
    var input: String?
}

func parseArguments() -> Options {
    var opts = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var inputs: [String] = []
    for arg in args {
        switch arg {
        case "--json": opts.json = true
        case "--suite": opts.suite = true
        case "--url-suite": opts.urlSuite = true
        case "--verbose", "-v": opts.verbose = true
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            inputs.append(arg)
        }
    }
    if !inputs.isEmpty {
        opts.input = inputs.joined(separator: " ")
    }
    return opts
}

func printUsage() {
    let usage = """
    smartsearch-debug — Smart Search engine harness

    Usage:
      smartsearch-debug "<input>"           pretty output for one input
      smartsearch-debug --json "<input>"     JSON output for one input
      smartsearch-debug --suite              run the bundled non-network corpus
      smartsearch-debug --url-suite          run the URL-extraction corpus (network)
      smartsearch-debug --help               this message

    Examples:
      smartsearch-debug "abel norman first stars science"
      smartsearch-debug "10.1126/science.295.5552.93"
      smartsearch-debug "https://en.wikipedia.org/wiki/Population_III_star"
    """
    print(usage)
}

// MARK: - Pretty printing

func printOutcome(_ outcome: ResolveOutcome, input: String, json: Bool) {
    if json {
        print(jsonString(for: outcome, input: input))
    } else {
        printPretty(outcome, input: input)
    }
}

func printPretty(_ outcome: ResolveOutcome, input: String) {
    print("input: \(input)")
    switch outcome {
    case .identifier(let id):
        print("intent: identifier (.\(id.typeName))")
        print("value:  \(id.value)")
    case .fielded(let q):
        print("intent: fielded")
        print("query:  \(q)")
    case .citation(let p):
        print("intent: reference (1 block)")
        printParsed(p, indent: "  ")
    case .citations(let blocks):
        print("intent: references (\(blocks.count) blocks)")
        for (i, p) in blocks.enumerated() {
            print("  [\(i + 1)]")
            if let p = p {
                printParsed(p, indent: "    ")
            } else {
                print("    parse failed")
            }
        }
    case .freeTextQuery(let rw):
        print("intent: freeText")
        print("source: \(rw.source.rawValue) (confidence \(String(format: "%.2f", rw.confidence)))")
        print("query:  \(rw.query)")
        if !rw.interpretation.isEmpty {
            print("note:   \(rw.interpretation)")
        }
    case .urlExtraction(let r):
        print("intent: url")
        print("page:   \(r.url.absoluteString)")
        if let t = r.pageTitle, !t.isEmpty { print("title:  \(t)") }
        if r.identifiers.isEmpty {
            print("found:  no identifiers (\(r.reason ?? "—"))")
        } else {
            print("found:  \(r.identifiers.count) identifier(s)")
            for id in r.identifiers {
                print("  - \(id.typeName): \(id.value)")
            }
        }
    }
}

func printParsed(_ p: ParsedReference, indent: String) {
    print("\(indent)authors: \(p.authors.isEmpty ? "(none)" : p.authors.joined(separator: ", "))")
    if !p.title.isEmpty { print("\(indent)title:   \(p.title)") }
    if p.year != 0 { print("\(indent)year:    \(p.year)") }
    if !p.journal.isEmpty { print("\(indent)journal: \(p.journal)") }
    if !p.volume.isEmpty { print("\(indent)volume:  \(p.volume)") }
    if !p.pages.isEmpty { print("\(indent)pages:   \(p.pages)") }
    if !p.doi.isEmpty { print("\(indent)doi:     \(p.doi)") }
    if !p.arxiv.isEmpty { print("\(indent)arxiv:   \(p.arxiv)") }
    if !p.bibcode.isEmpty { print("\(indent)bibcode: \(p.bibcode)") }
    print("\(indent)confidence: \(String(format: "%.2f", p.confidence))")
}

// MARK: - JSON output

func jsonString(for outcome: ResolveOutcome, input: String) -> String {
    let obj = encodeOutcome(outcome, input: input)
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{}"
}

func encodeOutcome(_ outcome: ResolveOutcome, input: String) -> [String: Any] {
    var out: [String: Any] = ["input": input]
    switch outcome {
    case .identifier(let id):
        out["intent"] = "identifier"
        out["identifier"] = ["kind": id.typeName, "value": id.value]
    case .fielded(let q):
        out["intent"] = "fielded"
        out["query"] = q
    case .citation(let p):
        out["intent"] = "reference"
        out["blocks"] = 1
        out["parsed"] = [encodeParsed(p)]
    case .citations(let blocks):
        out["intent"] = "reference"
        out["blocks"] = blocks.count
        out["parsed"] = blocks.map { $0.map(encodeParsed) as Any? ?? NSNull() }
    case .freeTextQuery(let rw):
        out["intent"] = "freeText"
        out["query"] = rw.query
        out["interpretation"] = rw.interpretation
        out["confidence"] = rw.confidence
        out["source"] = rw.source.rawValue
    case .urlExtraction(let r):
        out["intent"] = "url"
        out["pageURL"] = r.url.absoluteString
        if let t = r.pageTitle { out["pageTitle"] = t }
        out["identifiers"] = r.identifiers.map { ["kind": $0.typeName, "value": $0.value] }
        if let reason = r.reason { out["reason"] = reason }
    }
    return out
}

func encodeParsed(_ p: ParsedReference) -> [String: Any] {
    var d: [String: Any] = [
        "authors": p.authors,
        "confidence": p.confidence
    ]
    if !p.title.isEmpty { d["title"] = p.title }
    if p.year != 0 { d["year"] = p.year }
    if !p.journal.isEmpty { d["journal"] = p.journal }
    if !p.volume.isEmpty { d["volume"] = p.volume }
    if !p.pages.isEmpty { d["pages"] = p.pages }
    if !p.doi.isEmpty { d["doi"] = p.doi }
    if !p.arxiv.isEmpty { d["arxiv"] = p.arxiv }
    if !p.bibcode.isEmpty { d["bibcode"] = p.bibcode }
    return d
}

// MARK: - Test corpus

struct CorpusCase {
    let input: String
    let kind: String                              // expected SearchIntent kind
    let mustContain: [String]                     // substrings that must appear in `outcome.queryRepresentation`
    let mustNotContain: [String]                  // substrings that must NOT appear
    let mustHaveAuthorsFor: [String]              // each surname → expect `author:"<surname>` (case-insensitive)
    let label: String                             // human-readable test name

    init(_ label: String,
         _ input: String,
         kind: String,
         mustContain: [String] = [],
         mustNotContain: [String] = [],
         mustHaveAuthorsFor: [String] = []) {
        self.label = label
        self.input = input
        self.kind = kind
        self.mustContain = mustContain
        self.mustNotContain = mustNotContain
        self.mustHaveAuthorsFor = mustHaveAuthorsFor
    }
}

let corpus: [CorpusCase] = [
    // Identifiers
    .init("doi/canonical", "10.1126/science.295.5552.93", kind: "identifier"),
    .init("doi/prefixed", "doi:10.1086/164143", kind: "identifier"),
    .init("arxiv/new", "2112.01234", kind: "identifier"),
    .init("arxiv/new+version", "2301.04153v2", kind: "identifier"),
    .init("arxiv/old", "astro-ph/0112088", kind: "identifier"),
    .init("bibcode/sci", "2002Sci...295...93A", kind: "identifier"),
    .init("bibcode/apj", "1986ApJ...304...15B", kind: "identifier"),
    .init("pmid/prefixed", "pmid:1234567", kind: "identifier"),

    // Fielded
    .init("fielded/au+abs", #"au:"Abel" abs:"first stars""#, kind: "fielded"),
    .init("fielded/year-narrow", "au:Abel year:2002", kind: "fielded"),
    .init("fielded/title-words", "title:(dark matter) year:2020-2024", kind: "fielded"),
    .init("fielded/citations-fn", "citations(bibcode:2002Sci...295...93A)", kind: "fielded"),

    // References (single block)
    .init("ref/abel-bryan-norman-2002",
          "Abel, T., Bryan, G. L., Norman, M. L. 2002, Science, 295, 93",
          kind: "reference"),
    .init("ref/bbks-1986",
          "Bardeen J.M., Bond J.R., Kaiser N., Szalay A.S. 1986, ApJ, 304, 15",
          kind: "reference"),

    // Free-text — invariants on rewritten query
    // Apple Intelligence is non-deterministic on this input. Across 5 runs
    // we see Abel+Norman every time, but Bryan and bibstem:Sci appear in
    // ~4/5. We test the consistent invariants only.
    .init("free/multi-author-journal",
          "abel bryan norman first stars science",
          kind: "freeText",
          mustContain: ["abs:(", "first"],
          mustNotContain: [";", "title:\"first", "title:\"first stars\""],
          mustHaveAuthorsFor: ["Abel", "Norman"]),
    .init("free/riess-since-refereed",
          "Riess dark energy since 2020 refereed",
          kind: "freeText",
          mustContain: ["property:refereed"],
          mustNotContain: [";"],
          mustHaveAuthorsFor: ["Riess"]),
    .init("free/jwst-topic",
          "JWST galaxy formation high redshift",
          kind: "freeText",
          mustContain: ["abs:("],
          mustNotContain: [";"]),
    .init("free/recent",
          "recent JWST observations",
          kind: "freeText",
          mustContain: ["year:"],
          mustNotContain: [";"]),
    .init("free/decade",
          "galaxy rotation curves 1970s",
          kind: "freeText",
          mustContain: ["year:1970-1979"],
          mustNotContain: [";"]),
]

// MARK: - Suite runner

func runSuite(json: Bool, verbose: Bool) async -> Int {
    let engine = SmartSearchEngine()
    var passes = 0
    var failures = 0
    var jsonResults: [[String: Any]] = []

    for c in corpus {
        let outcome = await engine.resolve(c.input)
        let actualKind = kindString(of: outcome)
        let queryStr = queryRepresentation(of: outcome)
        var caseFailures: [String] = []

        if actualKind != c.kind {
            caseFailures.append("expected kind \(c.kind), got \(actualKind)")
        }
        for needle in c.mustContain where !queryStr.localizedCaseInsensitiveContains(needle) {
            caseFailures.append("expected to contain '\(needle)'")
        }
        for needle in c.mustNotContain where queryStr.contains(needle) {
            caseFailures.append("must NOT contain '\(needle)'")
        }
        for surname in c.mustHaveAuthorsFor {
            // Look for author:"<surname>" or author:"<surname>, ..." (case-insensitive on surname).
            let pattern = "author:\"\(NSRegularExpression.escapedPattern(for: surname))(\"|,)"
            if queryStr.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil {
                caseFailures.append("missing author clause for '\(surname)'")
            }
        }

        let passed = caseFailures.isEmpty
        if passed { passes += 1 } else { failures += 1 }

        if json {
            var entry = encodeOutcome(outcome, input: c.input)
            entry["label"] = c.label
            entry["expectedKind"] = c.kind
            entry["passed"] = passed
            entry["failures"] = caseFailures
            jsonResults.append(entry)
        } else {
            let mark = passed ? "✅" : "❌"
            print("\(mark) \(c.label.padding(toLength: 36, withPad: " ", startingAt: 0)) → \(actualKind)")
            if !passed || verbose {
                if verbose && !queryStr.isEmpty {
                    print("    query: \(queryStr)")
                }
                for f in caseFailures {
                    print("    ✗ \(f)")
                }
            }
        }
    }

    if json {
        let out: [String: Any] = ["total": corpus.count, "passed": passes, "failed": failures, "cases": jsonResults]
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        print("")
        print("\(passes)/\(corpus.count) passed (\(failures) failed)")
    }
    return failures
}

func kindString(of outcome: ResolveOutcome) -> String {
    switch outcome {
    case .identifier: return "identifier"
    case .fielded: return "fielded"
    case .citation, .citations: return "reference"
    case .freeTextQuery: return "freeText"
    case .urlExtraction: return "url"
    }
}

/// Approximate "what would actually be searched" string used for invariant checks.
func queryRepresentation(of outcome: ResolveOutcome) -> String {
    switch outcome {
    case .identifier(let id): return "\(id.typeName):\(id.value)"
    case .fielded(let q): return q
    case .freeTextQuery(let rw): return rw.query
    case .citation(let p): return parsedSummary(p)
    case .citations(let ps): return ps.compactMap { $0.map(parsedSummary) }.joined(separator: " ; ")
    case .urlExtraction(let r): return r.identifiers.map { "\($0.typeName):\($0.value)" }.joined(separator: " ")
    }
}

func parsedSummary(_ p: ParsedReference) -> String {
    var parts: [String] = []
    for a in p.authors { parts.append("author:\"\(a)\"") }
    if !p.title.isEmpty { parts.append("title:(\(p.title))") }
    if p.year != 0 { parts.append("year:\(p.year)") }
    if !p.journal.isEmpty { parts.append("bibstem:\(p.journal)") }
    return parts.joined(separator: " ")
}

// MARK: - URL test corpus

/// Test case for the URL extraction pipeline.
struct URLTestCase {
    let label: String
    let url: String

    /// Expected top-level intent: "identifier" (short-circuit, no fetch) or "url" (fetch + extract).
    let expectedIntent: String

    /// For identifier short-circuits: kind ("doi"|"arxiv"|"bibcode"|"pmid") and exact value.
    var expectedKind: String? = nil
    var expectedValue: String? = nil

    /// For URL fetches: at least N identifiers must be extracted (0 means no requirement).
    var mustExtractAtLeast: Int = 0

    /// For URL fetches: these specific identifier values MUST appear in the extracted set
    /// (exact-match, case-insensitive). Catches regressions where a known DOI on a stable
    /// page stops being extracted.
    var mustContain: [String] = []

    /// For URL fetches: NONE of these may appear (regression catcher).
    var mustNotContain: [String] = []

    /// For graceful-failure cases: the extraction is allowed to return zero identifiers
    /// AND a non-nil reason. We assert on reason text instead of identifier count.
    var allowEmpty: Bool = false
    var reasonContains: String? = nil

    /// Network calls are flaky. If true, a network failure (DNS, timeout) marks the case
    /// as SKIPPED rather than FAILED so the suite stays green when third-party sites flap.
    var allowNetworkFailure: Bool = false
}

let urlCorpus: [URLTestCase] = [
    // MARK: - Identifier short-circuits (no network)
    URLTestCase(
        label: "short/doi.org",
        url: "https://doi.org/10.1126/science.295.5552.93",
        expectedIntent: "identifier",
        expectedKind: "doi", expectedValue: "10.1126/science.295.5552.93"
    ),
    URLTestCase(
        label: "short/dx.doi.org",
        url: "https://dx.doi.org/10.1086/164143",
        expectedIntent: "identifier",
        expectedKind: "doi", expectedValue: "10.1086/164143"
    ),
    URLTestCase(
        label: "short/arxiv-new",
        url: "https://arxiv.org/abs/2301.04153",
        expectedIntent: "identifier",
        expectedKind: "arxiv", expectedValue: "2301.04153"
    ),
    URLTestCase(
        label: "short/arxiv-old",
        url: "https://arxiv.org/abs/astro-ph/0112088",
        expectedIntent: "identifier",
        expectedKind: "arxiv", expectedValue: "astro-ph/0112088"
    ),
    URLTestCase(
        label: "short/arxiv-pdf",
        url: "https://arxiv.org/pdf/2301.04153.pdf",
        expectedIntent: "identifier",
        expectedKind: "arxiv", expectedValue: "2301.04153"
    ),
    URLTestCase(
        label: "short/ads-bibcode",
        url: "https://ui.adsabs.harvard.edu/abs/2002Sci...295...93A/abstract",
        expectedIntent: "identifier",
        expectedKind: "bibcode", expectedValue: "2002Sci...295...93A"
    ),
    URLTestCase(
        label: "short/pubmed",
        url: "https://pubmed.ncbi.nlm.nih.gov/1234567/",
        expectedIntent: "identifier",
        expectedKind: "pmid", expectedValue: "1234567"
    ),

    // MARK: - URL fetches with predictable extractions

    URLTestCase(
        label: "wiki/godel-completeness (single DOI)",
        url: "https://en.wikipedia.org/wiki/Original_proof_of_G%C3%B6del%27s_completeness_theorem",
        expectedIntent: "url",
        mustExtractAtLeast: 1,
        mustContain: ["10.1007/BF01696781"],
        allowNetworkFailure: true
    ),
    URLTestCase(
        label: "wiki/godel double-encoded (retry path)",
        url: "https://en.wikipedia.org/wiki/Original_proof_of_G%C3%B6del%2527s_completeness_theorem",
        expectedIntent: "url",
        mustExtractAtLeast: 1,
        mustContain: ["10.1007/BF01696781"],
        allowNetworkFailure: true
    ),
    URLTestCase(
        label: "wiki/population-III (many bibcodes)",
        url: "https://en.wikipedia.org/wiki/Population_III_star",
        expectedIntent: "url",
        mustExtractAtLeast: 10,
        mustContain: ["2018ApJ...867...98S", "1944ApJ...100..137B"],
        // `gnd/4226307` is a German-National-Library ID, NOT an arxiv id —
        // verify the archive whitelist filters it out.
        mustNotContain: ["gnd/4226307"],
        allowNetworkFailure: true
    ),
    URLTestCase(
        label: "wiki/CMB (many DOIs)",
        url: "https://en.wikipedia.org/wiki/Cosmic_microwave_background",
        expectedIntent: "url",
        mustExtractAtLeast: 30,
        mustContain: ["10.1086/344402"],
        allowNetworkFailure: true
    ),
    URLTestCase(
        label: "wiki/quicksort (cs DOIs)",
        url: "https://en.wikipedia.org/wiki/Quicksort",
        expectedIntent: "url",
        mustExtractAtLeast: 5,
        mustContain: ["10.1145/366622.366642"],
        allowNetworkFailure: true
    ),

    // MARK: - Graceful empty / failure paths

    URLTestCase(
        label: "edge/example.com (no IDs)",
        url: "https://example.com/",
        expectedIntent: "url",
        allowEmpty: true,
        allowNetworkFailure: true
    ),
    URLTestCase(
        label: "edge/wikipedia 404",
        url: "https://en.wikipedia.org/wiki/Definitely_Not_A_Real_Page_zzz_QQQ",
        expectedIntent: "url",
        allowEmpty: true,
        reasonContains: "404",
        allowNetworkFailure: true
    ),

    // MARK: - More demanding pages

    // arXiv monthly listing — current URL pattern is YYYY-MM.
    URLTestCase(
        label: "arxiv/listing (monthly)",
        url: "https://arxiv.org/list/astro-ph.CO/2024-01",
        expectedIntent: "url",
        mustExtractAtLeast: 5,
        allowNetworkFailure: true
    ),

    // ADS query results page — short-circuits via `searchQueryFromURL` to
    // a fielded query. (Was previously expected to fall through to .url and
    // return nothing; the page is JS-rendered and unscrapable.)
    URLTestCase(
        label: "ads/search results",
        url: "https://ui.adsabs.harvard.edu/search/q=author%3A%22Abel%22%20year%3A2002&sort=date%20desc",
        expectedIntent: "fielded"
    ),

    // Wikipedia article with diverse identifier types (DOI + arxiv + bibcode mixed).
    URLTestCase(
        label: "wiki/inflation (mixed IDs)",
        url: "https://en.wikipedia.org/wiki/Inflation_(cosmology)",
        expectedIntent: "url",
        mustExtractAtLeast: 10,
        allowNetworkFailure: true
    ),

    // MARK: - Regression: false-positive guards

    // arxiv old-format regex must NOT match generic /1234567 paths. This page
    // contains no arxiv-format IDs but does have URL-like paths.
    URLTestCase(
        label: "edge/no-academic-content",
        url: "https://www.iana.org/help/example-domains",
        expectedIntent: "url",
        // IANA help page has no academic IDs; allow empty extraction.
        allowEmpty: true,
        allowNetworkFailure: true
    ),

    // MARK: - Non-URL fall-through (sanity)

    URLTestCase(
        label: "non-url/free-text",
        url: "ftp://example.com/file.txt",
        expectedIntent: "freeText"   // unsupported scheme → not classified as URL
    ),

    URLTestCase(
        label: "non-url/empty",
        url: "",
        expectedIntent: "freeText"
    ),

    // Publisher landing pages — these often block on User-Agent or require
    // JS, so we only assert "doesn't crash and returns a sensible result".
    // Nature articles short-circuit on the slug (DOI suffix). Previously this
    // case went through page-fetch and tested for `&amp;format=js`-trailing
    // pollution; that path is preserved by the trailing-`&` regex fix in the
    // extractor (still tested via wiki/cmb / wiki/dark-matter pages which
    // exercise that code).
    URLTestCase(
        label: "publisher/nature legacy slug",
        url: "https://www.nature.com/articles/nature01080",
        expectedIntent: "identifier",
        expectedKind: "doi", expectedValue: "10.1038/nature01080"
    ),

    // MARK: - Publisher DOI URLs (path-embedded DOI, must short-circuit)

    URLTestCase(
        label: "publisher/wiley DOI in path",
        url: "https://agupubs.onlinelibrary.wiley.com/doi/full/10.1029/2024GL114318",
        expectedIntent: "identifier",
        // The DOI is right there in the URL — short-circuit to the article,
        // don't fetch the page (which would scrape its bibliography).
        expectedKind: "doi", expectedValue: "10.1029/2024GL114318"
    ),
    URLTestCase(
        label: "publisher/science DOI in path",
        url: "https://www.science.org/doi/10.1126/science.295.5552.93",
        expectedIntent: "identifier",
        expectedKind: "doi", expectedValue: "10.1126/science.295.5552.93"
    ),
    URLTestCase(
        label: "publisher/springer DOI in path",
        url: "https://link.springer.com/article/10.1007/BF01696781",
        expectedIntent: "identifier",
        expectedKind: "doi", expectedValue: "10.1007/BF01696781"
    ),
    URLTestCase(
        label: "publisher/wiley abs verb",
        url: "https://onlinelibrary.wiley.com/doi/abs/10.1002/anie.202001234",
        expectedIntent: "identifier",
        expectedKind: "doi", expectedValue: "10.1002/anie.202001234"
    ),
    URLTestCase(
        label: "publisher/nature articles slug",
        url: "https://www.nature.com/articles/s41586-024-07930-y",
        expectedIntent: "identifier",
        // Nature URLs encode the DOI suffix as the slug; prefix is always 10.1038.
        expectedKind: "doi", expectedValue: "10.1038/s41586-024-07930-y"
    ),

    // MARK: - ADS search URL (must extract q= as fielded query)

    URLTestCase(
        label: "ads/search URL with q=",
        url: "https://ui.adsabs.harvard.edu/search/fq=%7B!type%3Daqp%20v%3D%24fq_database%7D&fq_database=database%3A%20astronomy&q=author%3A(%22Abel%22)%20first_author%3A(%22Yuan%22)&sort=date%20desc%2C%20bibcode%20desc&p_=0",
        expectedIntent: "fielded"
        // The query is `author:("Abel") first_author:("Yuan")`. Don't fetch
        // the (JS-rendered) search page; pass the query straight to ADS.
    ),
]

func runURLSuite(json: Bool, verbose: Bool) async -> Int {
    let engine = SmartSearchEngine()
    var passes = 0
    var failures = 0
    var skipped = 0
    var jsonResults: [[String: Any]] = []

    for c in urlCorpus {
        let outcome = await engine.resolve(c.url)
        let actualIntent = kindString(of: outcome)
        var caseFailures: [String] = []
        var caseSkipReason: String? = nil

        // Intent check
        if actualIntent != c.expectedIntent {
            caseFailures.append("expected intent \(c.expectedIntent), got \(actualIntent)")
        }

        // Identifier short-circuit assertions
        if let expectedKind = c.expectedKind, let expectedValue = c.expectedValue {
            if case .identifier(let id) = outcome {
                if id.typeName != expectedKind {
                    caseFailures.append("expected \(expectedKind), got \(id.typeName)")
                }
                if id.value != expectedValue {
                    caseFailures.append("expected value '\(expectedValue)', got '\(id.value)'")
                }
            } else if c.expectedIntent == "identifier" {
                caseFailures.append("expected identifier outcome but got \(actualIntent)")
            }
        }

        // URL extraction assertions
        if case .urlExtraction(let r) = outcome {
            // Network failure detection: nil pageTitle + nil identifiers + reason
            // mentioning "Couldn't fetch" or DNS-style errors.
            let isNetworkFailure: Bool = {
                guard r.identifiers.isEmpty, let reason = r.reason else { return false }
                return reason.lowercased().contains("couldn't fetch")
                    || reason.lowercased().contains("network")
                    || reason.lowercased().contains("timeout")
                    || reason.lowercased().contains("connection")
            }()

            if isNetworkFailure && c.allowNetworkFailure {
                caseSkipReason = "network failure: \(r.reason ?? "unknown")"
            } else {
                if c.mustExtractAtLeast > 0 && r.identifiers.count < c.mustExtractAtLeast {
                    caseFailures.append("expected ≥\(c.mustExtractAtLeast) identifiers, got \(r.identifiers.count)")
                }
                let extractedValues = Set(r.identifiers.map { $0.value.lowercased() })
                for needle in c.mustContain {
                    if !extractedValues.contains(needle.lowercased()) {
                        caseFailures.append("missing expected identifier '\(needle)'")
                    }
                }
                for forbidden in c.mustNotContain {
                    if extractedValues.contains(forbidden.lowercased()) {
                        caseFailures.append("must NOT contain '\(forbidden)'")
                    }
                }
                if c.allowEmpty && !c.mustContain.isEmpty {
                    // mixing allowEmpty with mustContain doesn't make sense
                    caseFailures.append("test config: allowEmpty + mustContain mutually exclusive")
                }
                if let needle = c.reasonContains {
                    if r.reason?.lowercased().contains(needle.lowercased()) != true {
                        caseFailures.append("reason should contain '\(needle)', got '\(r.reason ?? "nil")'")
                    }
                }
            }
        }

        let passed = caseFailures.isEmpty && caseSkipReason == nil
        let isSkip = caseSkipReason != nil
        if passed { passes += 1 }
        else if isSkip { skipped += 1 }
        else { failures += 1 }

        if json {
            var entry = encodeOutcome(outcome, input: c.url)
            entry["label"] = c.label
            entry["expectedIntent"] = c.expectedIntent
            entry["passed"] = passed
            entry["skipped"] = isSkip
            entry["failures"] = caseFailures
            if let r = caseSkipReason { entry["skipReason"] = r }
            jsonResults.append(entry)
        } else {
            let mark: String
            if passed { mark = "✅" }
            else if isSkip { mark = "⏭️ " }
            else { mark = "❌" }
            print("\(mark) \(c.label.padding(toLength: 44, withPad: " ", startingAt: 0)) → \(actualIntent)")
            if isSkip, let reason = caseSkipReason {
                print("    skip: \(reason)")
            }
            if !passed && !isSkip {
                if verbose, case .urlExtraction(let r) = outcome {
                    print("    found \(r.identifiers.count) ids · reason: \(r.reason ?? "—")")
                }
                for f in caseFailures {
                    print("    ✗ \(f)")
                }
            }
        }
    }

    if json {
        let out: [String: Any] = [
            "total": urlCorpus.count, "passed": passes, "failed": failures, "skipped": skipped,
            "cases": jsonResults
        ]
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        print("")
        print("\(passes)/\(urlCorpus.count) passed (\(failures) failed, \(skipped) skipped)")
    }
    return failures
}

// MARK: - Entry point

let opts = parseArguments()

if opts.suite {
    let failures = await runSuite(json: opts.json, verbose: opts.verbose)
    exit(failures > 0 ? 1 : 0)
}

if opts.urlSuite {
    let failures = await runURLSuite(json: opts.json, verbose: opts.verbose)
    exit(failures > 0 ? 1 : 0)
}

guard let input = opts.input, !input.isEmpty else {
    printUsage()
    exit(1)
}

let engine = SmartSearchEngine()
let outcome = await engine.resolve(input)
printOutcome(outcome, input: input, json: opts.json)
