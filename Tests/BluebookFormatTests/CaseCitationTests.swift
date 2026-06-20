import XCTest
@testable import BluebookFormat

final class CaseCitationTests: XCTestCase {

    // MARK: fixtures

    private func obergefell(pincite: String? = nil) -> CaseRecord {
        CaseRecord(
            name: "Obergefell v. Hodges",
            citations: [ReporterCitation(volume: "576", reporter: "U.S.", page: "644", kind: .official)],
            courtID: "scotus",
            year: 2015
        )
    }

    // MARK: SCOTUS official reporter, law-review default (roman name)

    func testScotusLawReviewPlain() throws {
        let rt = try CaseCitation.format(obergefell())
        XCTAssertEqual(rt.plainText, "Obergefell v. Hodges, 576 U.S. 644 (2015).")
    }

    func testScotusLawReviewNameIsRoman() throws {
        let rt = try CaseCitation.format(obergefell())
        // Law-review full cite: no italics at all (no \i groups).
        XCTAssertFalse(rt.rtfBody.contains("\\i{}"), "law-review full name must be roman")
    }

    func testPincite() throws {
        let opts = CaseCitation.Options(style: .lawReview, pincite: "681")
        let rt = try CaseCitation.format(obergefell(), options: opts)
        XCTAssertEqual(rt.plainText, "Obergefell v. Hodges, 576 U.S. 644, 681 (2015).")
    }

    // MARK: explanatory parenthetical

    func testParenthetical() throws {
        let opts = CaseCitation.Options(style: .lawReview, pincite: "681", parenthetical: "en banc")
        let rt = try CaseCitation.format(obergefell(), options: opts)
        XCTAssertEqual(rt.plainText, "Obergefell v. Hodges, 576 U.S. 644, 681 (2015) (en banc).")
    }

    func testParentheticalBlankIgnored() throws {
        let opts = CaseCitation.Options(parenthetical: "   ")
        let rt = try CaseCitation.format(obergefell(), options: opts)
        XCTAssertEqual(rt.plainText, "Obergefell v. Hodges, 576 U.S. 644 (2015).")
    }

    // MARK: string citation (multi-cite)

    func testStringCitationJoinsWithSemicolons() throws {
        let a = try CaseCitation.format(obergefell())
        let b = try CaseCitation.format(obergefell(), options: .init(pincite: "681"))
        let joined = CaseCitation.stringCitation([a, b])
        XCTAssertEqual(joined.plainText,
            "Obergefell v. Hodges, 576 U.S. 644 (2015); Obergefell v. Hodges, 576 U.S. 644, 681 (2015).")
    }

    func testStringCitationCapitalizedSignalStartsNewSentence() throws {
        // Cite 1 ("See …") and cite 2 carrying a capitalized "But see" — the second
        // begins a new citation sentence, so cite 1 ends with a period, not "; ".
        let a = try CaseCitation.format(obergefell(), options: .init(signal: Signal("see").capitalized))
        let b = try CaseCitation.format(obergefell(), options: .init(signal: Signal("but see").capitalized, pincite: "681"))
        let joined = CaseCitation.stringCitation([
            CaseCitation.Member(a),
            CaseCitation.Member(b, beginsNewSentence: true),
        ])
        XCTAssertEqual(joined.plainText,
            "See Obergefell v. Hodges, 576 U.S. 644 (2015). But see Obergefell v. Hodges, 576 U.S. 644, 681 (2015).")
    }

    func testStringCitationLowercaseContinuationUsesSemicolon() throws {
        // A lowercase signal on cite 2 keeps it in the same sentence: "; " separator.
        let a = try CaseCitation.format(obergefell(), options: .init(signal: Signal("see").capitalized))
        let b = try CaseCitation.format(obergefell(), options: .init(signal: Signal("see also"), pincite: "681"))
        let joined = CaseCitation.stringCitation([
            CaseCitation.Member(a),
            CaseCitation.Member(b, beginsNewSentence: false),
        ])
        XCTAssertEqual(joined.plainText,
            "See Obergefell v. Hodges, 576 U.S. 644 (2015); see also Obergefell v. Hodges, 576 U.S. 644, 681 (2015).")
    }

    func testStringCitationSingleEqualsPlainCite() throws {
        let a = try CaseCitation.format(obergefell())
        XCTAssertEqual(CaseCitation.stringCitation([a]).plainText, a.plainText)
    }

    func testStringCitationEmptyIsEmpty() {
        XCTAssertEqual(CaseCitation.stringCitation([] as [RichText]).plainText, "")
    }

    // MARK: court-document mode italicizes the full name

    func testCourtDocumentNameIsItalic() throws {
        let opts = CaseCitation.Options(style: .courtDocument, pincite: "681")
        let rt = try CaseCitation.format(obergefell(), options: opts)
        XCTAssertEqual(rt.plainText, "Obergefell v. Hodges, 576 U.S. 644, 681 (2015).")
        XCTAssertTrue(rt.rtfBody.contains("{\\i{}Obergefell v. Hodges}"),
                      "court-document full name must be italic; got \(rt.rtfBody)")
    }

    // MARK: circuit court parenthetical (T7)

    func testCircuitParenthetical() throws {
        let rec = CaseRecord(
            name: "Doe v. Roe",
            citations: [ReporterCitation(volume: "123", reporter: "F.3d", page: "456", kind: .regional)],
            courtID: "ca9",
            year: 2018
        )
        let rt = try CaseCitation.format(rec)
        XCTAssertEqual(rt.plainText, "Doe v. Roe, 123 F.3d 456 (9th Cir. 2018).")
    }

    // MARK: T6 word abbreviation, with "United States" left intact

    func testT6Abbreviation() throws {
        let rec = CaseRecord(
            name: "Standard Oil Company v. United States",
            citations: [ReporterCitation(volume: "221", reporter: "U.S.", page: "1", kind: .official)],
            courtID: "scotus",
            year: 1911
        )
        let rt = try CaseCitation.format(rec)
        XCTAssertEqual(rt.plainText, "Standard Oil Co. v. United States, 221 U.S. 1 (1911).")
    }

    func testT6MultiWordAbbreviation() throws {
        // Association -> Ass'n (curly apostrophe), National -> Nat'l.
        let abbreviated = CaseName.abbreviate("National Education Association")
        XCTAssertEqual(abbreviated, "Nat\u{2019}l Educ. Ass\u{2019}n")
    }

    // MARK: procedural phrase stays italic in BOTH modes

    func testProceduralPhraseLawReview() throws {
        let rec = CaseRecord(
            name: "In re Marriage Cases",
            citations: [ReporterCitation(volume: "183", reporter: "P.3d", page: "384", kind: .regional)],
            courtID: nil,
            year: 2008
        )
        let rt = try CaseCitation.format(rec)
        XCTAssertEqual(rt.plainText, "In re Marriage Cases, 183 P.3d 384 (2008).")
        // "In re " italic even in law-review mode; the rest roman.
        XCTAssertTrue(rt.rtfBody.contains("{\\i{}In re }"), "got \(rt.rtfBody)")
        XCTAssertTrue(rt.rtfBody.contains("Marriage Cases,"), "rest must be roman; got \(rt.rtfBody)")
    }

    func testExRelInlineItalic() throws {
        let rt = CaseName.render("Arizona ex rel. Horne v. United States", style: .lawReview)
        XCTAssertTrue(rt.rtfBody.contains("{\\i{} ex rel. }"), "got \(rt.rtfBody)")
        XCTAssertEqual(rt.plainText, "Arizona ex rel. Horne v. United States")
    }

    // MARK: signal prepend (always italic)

    func testSignalPrepend() throws {
        let opts = CaseCitation.Options(style: .lawReview,
                                        signal: Signal("see").capitalized,
                                        pincite: "681")
        let rt = try CaseCitation.format(obergefell(), options: opts)
        XCTAssertEqual(rt.plainText, "See Obergefell v. Hodges, 576 U.S. 644, 681 (2015).")
        XCTAssertTrue(rt.rtfBody.hasPrefix("{\\i{}See} "), "signal must lead, italic; got \(rt.rtfBody)")
    }

    // MARK: reporter selection prefers official over parallel cites

    func testPrefersOfficialReporter() throws {
        let rec = CaseRecord(
            name: "Brown v. Board of Education",
            citations: [
                ReporterCitation(volume: "74", reporter: "S. Ct.", page: "686", kind: .regional),
                ReporterCitation(volume: "347", reporter: "U.S.", page: "483", kind: .official),
            ],
            courtID: "scotus",
            year: 1954
        )
        let rt = try CaseCitation.format(rec)
        // "Education" abbreviates to "Educ." (T6); the point of this test is that
        // the official U.S. reporter is selected over the parallel S. Ct. cite.
        XCTAssertEqual(rt.plainText, "Brown v. Board of Educ., 347 U.S. 483 (1954).")
    }

    // MARK: degradation — no reporter / no year throw

    func testNoReporterThrows() {
        let rec = CaseRecord(name: "Unpublished v. Case", citations: [], courtID: "ca2", year: 2020)
        XCTAssertThrowsError(try CaseCitation.format(rec)) { error in
            XCTAssertEqual(error as? CaseCitation.FormatError, .noReporter)
        }
    }

    func testNoYearThrows() {
        let rec = CaseRecord(
            name: "Doe v. Roe",
            citations: [ReporterCitation(volume: "1", reporter: "U.S.", page: "1", kind: .official)],
            courtID: "scotus",
            year: nil
        )
        XCTAssertThrowsError(try CaseCitation.format(rec)) { error in
            XCTAssertEqual(error as? CaseCitation.FormatError, .noYear)
        }
    }

    // MARK: short-title derivation (Rule 10.9 / B10.2)

    func testShortTitleFirstParty() {
        XCTAssertEqual(CaseName.shortTitle("Obergefell v. Hodges"), "Obergefell")
    }

    func testShortTitleSkipsUnitedStates() {
        XCTAssertEqual(CaseName.shortTitle("United States v. Nixon"), "Nixon")
    }

    func testShortTitleSkipsGenericGovParty() {
        // "City of …" / "People" / "State of …" are generic — use the other party.
        XCTAssertEqual(CaseName.shortTitle("City of Boerne v. Flores"), "Flores")
        XCTAssertEqual(CaseName.shortTitle("People v. Anderson"), "Anderson")
    }

    func testShortTitleKeepsNamedState() {
        // A named state opposite another governmental party stays as the short title.
        XCTAssertEqual(CaseName.shortTitle("Arizona v. United States"), "Arizona")
        XCTAssertEqual(CaseName.shortTitle("California v. Texas"), "California")
        // ...including a federal agency acronym (a governmental opponent, not a person).
        XCTAssertEqual(CaseName.shortTitle("Massachusetts v. EPA"), "Massachusetts")
    }

    func testShortTitleStateVersusIndividual() {
        // A state prosecuting/suing an individual shortens to the individual, not the
        // state (Rule 10.9): the distinctive party is the defendant's surname.
        XCTAssertEqual(CaseName.shortTitle("Tennessee v. Garner"), "Garner")
        XCTAssertEqual(CaseName.shortTitle("Michigan v. Long"), "Long")
        XCTAssertEqual(CaseName.shortTitle("New York v. Ferber"), "Ferber")
    }

    func testShortTitleOrgKeepsAbbreviatedName() {
        // Org party (chosen because the other is "United States") keeps its abbreviated
        // name rather than collapsing to one word; "Company" → "Co." (T6).
        XCTAssertEqual(CaseName.shortTitle("United States v. Standard Oil Company"), "Standard Oil Co.")
    }

    func testShortTitlePersonalSurname() {
        XCTAssertEqual(CaseName.shortTitle("Mary Beth Tinker v. Des Moines"), "Tinker")
    }

    func testShortTitleInReSubject() {
        XCTAssertEqual(CaseName.shortTitle("In re Gault"), "Gault")
    }

    // MARK: short-form citation

    func testShortFormPlain() throws {
        let opts = CaseCitation.Options(style: .lawReview, pincite: "681", form: .short)
        let rt = try CaseCitation.format(obergefell(), options: opts)
        XCTAssertEqual(rt.plainText, "Obergefell, 576 U.S. at 681.")
    }

    func testShortFormTitleItalicInLawReview() throws {
        // Short titles are italic even in law-review style (where full names are roman).
        let opts = CaseCitation.Options(style: .lawReview, pincite: "681", form: .short)
        let rt = try CaseCitation.format(obergefell(), options: opts)
        XCTAssertTrue(rt.rtfBody.contains("{\\i{}Obergefell}"), "got \(rt.rtfBody)")
    }

    func testShortFormNoPinciteDropsAt() throws {
        let opts = CaseCitation.Options(form: .short)
        let rt = try CaseCitation.format(obergefell(), options: opts)
        XCTAssertEqual(rt.plainText, "Obergefell, 576 U.S.")
    }

    func testShortFormOverrideTitle() throws {
        let opts = CaseCitation.Options(pincite: "851", form: .short, shortTitle: "Casey")
        let rec = CaseRecord(
            name: "Planned Parenthood of Southeastern Pa. v. Casey",
            citations: [ReporterCitation(volume: "505", reporter: "U.S.", page: "833", kind: .official)],
            courtID: "scotus", year: 1992)
        let rt = try CaseCitation.format(rec, options: opts)
        XCTAssertEqual(rt.plainText, "Casey, 505 U.S. at 851.")
    }

    func testShortFormSignalPrefix() throws {
        let opts = CaseCitation.Options(signal: Signal("see").capitalized, pincite: "681", form: .short)
        let rt = try CaseCitation.format(obergefell(), options: opts)
        XCTAssertEqual(rt.plainText, "See Obergefell, 576 U.S. at 681.")
        XCTAssertTrue(rt.rtfBody.hasPrefix("{\\i{}See} "), "got \(rt.rtfBody)")
    }

    func testShortFormNeedsNoYear() throws {
        // Unlike the full cite, short form doesn't require a year.
        let rec = CaseRecord(
            name: "Doe v. Roe",
            citations: [ReporterCitation(volume: "1", reporter: "U.S.", page: "1", kind: .official)],
            courtID: "scotus", year: nil)
        let rt = try CaseCitation.format(rec, options: .init(pincite: "5", form: .short))
        XCTAssertEqual(rt.plainText, "Doe, 1 U.S. at 5.")
    }

    func testShortFormInStringCitation() throws {
        let a = try CaseCitation.format(obergefell())
        let b = try CaseCitation.format(obergefell(), options: .init(pincite: "681", form: .short))
        let joined = CaseCitation.stringCitation([a, b])
        XCTAssertEqual(joined.plainText,
            "Obergefell v. Hodges, 576 U.S. 644 (2015); Obergefell, 576 U.S. at 681.")
    }

    // MARK: RTF escaping of non-ASCII (curly apostrophe -> \uN{})

    func testRTFEscapesCurlyApostrophe() throws {
        let rec = CaseRecord(
            name: "National Association v. Smith",
            citations: [ReporterCitation(volume: "1", reporter: "U.S.", page: "1", kind: .official)],
            courtID: "scotus",
            year: 2000
        )
        let rt = try CaseCitation.format(rec)
        // U+2019 (8217) must be escaped, not emitted raw.
        XCTAssertTrue(rt.rtfBody.contains("\\u8217{}"), "got \(rt.rtfBody)")
        XCTAssertFalse(rt.rtfBody.unicodeScalars.contains { $0.value == 0x2019 })
    }
}
