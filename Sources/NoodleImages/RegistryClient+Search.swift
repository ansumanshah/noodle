import Foundation
import CFNetwork
import NoodleCore

extension RegistryClient {
    // MARK: search

    /// Search Docker Hub. The request goes through the same transport and proxy settings as pulls, and the
    /// connection is closed as soon as the answer is in. Any upstream failure throws; it never returns an empty list.
    public func search(term: String, limit: Int = 25, officialOnly: Bool = false) async throws -> [SearchResult] {
        var comps = URLComponents(string: "https://hub.docker.com/v2/search/repositories/")!
        var items: [URLQueryItem] = [.init(name: "query", value: term), .init(name: "page_size", value: String(max(1, min(limit, 100))))]
        if officialOnly { items.append(.init(name: "is_official", value: "true")) }
        comps.queryItems = items
        let data: Data, resp: HTTPURLResponse
        do { (data, resp) = try await transport.data(URLRequest(url: comps.url!, timeoutInterval: 20), releaseConnection: true) }
        catch is CancellationError { throw CancellationError() }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch { throw ImageError.io("search failed: could not reach Docker Hub (\(Self.describe(error)))") }
        guard resp.statusCode == 200 else {
            throw ImageError.registry(status: resp.statusCode, message: "search failed: Docker Hub answered \(resp.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: resp.statusCode))")
        }
        struct Page: Decodable {
            struct R: Decodable {
                var repo_name: String?; var short_description: String?; var star_count: Int?; var is_official: Bool?; var is_automated: Bool?
            }
            var results: [R]?
        }
        guard let page = try? JSONDecoder().decode(Page.self, from: data), let results = page.results else {
            throw ImageError.io("search failed: Docker Hub sent an answer Noodle could not read")
        }
        return results.map {
            SearchResult(name: $0.repo_name ?? "", description: $0.short_description ?? "", starCount: $0.star_count ?? 0,
                         isOfficial: $0.is_official ?? false, isAutomated: $0.is_automated ?? false)
        }
    }
}
