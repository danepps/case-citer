import XCTest
@testable import BluebookFormat

final class CaseNameTests: XCTestCase {

    // MARK: first-party reduction (Rule 10.2.1(a))

    func testSinglePartyEachSideIsUnchanged() {
        XCTAssertEqual(CaseName.firstPartyEachSide("Obergefell v. Hodges"),
                       "Obergefell v. Hodges")
    }

    func testMultiPartySideReducesToFirstParty() {
        let caption = "Donald O'Connor, and Benjamin M. Aban, Donald N. Adaniya v. United States"
        XCTAssertEqual(CaseName.firstPartyEachSide(caption),
                       "Donald O'Connor v. United States")
    }

    func testBothSidesReduced() {
        XCTAssertEqual(CaseName.firstPartyEachSide("Smith, Jones, Lee v. Acme, Inc., Beta Corp."),
                       "Smith v. Acme, Inc.")
    }

    func testEtAlIsDropped() {
        XCTAssertEqual(CaseName.firstPartyEachSide("Smith, et al. v. Jones"),
                       "Smith v. Jones")
    }

    // MARK: chained "v." segments (consolidated cases / cross-appeals)

    func testChainedVKeepsOnlyFirstTwoSides() {
        XCTAssertEqual(
            CaseName.firstPartyEachSide("Albert Harris v. Dan D. Stephens v. Dan D. Stephens"),
            "Albert Harris v. Dan D. Stephens")
    }

    func testLongCrossAppealChainReducedToTwoSides() {
        let caption = "Donald O'connor v. Clayter v. Jones v. Rodriguez v. Taylor v. United States"
        XCTAssertEqual(CaseName.firstPartyEachSide(caption),
                       "Donald O'connor v. Clayter")
    }

    // MARK: trailing designations stay attached to the first party

    func testPersonalSuffixIsKept() {
        XCTAssertEqual(CaseName.firstPartyEachSide("John D. Cota, Jr. v. United States"),
                       "John D. Cota, Jr. v. United States")
    }

    func testCorporateSuffixIsKept() {
        XCTAssertEqual(CaseName.firstPartyEachSide("Acme, Inc. v. Beta"),
                       "Acme, Inc. v. Beta")
    }

    func testSuffixKeptThenListDropped() {
        XCTAssertEqual(CaseName.firstPartyEachSide("Acme, Inc., Beta Co. v. Smith"),
                       "Acme, Inc. v. Smith")
    }

    // MARK: consolidated cross-appeals glued on with a period

    func testConsolidatedReListingTruncatedAtPeriod() {
        let caption = "Hester Lee Searles, Individually, in No. 92-1573 v. Southeastern Pennsylvania Transportation Authority. Hester Lee Searles, in No. 92-1574 v. J. Clayton Undercofler"
        XCTAssertEqual(CaseName.bluebookCaseName(caption),
                       "Searles v. Southeastern Pennsylvania Transportation Authority")
    }

    func testBoundaryIgnoresAbbreviations() {
        // "No." and "Dr." are abbreviations, not sentence boundaries — the period guard
        // must not cut here (the whole thing stays one side, no spurious truncation).
        XCTAssertEqual(
            CaseName.truncateAtConsolidatedBoundary("Pulaski County Special School District No. 1 Dr. J.F. Cooley"),
            "Pulaski County Special School District No. 1 Dr. J.F. Cooley")
    }

    func testBoundaryIgnoresCorporateAbbreviation() {
        XCTAssertEqual(
            CaseName.truncateAtConsolidatedBoundary("Warner Bros. Pictures Inc."),
            "Warner Bros. Pictures Inc.")
    }

    // MARK: surname-only individuals (Rule 10.2.1(g))

    func testIndividualsReducedToSurnames() {
        XCTAssertEqual(CaseName.bluebookCaseName("Albert Harris v. Dan D. Stephens"),
                       "Harris v. Stephens")
    }

    func testGovernmentalPartyKeptWhole() {
        XCTAssertEqual(CaseName.bluebookCaseName("United States v. Armand Bilotti"),
                       "United States v. Bilotti")
    }

    func testOrganizationKeptWhole() {
        XCTAssertEqual(CaseName.bluebookCaseName("Lloyd Cramer v. Consolidated Freightways Inc."),
                       "Cramer v. Consolidated Freightways Inc.")
    }

    func testStatePartyKeptWhole() {
        XCTAssertEqual(CaseName.bluebookCaseName("Tennessee v. Edward Garner"),
                       "Tennessee v. Garner")
    }

    func testSpaceMashedMultiPartyLeftIntact() {
        // 4+ tokens with no comma: a concatenated party list, not one person — reducing
        // to the last token ("Lipich") would name the wrong party, so keep it whole.
        XCTAssertEqual(
            CaseName.bluebookCaseName("Lloyd W. Cramer Daniel E. Lipich v. Consolidated Freightways Inc."),
            "Lloyd W. Cramer Daniel E. Lipich v. Consolidated Freightways Inc.")
    }

    func testChainAndSurnameTogether() {
        XCTAssertEqual(
            CaseName.bluebookCaseName("Albert Harris v. Dan D. Stephens v. Dan D. Stephens"),
            "Harris v. Stephens")
    }

    // MARK: interaction with rendering / short titles

    func testRenderCollapsesMultiPartyName() {
        let rt = CaseName.render(
            "Donald O'Connor, and Benjamin M. Aban v. United States",
            style: .courtDocument)
        XCTAssertEqual(rt.plainText, "O'Connor v. United States")
    }

    func testShortTitleFromMultiPartyClassAction() {
        // First party is an individual → surname; opposing generic party dropped.
        XCTAssertEqual(
            CaseName.shortTitle("Donald O'Connor, and Benjamin M. Aban v. United States"),
            "O'Connor")
    }
}
