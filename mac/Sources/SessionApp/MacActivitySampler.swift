import AppKit
import ApplicationServices
import IOKit
import IOKit.pwr_mgt
import os
import SessionCore

final class MacActivitySampler: ActivitySampler {
    /// 距上次键鼠输入的秒数。用 IOKit HIDIdleTime，而不是 CGEventSource——后者在非 .app 的进程里
    /// 会返回系统开机时长（见 activity-clock b887f94）。若前台 App 持有"阻止显示器休眠"断言
    /// （正在播放视频/演示），超过阈值也不算闲置：此时返回 0。
    func idleSeconds() -> TimeInterval {
        let hid = Self.hidIdleSeconds()
        guard hid >= Self.assertionCheckFloor else { return hid }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           Self.holdsDisplaySleepAssertion(pid: pid) { return 0 }
        return hid
    }

    /// 距上次键鼠输入的秒数，不看电源断言（休息提醒用：休息时看视频不算在干活）。
    static func inputIdleSeconds() -> TimeInterval { hidIdleSeconds() }

    /// 只在已经接近闲置阈值时才去查电源断言，避免每 2 秒都查。
    private static let assertionCheckFloor: TimeInterval = 60

    private static func hidIdleSeconds() -> TimeInterval {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }
        guard let prop = IORegistryEntryCreateCFProperty(entry, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return 0 }
        return TimeInterval(prop.int64Value) / 1_000_000_000
    }

    /// IOPMCopyAssertionsByProcess 返回 { PID(CFNumber) → [断言字典] }；断言字典里 "AssertType" 为
    /// "PreventUserIdleDisplaySleep" 表示该进程在阻止显示器休眠（视频播放等）。
    private static func holdsDisplaySleepAssertion(pid: pid_t) -> Bool {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let dict = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        return (dict[NSNumber(value: pid)] ?? []).contains { ($0["AssertType"] as? String) == "PreventUserIdleDisplaySleep" }
    }

    func frontmost() -> FrontmostInfo {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return FrontmostInfo(bundleId: nil, appName: nil, windowTitle: nil, urlHost: nil)
        }
        let bundleId = app.bundleIdentifier
        let host = bundleId.flatMap { Browser.currentURL(bundleId: $0) }?.host?.lowercased()
        Log.debug("采样 前台=\(bundleId ?? "nil") host=\(host ?? "nil") AX=\(AXIsProcessTrusted())")
        return FrontmostInfo(bundleId: bundleId, appName: app.localizedName,
                             windowTitle: Self.windowTitle(pid: app.processIdentifier), urlHost: host)
    }

    /// 需要"辅助功能"权限；没有权限时返回 nil（降级为只按 App 粒度）。
    private static func windowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        let werr = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window)
        guard werr == .success, let window else {
            // -25211 APIDisabled（未授权）、-25204 CannotComplete 等，排查权限问题时看这里。
            log.debug("AXFocusedWindow pid=\(pid) failed: \(werr.rawValue)")
            return nil
        }
        var title: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        guard err == .success else { log.debug("AXTitle pid=\(pid) failed: \(err.rawValue)"); return nil }
        let text = title as? String
        return (text?.isEmpty ?? true) ? nil : text   // 空标题按"没有标题"处理
    }

    private static let log = Logger(subsystem: "session", category: "sampler")
}
