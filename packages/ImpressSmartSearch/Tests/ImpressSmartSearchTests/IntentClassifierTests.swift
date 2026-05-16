//
//  IntentClassifierTests.swift
//  ImpressSmartSearchTests
//
//  Deterministic tests for the regex-driven intent classifier. No network,
//  no LLM — runs on every machine.
//

import XCTest
@testable import ImpressSmartSearch

final class IntentClassifierTests: XCTestCase {

    // MARK: - Empty input

    func testClassify_empty() {
        if case .freeText(let q) = IntentClassifier.classify("") {
            XCTAssertEqual(q, "")
        } else { XCTFail("empty → freeText") }
    }

    func testClassify_whitespace() {
        if case .freeText(let q) = IntentClassifier.classify("   \n  ") {
            XCTAssertEqual(q, "")
        } else { XCTFail("whitespace → freeText") }
    }

    // MARK: - Identifiers

    func testClassify_doi() {
        if case .identifier(.doi(let v)) = IntentClassifier.classify("10.1126/science.295.5552.93") {
            XCTAssertEqual(v, "10.1126/science.295.5552.93")
        } else { XCTFail("DOI not detected") }
    }

    func testClassify_doiWithPrefix() {
        if case .identifier(.doi(let v)) = IntentClassifier.classify("doi:10.1086/164143") {
            XCTAssertEqual(v, "10.1086/164143")
        } else { XCTFail("DOI with prefix not detected") }
    }

    func testClassify_arxivNew() {
        if case .identifier(.arxiv(let v)) = IntentClassifier.classify("2112.01234") {
            XCTAssertEqual(v, "2112.01234")
        } else { XCTFail("arXiv new not detected") }
    }

    func testClassify_arxivNewWithVersion() {
        if case .identifier(.arxiv(let v)) = IntentClassifier.classify("2301.04153v2") {
            XCTAssertEqual(v, "2301.04153v2")
        } else { XCTFail("arXiv new + version not detected") }
    }

    func testClassify_arxivOld() {
        if case .identifier(.arxiv(let v)) = IntentClassifier.classify("astro-ph/0112088") {
            XCTAssertEqual(v, "astro-ph/0112088")
        } else { XCTFail("arXiv old not detected") }
    }

    func testClassify_bibcode2002() {
        if case .identifier(.bibcode(let v)) = IntentClassifier.classify("2002Sci...295...93A") {
            XCTAssertEqual(v, "2002Sci...295...93A")
        } else { XCTFail("Bibcode not detected") }
    }

    func testClassify_bibcode1986() {
        if case .identifier(.bibcode(let v)) = IntentClassifier.classify("1986ApJ...304...15B") {
            XCTAssertEqual(v, "1986ApJ...304...15B")
        } else { XCTFail("Bibcode 1986 not detected") }
    }

    func testClassify_pmidWithPrefix() {
        if case .identifier(.pmid(let v)) = IntentClassifier.classify("pmid:1234567") {
            XCTAssertEqual(v, "1234567")
        } else { XCTFail("PMID not detected") }
    }

    func testClassify_barePMID_isAmbiguous() {
        if case .identifier = IntentClassifier.classify("1234567") {
            XCTFail("bare 7-digit number must not classify as identifier")
        }
    }

    func testClassify_doiInProse_isNotIdentifier() {
        if case .identifier = IntentClassifier.classify("see the discussion in 10.1086/164143") {
            XCTFail("DOI inside prose must not classify as bare identifier")
        }
    }

    // MARK: - Arxiv URL short-circuit (regression: `arxiv.org/html/...`)
    //
    // When the URL itself encodes a single paper, classification must skip
    // the `.url` path-fetch — otherwise the HTML extractor scrapes every
    // arXiv id on the page (the paper's reference list) and floods the
    // batch picker with unrelated candidates.

    func testClassify_arxivAbsURL() {
        if case .identifier(.arxiv(let v)) = IntentClassifier.classify("https://arxiv.org/abs/2605.08436v1") {
            XCTAssertEqual(v, "2605.08436v1")
        } else { XCTFail("arxiv.org/abs URL must short-circuit to .identifier") }
    }

    func testClassify_arxivPdfURL() {
        if case .identifier(.arxiv(let v)) = IntentClassifier.classify("https://arxiv.org/pdf/2605.08436v1.pdf") {
            XCTAssertEqual(v, "2605.08436v1")
        } else { XCTFail("arxiv.org/pdf URL must short-circuit to .identifier") }
    }

    func testClassify_arxivHtmlURL() {
        if case .identifier(.arxiv(let v)) = IntentClassifier.classify("https://arxiv.org/html/2605.08436v1") {
            XCTAssertEqual(v, "2605.08436v1")
        } else { XCTFail("arxiv.org/html URL must short-circuit to .identifier") }
    }

    func testClassify_arxivHtmlURLWithExtension() {
        if case .identifier(.arxiv(let v)) = IntentClassifier.classify("https://arxiv.org/html/2605.08436v1.html") {
            XCTAssertEqual(v, "2605.08436v1")
        } else { XCTFail("arxiv.org/html with .html extension must short-circuit to .identifier") }
    }

    func testClassify_arxivOldFormatURL() {
        if case .identifier(.arxiv(let v)) = IntentClassifier.classify("https://arxiv.org/abs/astro-ph/0112088") {
            XCTAssertEqual(v, "astro-ph/0112088")
        } else { XCTFail("arxiv old-format URL must short-circuit to .identifier") }
    }

    // MARK: - Fielded

    func testClassify_authorAbsFielded() {
        if case .fielded(let q) = IntentClassifier.classify(#"au:"Abel" abs:"first stars""#) {
            XCTAssertTrue(q.contains("au:"))
            XCTAssertTrue(q.contains("abs:"))
        } else { XCTFail("au:abs: not classified as fielded") }
    }

    func testClassify_mixedFielded() {
        if case .fielded = IntentClassifier.classify("au:Abel first stars") {
        } else { XCTFail("mixed fielded not detected") }
    }

    func testClassify_fieldedBeatsReference() {
        if case .fielded = IntentClassifier.classify("au:Abel year:2002") {
        } else { XCTFail("fielded must win over reference heuristic") }
    }

    func testClassify_functionalOperator() {
        if case .fielded = IntentClassifier.classify("citations(bibcode:2002Sci...295...93A)") {
        } else { XCTFail("citations(...) not detected as fielded") }
    }

    func testClassify_titleParenthesised() {
        if case .fielded = IntentClassifier.classify("title:(dark matter) year:2020-2024") {
        } else { XCTFail("title:(...) not detected") }
    }

    // MARK: - References

    func testClassify_singleReference_AbelBryanNorman() {
        let input = "Abel, T., Bryan, G. L., Norman, M. L. 2002, Science, 295, 93"
        if case .reference(let blocks) = IntentClassifier.classify(input) {
            XCTAssertEqual(blocks.count, 1)
        } else { XCTFail("Abel/Bryan/Norman 2002 not detected as reference") }
    }

    func testClassify_singleReference_BBKS() {
        let input = "Bardeen J.M., Bond J.R., Kaiser N., Szalay A.S. 1986, ApJ, 304, 15"
        if case .reference(let blocks) = IntentClassifier.classify(input) {
            XCTAssertEqual(blocks.count, 1)
        } else { XCTFail("BBKS reference not detected") }
    }

    func testClassify_multiBlock_blank() {
        let input = """
        Abel, T., Bryan, G. L., Norman, M. L. 2002, Science, 295, 93

        Bardeen, J.M., et al. 1986, ApJ, 304, 15

        Riess, A. G. et al. 1998, AJ, 116, 1009
        """
        if case .reference(let blocks) = IntentClassifier.classify(input) {
            XCTAssertEqual(blocks.count, 3)
        } else { XCTFail("3-block bibliography not detected") }
    }

    func testClassify_multiBlock_bibitem() {
        let input = """
        \\bibitem{abel2002} Abel, T. et al. 2002, Science, 295, 93
        \\bibitem{bbks1986} Bardeen, J. M. et al. 1986, ApJ, 304, 15
        \\bibitem{riess1998} Riess, A. G. et al. 1998, AJ, 116, 1009
        """
        if case .reference(let blocks) = IntentClassifier.classify(input) {
            XCTAssertEqual(blocks.count, 3, "got \(blocks)")
        } else { XCTFail("\\bibitem blocks not detected") }
    }

    func testClassify_multiBlock_numbered() {
        let input = """
        [1] Abel, T. et al. 2002, Science, 295, 93
        [2] Bardeen, J. M. et al. 1986, ApJ, 304, 15
        [3] Riess, A. G. et al. 1998, AJ, 116, 1009
        """
        if case .reference(let blocks) = IntentClassifier.classify(input) {
            XCTAssertEqual(blocks.count, 3)
        } else { XCTFail("numbered blocks not detected") }
    }

    func testClassify_apaSingleLine() {
        let input = "Riess, A. G., & Filippenko, A. V. (1998). Observational evidence. AJ, 116, 1009."
        if case .reference = IntentClassifier.classify(input) {
        } else { XCTFail("APA single-line not detected as reference") }
    }

    // MARK: - Free text

    func testClassify_bareTitleFragment() {
        if case .freeText = IntentClassifier.classify("Abel first stars science") {
        } else { XCTFail("bare title fragment must classify as freeText") }
    }

    func testClassify_naturalLanguage() {
        if case .freeText = IntentClassifier.classify("dark energy by Riess since 2020 refereed") {
        } else { XCTFail("natural language must classify as freeText") }
    }

    func testClassify_singleWord() {
        if case .freeText = IntentClassifier.classify("inflation") {
        } else { XCTFail("single word must classify as freeText") }
    }

    func testClassify_yearAlone() {
        if case .freeText = IntentClassifier.classify("2020") {
        } else { XCTFail("bare year must classify as freeText") }
    }

    func testClassify_volPagesOnly() {
        if case .freeText = IntentClassifier.classify("295, 93") {
        } else { XCTFail("ambiguous vol+page must classify as freeText") }
    }
}
