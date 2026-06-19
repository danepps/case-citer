import XCTest
@testable import CourtListener

final class SearchCacheTests: XCTestCase {

    /// Build a SearchResult via JSON (its memberwise init is internal to the module).
    private func result(_ name: String) throws -> SearchResult {
        let json = #"{"caseName": "\#(name)", "citation": ["576 U.S. 644"]}"#
        return try JSONDecoder().decode(SearchResult.self, from: Data(json.utf8))
    }

    // MARK: key normalization

    func testKeyTrimsAndLowercases() {
        XCTAssertEqual(SearchCache.key(for: "  Roe v. Wade "), "roe v. wade")
        XCTAssertEqual(SearchCache.key(for: "ROE"), SearchCache.key(for: "roe"))
    }

    // MARK: hit / miss

    func testStoreThenHit() async throws {
        let cache = SearchCache()
        await cache.store([try result("Obergefell v. Hodges")], for: "obergefell")
        let hit = await cache.value(for: "obergefell")
        XCTAssertEqual(hit?.first?.caseName, "Obergefell v. Hodges")
    }

    func testMissForUnknownKey() async {
        let cache = SearchCache()
        let miss = await cache.value(for: "nope")
        XCTAssertNil(miss)
    }

    func testEmptyResultsAreCachedAsAHit() async throws {
        let cache = SearchCache()
        await cache.store([], for: "typoo")
        let hit = await cache.value(for: "typoo")
        XCTAssertEqual(hit?.count, 0)   // a real hit (empty array), not a nil miss
    }

    // MARK: TTL

    func testExpiredEntryIsAMiss() async throws {
        // Negative ttl: any stored entry is immediately stale.
        let cache = SearchCache(ttl: -1)
        await cache.store([try result("Stale v. Old")], for: "stale")
        let miss = await cache.value(for: "stale")
        XCTAssertNil(miss)
    }

    // MARK: LRU eviction

    func testEvictsLeastRecentlyUsedPastCapacity() async throws {
        let cache = SearchCache(capacity: 2)
        await cache.store([try result("A")], for: "a")
        await cache.store([try result("B")], for: "b")
        await cache.store([try result("C")], for: "c")   // evicts "a"
        let a = await cache.value(for: "a")
        let b = await cache.value(for: "b")
        let c = await cache.value(for: "c")
        XCTAssertNil(a)
        XCTAssertEqual(b?.first?.caseName, "B")
        XCTAssertEqual(c?.first?.caseName, "C")
    }

    func testAccessRefreshesRecency() async throws {
        let cache = SearchCache(capacity: 2)
        await cache.store([try result("A")], for: "a")
        await cache.store([try result("B")], for: "b")
        _ = await cache.value(for: "a")                  // "a" now most-recent
        await cache.store([try result("C")], for: "c")   // evicts "b", not "a"
        let a = await cache.value(for: "a")
        let b = await cache.value(for: "b")
        XCTAssertEqual(a?.first?.caseName, "A")
        XCTAssertNil(b)
    }

    // MARK: disk persistence

    func testPersistsAcrossInstances() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-cache-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = SearchCache(diskURL: url)
        await writer.store([try result("Brown v. Board")], for: "brown")

        // A fresh instance over the same file should load the persisted entry.
        let reader = SearchCache(diskURL: url)
        let hit = await reader.value(for: "brown")
        XCTAssertEqual(hit?.first?.caseName, "Brown v. Board")
    }
}
