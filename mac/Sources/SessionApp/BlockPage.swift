import Foundation

enum BlockPage {
    /// 拦截页文件名；恢复时靠它识别被重定向的标签页。
    static let fileName = "blocked.html"
    private static let fragmentKey = "o="

    /// `original` 编码进 URL 片段：即使 App 退出/崩溃，也能从标签页本身还原，不需要额外落盘状态。
    static func url(original: URL? = nil) -> URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            .appendingPathComponent("Session", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(fileName)
        let html = """
        <!doctype html><meta charset="utf-8"><title>专注中</title>
        <body style="font:20px -apple-system;display:grid;place-items:center;height:100vh;margin:0;color:#444">
        <div style="text-align:center"><div style="font-size:64px">🍅</div><p>正在专注，这个网站已被屏蔽。</p>
        <p style="font-size:14px"><a id="back" href="#">专注结束后点此返回原页面</a></p></div>
        <script>
        var m = location.hash.match(/o=(.*)$/);
        if (m) document.getElementById('back').href = decodeURIComponent(m[1]);
        </script></body>
        """
        try? html.write(to: file, atomically: true, encoding: .utf8)
        guard let original,
              let encoded = original.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return file }
        return URL(string: file.absoluteString + "#" + fragmentKey + encoded)
    }

    /// 从拦截页 URL 里取回原始 URL；不是拦截页或没有原始 URL 时返回 nil。
    static func originalURL(from tabURL: String) -> URL? {
        guard tabURL.contains("/Session/" + fileName), let r = tabURL.range(of: "#" + fragmentKey) else { return nil }
        return String(tabURL[r.upperBound...]).removingPercentEncoding.flatMap { URL(string: $0) }
    }
}
