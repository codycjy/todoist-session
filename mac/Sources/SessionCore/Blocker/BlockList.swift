import Foundation

public enum BlockDecision: Equatable, Sendable {
    case allow
    case hideApp(bundleId: String)
    case redirectSite(host: String)
}

public struct BlockList: Codable, Equatable, Sendable {
    public var apps: Set<String>
    public var domains: Set<String>

    public init(apps: Set<String> = [], domains: Set<String> = []) {
        self.apps = apps
        self.domains = Set(domains.map { $0.lowercased() })
    }

    public init(appsCSV: String, domainsCSV: String) {
        func parts(_ s: String) -> [String] {
            s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        self.init(apps: Set(parts(appsCSV)), domains: Set(parts(domainsCSV)))
    }

    public func merged(with other: BlockList) -> BlockList {
        BlockList(apps: apps.union(other.apps), domains: domains.union(other.domains))
    }

    public func decide(bundleId: String?, urlHost: String?) -> BlockDecision {
        if let bundleId, apps.contains(bundleId) { return .hideApp(bundleId: bundleId) }
        if let host = urlHost?.lowercased(),
           domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return .redirectSite(host: host)
        }
        return .allow
    }
}
