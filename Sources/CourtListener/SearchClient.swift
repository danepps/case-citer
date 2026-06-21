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
        /// The response wasn't the JSON we expect — usually CourtListener changed its
        /// shape. Carries a diagnostic detail; the UI shows a concise message instead.
        case decoding(String)
    }

    private let apiKeyProvider: () -> String?
    private let session: URLSession
    private let cache: SearchCache?
    private let base = URL(string: "https://www.courtlistener.com/api/rest/v4/search/")!

    /// - Parameter apiKeyProvider: evaluated *per request*, so a token toggled in
    ///   Settings takes effect on the next search without relaunching the app. Return
    ///   `nil`/empty for an anonymous request.
    /// - Parameter cache: result cache (defaults to a disk-backed one). Pass `nil`
    ///   to disable caching — e.g. in tests that assert on live network behavior.
    public init(apiKeyProvider: @escaping () -> String?,
                session: URLSession? = nil,
                cache: SearchCache? = SearchCache(diskURL: SearchCache.defaultDiskURL())) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session ?? Self.makeSession()
        self.cache = cache
    }

    /// Convenience for a fixed token (or anonymous): a one-shot CLI call or a test
    /// where the token won't change over the client's lifetime.
    public convenience init(apiKey: String?,
                            session: URLSession? = nil,
                            cache: SearchCache? = SearchCache(diskURL: SearchCache.defaultDiskURL())) {
        self.init(apiKeyProvider: { apiKey }, session: session, cache: cache)
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
        let key = SearchCache.key(for: query)
        if let cached = await cache?.value(for: key) {
            return cached
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let byName = try await fetch(q: Self.buildQuery(trimmed))
        let results = byName.isEmpty ? try await fetch(q: trimmed) : byName
        // Only successful (non-throwing) responses reach here, so an empty result is a
        // genuine "no match" worth caching to avoid re-querying typos.
        await cache?.store(results, for: key)
        return results
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
        if let apiKey = apiKeyProvider(), !apiKey.isEmpty {
            request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await dataRetryingTimeout(request, attempts: 2)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ClientError.http(http.statusCode)
        }

        // A decode failure here means the payload wasn't the search shape we expect
        // (e.g. CourtListener changed its response). Tag it distinctly from transport
        // errors so the UI can stay concise while the detail survives for diagnostics.
        do {
            return try JSONDecoder().decode(SearchResponse.self, from: data).results
        } catch {
            throw ClientError.decoding(String(describing: error))
        }
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
