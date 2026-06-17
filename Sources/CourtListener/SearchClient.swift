import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Async client for the CourtListener opinions search endpoint.
///
/// Auth is a free API token (`Authorization: Token <key>`) from a CL account.
/// Anonymous requests work but are rate-limited harder; an absent token is a
/// recoverable condition, not a crash.
public final class SearchClient {

    public enum ClientError: Error, Equatable {
        case missingAPIKey
        case http(Int)
        case timedOut
        case transport(String)
    }

    private let apiKey: String?
    private let session: URLSession
    private let base = URL(string: "https://www.courtlistener.com/api/rest/v4/search/")!

    public init(apiKey: String?, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// This is a case-citation tool, so people search by party name: target the
    /// case-name field. Static + internal so it's unit-testable without a network
    /// call. (`searchOpinions` falls back to full text when this returns nothing.)
    static func buildQuery(_ raw: String) -> String {
        "caseName:(\(raw.trimmingCharacters(in: .whitespaces)))"
    }

    /// Search opinions for `query`, returning decoded results. Searches the case-name
    /// field most-cited-first (so landmark cases surface), and falls back to full text
    /// if the name search is empty (topical query or a typo). Throws on transport or
    /// non-2xx responses so the panel can surface "offline" / "rate limited".
    public func searchOpinions(_ query: String) async throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let byName = try await fetch(q: Self.buildQuery(trimmed))
        return byName.isEmpty ? try await fetch(q: trimmed) : byName
    }

    private func fetch(q: String) async throws -> [SearchResult] {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "type", value: "o"),
            // Most-cited first: surfaces the canonical case among same-named results.
            URLQueryItem(name: "order_by", value: "citeCount desc"),
        ]
        var request = URLRequest(url: components.url!)
        // CourtListener can be slow on a cold request; keep the ceiling generous so a
        // warm-up doesn't read as "offline". Distinguish a timeout from a true
        // connectivity failure so the UI can phrase them differently.
        request.timeoutInterval = 30
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw ClientError.timedOut
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ClientError.http(http.statusCode)
        }

        return try JSONDecoder().decode(SearchResponse.self, from: data).results
    }
}
