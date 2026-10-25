import Foundation

/// 拦截页链接的纯逻辑：把原始 URL 编码进拦截页的 URL 片段，并在恢复时安全地取回。
public enum BlockPageLink {
    public static let fileName = "blocked.html"
    public static let directoryName = "Session"
    private static let fragmentKey = "o="

    /// 只允许 http / https（不区分大小写）。
    public static func isSafeOriginal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// `o=<percent-encoded original>`（不含 `#`）。
    public static func fragment(for original: URL) -> String {
        fragmentKey + (original.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
    }

    /// 从标签页 URL 取回原始 URL。仅当路径恰好以 `/Session/blocked.html` 结尾（后接 `#`）、
    /// 且原始 URL 为 http(s) 时返回。
    public static func originalURL(fromTabURL tabURL: String) -> URL? {
        guard let hash = tabURL.firstIndex(of: "#") else { return nil }
        let base = tabURL[..<hash]
        guard base.lowercased().hasPrefix("file:"), !base.contains("?"), base.hasSuffix("/" + directoryName + "/" + fileName) else { return nil }
        let fragment = tabURL[tabURL.index(after: hash)...]
        guard fragment.hasPrefix(fragmentKey),
              let decoded = String(fragment.dropFirst(fragmentKey.count)).removingPercentEncoding,
              let url = URL(string: decoded), isSafeOriginal(url) else { return nil }
        return url
    }
}

extension String {
    /// 转义后可安全放进 AppleScript 双引号字符串字面量。
    public var appleScriptEscaped: String {
        var out = ""
        for ch in unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
