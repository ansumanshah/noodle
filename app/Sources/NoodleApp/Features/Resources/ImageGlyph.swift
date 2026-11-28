import SwiftUI

enum ImageKind: Equatable, Sendable {
    case database, cache, runtime, web, base, storage, generic

    init(reference: String) {
        let path = reference.split(separator: "@", maxSplits: 1).first ?? ""
        let leaf = path.split(separator: "/").last ?? ""
        let name = leaf.split(separator: ":", maxSplits: 1).first?.lowercased() ?? ""
        switch name {
        case "postgres", "mysql", "mariadb", "mongo", "cockroachdb": self = .database
        case "redis", "valkey", "memcached", "redis-stack-server": self = .cache
        case "node", "python", "golang", "ruby", "rust", "eclipse-temurin", "php": self = .runtime
        case "nginx", "caddy", "httpd", "traefik": self = .web
        case "alpine", "ubuntu", "debian", "busybox", "fedora": self = .base
        case "minio": self = .storage
        default: self = .generic
        }
    }

    var symbol: String {
        switch self {
        case .database: "cylinder"
        case .cache: "bolt.fill"
        case .runtime: "curlybraces"
        case .web: "globe"
        case .base: "terminal"
        case .storage: "externaldrive"
        case .generic: "square.3.layers.3d"
        }
    }

    var tint: Color {
        switch self {
        case .database: .blue
        case .cache: .orange
        case .runtime: .teal
        case .web: .indigo
        case .storage: .purple
        case .base, .generic: .secondary
        }
    }
}

struct ImageGlyph: View {
    let reference: String
    var size: CGFloat = 22

    var body: some View {
        let kind = ImageKind(reference: reference)
        Image(systemName: kind.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(kind.tint)
            .frame(width: size, height: size)
            .background(kind.tint.opacity(0.12), in: .rect(cornerRadius: Radius.control))
            .accessibilityHidden(true)
    }
}
