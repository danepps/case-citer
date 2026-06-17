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

    public init(apiKey: String?, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.session = session ?? Self.makeSession()
    }

    /// Dedicated session for talking to CourtListener (behind a CDN, AWS CloudFront).
    /// We avoid `URLSession.shared` so HTTP/3 (QUIC) alt-svc data can't leak in from
    /// elsewhere: on some networks UDP/443 to the CDN is silently dropped, so a QUIC
    /// attempt hangs until the request times out (TCP/HTTP-2 works fine — that's why
    /// `curl` succeeds where the default session stalls). An ephemeral config keeps no
    /// persistent alt-svc cache, and `assumesHTTP3Capable = false` is set per request.
    private static func makeSession() -> URLSession {
        URLSession(configuration: .ephemeral)
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
        // Per-attempt ceiling. CourtListener (AWS CloudFront) is fast on TCP/HTTP-2 but
        // CFNetwork intermittently races HTTP/3 (QUIC) on UDP/443, which some networks
        // silently drop — that connection stalls. Keep the ceiling short so a stalled
        // attempt is abandoned quickly and retried (a fresh attempt usually lands on the
        // working TCP path) rather than freezing the panel for the old 30s.
        request.timeoutInterval = 12
        // Don't proactively use HTTP/3: it's the QUIC path above that stalls. This only
        // suppresses *proactive* h3 (macOS may still cache alt-svc), hence the retry.
        request.assumesHTTP3Capable = false
        // A real User-Agent: CDNs are likelier to fast-path an identified client than
        // a bare default, and it's polite to a free public API.
        request.setValue("CaseCiter/1.0 (macOS; +https://www.courtlistener.com)", forHTTPHeaderField: "User-Agent")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await dataRetryingTimeout(request, attempts: 2)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ClientError.http(http.statusCode)
        }

        return try JSONDecoder().decode(SearchResponse.self, from: data).results
    }

    /// Run `request`, retrying on timeout up to `attempts` times. A stalled HTTP/3
    /// attempt times out at the request's (short) ceiling; the next attempt usually
    /// reconnects over TCP and succeeds. Only timeouts are retried — an HTTP error or
    /// a genuine transport failure is surfaced immediately. Maps URL errors onto the
    /// client's error vocabulary so the panel can phrase them.
    private func dataRetryingTimeout(_ request: URLRequest, attempts: Int) async throws -> (Data, URLResponse) {
        var lastTimeout: Error = ClientError.timedOut
        for attempt in 1...max(1, attempts) {
            do {
                return try await session.data(for: request)
            } catch let urlError as URLError where urlError.code == .timedOut {
                lastTimeout = ClientError.timedOut
                if attempt == attempts { break }   // fall through to throw
            } catch {
                throw ClientError.transport(error.localizedDescription)
            }
        }
        throw lastTimeout
    }
}
