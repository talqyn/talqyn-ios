import Foundation

/// Builds URLs and `URLRequest`s.
///
/// A separate type because the path is significant: instant search carries a
/// trailing slash (`/v1/search/`) and the rest do not, and joining must not lose
/// it.
struct TalqynRequestBuilder: Sendable {
    let baseURL: URL
    let apiVersion: String
    let timeout: TimeInterval

    /// What may stand unescaped inside one path segment: the path charset
    /// minus the separator itself.
    private static let segmentAllowed = CharacterSet.urlPathAllowed
        .subtracting(CharacterSet(charactersIn: "/"))

    /// The same, plus `%`, so that a path assembled from segments already
    /// escaped with ``segment(_:)`` is not escaped a second time.
    private static let pathAllowed = segmentAllowed.union(CharacterSet(charactersIn: "%"))

    /// Escapes a value for use as one segment of a path.
    ///
    /// A `/` inside it becomes `%2F` rather than a separator: a session id is a
    /// value, not a route, and `chats/../../admin` must reach the server as
    /// exactly that string under `chats/`.
    static func segment(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? ""
    }

    /// Joins the base, the version, and `path` into a URL.
    ///
    /// `path` is a `/`-separated route whose segments are escaped one by one;
    /// values that may themselves contain a `/` go through ``segment(_:)``
    /// first and pass through untouched. A query on the base URL — a gateway
    /// key, say — is kept in front of the request's own items.
    func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw TalqynError.invalidConfiguration("could not parse baseURL: \(baseURL)")
        }
        var prefix = components.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        let version = apiVersion
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .addingPercentEncoding(withAllowedCharacters: Self.pathAllowed) ?? ""
        var tail = path
        while tail.hasPrefix("/") { tail.removeFirst() }
        let route = tail
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: Self.pathAllowed) ?? "" }
            .joined(separator: "/")

        components.percentEncodedPath = prefix + (version.isEmpty ? "" : "/" + version) + "/" + route
        let items = (components.queryItems ?? []) + query
        components.queryItems = items.isEmpty ? nil : items

        guard let url = components.url else {
            throw TalqynError.invalidConfiguration("could not build a URL for path \(path)")
        }
        return url
    }

    func request(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        headers: [String: String] = [:],
        accept: String = "application/json",
        timeout: TimeInterval? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: try url(path: path, query: query))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout ?? self.timeout
        request.setValue(accept, forHTTPHeaderField: "Accept")
        // Set before the caller's own headers, which may override it.
        request.setValue(Talqyn.clientHeader, forHTTPHeaderField: "X-Talqyn-SDK")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }
}
