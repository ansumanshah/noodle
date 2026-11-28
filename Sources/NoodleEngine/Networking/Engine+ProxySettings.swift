import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    /// Current proxy choice with URL credentials hidden.
    public func proxySettings() -> ProxySettings {
        var safe = proxy.redacted
        if let raw = safe.url, var url = URLComponents(string: raw), url.user != nil {
            url.user = ProxySettings.redactedPassword
            safe.url = url.string
        }
        return safe
    }

    public func setProxySettings(_ new: ProxySettings) async throws {
        var merged = new.restoringPassword(from: proxy)
        if let raw = merged.url, var url = URLComponents(string: raw), url.user == ProxySettings.redactedPassword {
            url.user = proxy.url.flatMap(URLComponents.init(string:))?.user
            merged.url = url.string
        }
        do { try merged.validate() } catch let e as ImageError { throw EngineError.badRequest(e.description) }
        _ = try Self.proxyEnvironment(merged)
        try merged.save(to: paths.proxyFile)
        proxy = merged
        await imageStore.registry.setProxy(merged)
    }
}
