import Foundation

enum BlockPage {
    static func url() -> URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            .appendingPathComponent("Session", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("blocked.html")
        let html = """
        <!doctype html><meta charset="utf-8"><title>专注中</title>
        <body style="font:20px -apple-system;display:grid;place-items:center;height:100vh;margin:0;color:#444">
        <div style="text-align:center"><div style="font-size:64px">🍅</div><p>正在专注，这个网站已被屏蔽。</p></div></body>
        """
        try? html.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
