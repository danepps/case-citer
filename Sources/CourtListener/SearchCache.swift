import Foundation

/// LRU cache of search results keyed by the *normalized* query string, with an
/// optional JSON-on-disk backing so cached cites survive app relaunch.
///
/// Correct by construction: a hit requires an identical normalized query, so a
/// cached response is exactly what the API would have returned for that query —
/// we never reuse one query's results for a different one. Entries older than
/// `ttl` are treated as misses (a staleness bound for newly-added opinions), and
/// the store is capped at `capacity`, evicting least-recently-used keys.
///
/// An `actor` so concurrent searches (overlapping in-flight tasks) can read and
/// write it without data races.
public actor SearchCache {
    private struct Entry: Codable {
        var results: [SearchResult]
        var storedAt: Date
    }

    private var entries: [String: Entry]
    private var order: [String]            // LRU recency; most-recently-used last
    private let capacity: Int
    private let ttl: TimeInterval
    private let diskURL: URL?

    /// - Parameters:
    ///   - capacity: max distinct queries retained (LRU beyond this).
    ///   - ttl: how long a cached response stays fresh, in seconds (default 24h).
    ///   - diskURL: optional file to persist to/from; nil = in-memory only.
    public init(capacity: Int = 200, ttl: TimeInterval = 24 * 60 * 60, diskURL: URL? = nil) {
        self.capacity = max(1, capacity)
        self.ttl = ttl
        self.diskURL = diskURL
        // Best-effort load of the persisted cache; a corrupt/absent file is just an
        // empty cache, never a failure.
        if let diskURL,
           let data = try? Data(contentsOf: diskURL),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            self.entries = saved
            self.order = saved.keys.sorted { saved[$0]!.storedAt < saved[$1]!.storedAt }
        } else {
            self.entries = [:]
            self.order = []
        }
    }

    /// The normalized cache key for a raw query: trimmed + lowercased, since the
    /// CourtListener case-name search is case-insensitive (so "Roe" and "roe" share
    /// an entry).
    public static func key(for query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Fresh cached results for `key`, or nil on a miss (absent or expired). A hit
    /// refreshes the key's recency; an expired entry is dropped.
    public func value(for key: String) -> [SearchResult]? {
        guard let entry = entries[key] else { return nil }
        if Date().timeIntervalSince(entry.storedAt) > ttl {
            remove(key)
            persist()
            return nil
        }
        touch(key)
        return entry.results
    }

    /// Store `results` for `key`, marking it most-recently-used and evicting the
    /// oldest keys past `capacity`. Persists to disk if configured.
    public func store(_ results: [SearchResult], for key: String) {
        entries[key] = Entry(results: results, storedAt: Date())
        touch(key)
        evictIfNeeded()
        persist()
    }

    // MARK: LRU bookkeeping

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func remove(_ key: String) {
        entries[key] = nil
        order.removeAll { $0 == key }
    }

    private func evictIfNeeded() {
        while entries.count > capacity, let oldest = order.first {
            remove(oldest)
        }
    }

    private func persist() {
        guard let diskURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: diskURL, options: .atomic)
    }

    /// Default on-disk location: `~/Library/Application Support/CaseCiter/search-cache.json`.
    /// Nil if the directory can't be created (cache then runs in-memory only).
    public static func defaultDiskURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        let dir = support.appendingPathComponent("CaseCiter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("search-cache.json")
    }
}
