import AppKit
import SessionCore

final class MacBlockEnforcer: BlockEnforcer {
    private var overlay: NSPanel?
    private var overlayTimer: Timer?

    func enforce(_ decision: BlockDecision, focusTitle: String, remainingSeconds: Int) {
        switch decision {
        case .allow:
            return
        case .hideApp(let bundleId):
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).forEach { _ = $0.hide() }
        case .redirectSite:
            guard let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                  let page = BlockPage.url() else { return }
            Browser.redirect(bundleId: bundleId, to: page)
        }
        showOverlay("正在专注：\(focusTitle)　剩余 \(AppModel.format(remainingSeconds))")
    }

    private func showOverlay(_ text: String) {
        overlayTimer?.invalidate()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 40, height: label.frame.height + 28)
        let panel = overlay ?? NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.78)
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        label.textColor = .white
        label.frame.origin = NSPoint(x: 20, y: 14)
        panel.setContentSize(size)
        panel.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        panel.contentView?.addSubview(label)
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY))
        }
        panel.orderFrontRegardless()
        overlay = panel
        overlayTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            self?.overlay?.orderOut(nil)
        }
    }
}
