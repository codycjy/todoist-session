import XCTest
@testable import SessionCore

fileprivate final class FakeScheduler: SettingsScheduling {
    var pending: (() -> Void)?
    var scheduled: [TimeInterval] = []
    var cancelled = 0
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> SettingsCancellable {
        scheduled.append(seconds)
        pending = { Task { @MainActor in action() } }
        return SettingsCancellable { [weak self] in self?.cancelled += 1; self?.pending = nil }
    }
}

fileprivate final class FakeRemote: SettingsRemote, @unchecked Sendable {
    var fetchResult: Result<RemoteSettings, Error> = .failure(Boom())
    var pushResult: Result<RemoteSettings, Error>?
    var pushes: [SettingsPatch] = []
    func fetchSettings() async throws -> RemoteSettings { try fetchResult.get() }
    func pushSettings(_ patch: SettingsPatch) async throws -> RemoteSettings {
        pushes.append(patch)
        if let pushResult { return try pushResult.get() }
        return RemoteSettings(focusSeconds: patch.focusSeconds ?? 0, idleThresholdSeconds: patch.idleThresholdSeconds ?? 0,
                              blockApps: patch.blockApps ?? [], blockDomains: patch.blockDomains ?? [])
    }
}

fileprivate struct Boom: Error {}

@MainActor
final class SettingsStoreTests: XCTestCase {
    var suite: String!
    var defaults: UserDefaults!
    fileprivate var scheduler: FakeScheduler!
    fileprivate var remote: FakeRemote!

    override func setUp() async throws {
        suite = "settings-test-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        scheduler = FakeScheduler()
        remote = FakeRemote()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeStore(env: [String: String] = [:], remote: SettingsRemote? = nil) -> SettingsStore {
        SettingsStore(defaults: defaults, env: env, scheduler: scheduler, remote: remote)
    }

    func testDefaults() {
        let s = makeStore()
        XCTAssertEqual(s.effective, AppSettings(focusSeconds: 1500, idleThresholdSeconds: 120, blockApps: [], blockDomains: []))
    }

    func testStoredBeatsDefaultAndPersists() {
        let s = makeStore()
        s.update { $0.focusSeconds = 600; $0.blockApps = ["com.a"] }
        let again = makeStore()
        XCTAssertEqual(again.effective.focusSeconds, 600)
        XCTAssertEqual(again.effective.blockApps, ["com.a"])
    }

    func testEnvBeatsStored() {
        let s = makeStore()
        s.update { $0.focusSeconds = 600; $0.blockDomains = ["a.com"] }
        let e = makeStore(env: ["SESSION_FOCUS_SECONDS": "10", "SESSION_BLOCK_DOMAINS": "B.com, c.com", "SESSION_IDLE_SECONDS": "45"])
        XCTAssertEqual(e.effective.focusSeconds, 10)
        XCTAssertEqual(e.effective.idleThresholdSeconds, 45)
        XCTAssertEqual(e.effective.blockDomains, ["b.com", "c.com"])
        XCTAssertEqual(e.values.focusSeconds, 600, "stored value stays editable and untouched")
        XCTAssertTrue(e.overridden.contains(.focusSeconds))
    }

    func testInvalidEnvIgnored() {
        let e = makeStore(env: ["SESSION_FOCUS_SECONDS": "abc"])
        XCTAssertEqual(e.effective.focusSeconds, 1500)
    }

    func testNormalisationAndClamping() {
        let s = makeStore()
        s.update {
            $0.focusSeconds = 5; $0.idleThresholdSeconds = 99999
            $0.blockDomains = [" YouTube.com ", "youtube.com", ""]
            $0.blockApps = [" com.a ", "com.a", " "]
        }
        XCTAssertEqual(s.values.focusSeconds, 60)
        XCTAssertEqual(s.values.idleThresholdSeconds, 1800)
        XCTAssertEqual(s.values.blockDomains, ["youtube.com"])
        XCTAssertEqual(s.values.blockApps, ["com.a"])
    }

    func testDebounceCancelsPreviousAndUsesOneSecond() async {
        remote.fetchResult = .success(RemoteSettings(focusSeconds: 1500, idleThresholdSeconds: 120, blockApps: [], blockDomains: []))
        let s = makeStore(remote: remote)
        s.update { $0.focusSeconds = 600 }
        s.update { $0.focusSeconds = 900 }
        XCTAssertEqual(scheduler.scheduled, [1, 1])
        XCTAssertEqual(scheduler.cancelled, 1)
        XCTAssertTrue(remote.pushes.isEmpty, "nothing is sent before the debounce fires")
        await s.flush()
        XCTAssertEqual(remote.pushes.count, 1)
        XCTAssertEqual(remote.pushes.first?.focusSeconds, 900)
        XCTAssertFalse(s.unsynced)
    }

    func testPushFailureKeepsLocalAndFlagsUnsynced() async {
        remote.pushResult = .failure(Boom())
        let s = makeStore(remote: remote)
        s.update { $0.blockApps = ["com.a"] }
        await s.flush()
        XCTAssertTrue(s.unsynced)
        XCTAssertEqual(s.values.blockApps, ["com.a"])
        // success on retry clears the flag
        remote.pushResult = nil
        s.update { $0.blockApps = ["com.a", "com.b"] }
        await s.flush()
        XCTAssertFalse(s.unsynced)
    }

    func testPullReplacesLocalWhenClean() async {
        let s = makeStore(remote: remote)
        s.update { $0.focusSeconds = 600 }
        await s.flush()                     // clean now
        remote.fetchResult = .success(RemoteSettings(focusSeconds: 1800, idleThresholdSeconds: 200, blockApps: ["x"], blockDomains: ["Y.com"]))
        await s.pull()
        XCTAssertEqual(s.values, AppSettings(focusSeconds: 1800, idleThresholdSeconds: 200, blockApps: ["x"], blockDomains: ["y.com"]))
        XCTAssertEqual(makeStore().values.focusSeconds, 1800, "pulled values are persisted")
    }

    func testPullFailureKeepsLocal() async {
        let s = makeStore(remote: remote)
        s.update { $0.focusSeconds = 600 }
        scheduler.pending = nil
        await s.pull()
        XCTAssertEqual(s.values.focusSeconds, 600)
        XCTAssertTrue(s.unsynced, "dirty local edit that could not be reached is unsynced")
    }

    func testPullWithDirtyLocalPushesLocalInsteadOfLosingIt() async {
        remote.pushResult = .failure(Boom())
        let first = makeStore(remote: remote)
        first.update { $0.focusSeconds = 600 }
        await first.flush()                 // failed -> dirty persisted
        remote.pushResult = nil
        remote.fetchResult = .success(RemoteSettings(focusSeconds: 1500, idleThresholdSeconds: 120, blockApps: [], blockDomains: []))
        let relaunched = makeStore(remote: remote)
        await relaunched.pull()
        XCTAssertEqual(relaunched.values.focusSeconds, 600)
        XCTAssertEqual(remote.pushes.last?.focusSeconds, 600)
        XCTAssertFalse(relaunched.unsynced)
    }

    func testNoRemoteNeverFlagsUnsynced() async {
        let s = makeStore()
        s.update { $0.focusSeconds = 600 }
        await s.flush()
        XCTAssertFalse(s.unsynced)
    }

    func testMergeIsPure() {
        let local = AppSettings(focusSeconds: 600, idleThresholdSeconds: 120, blockApps: [], blockDomains: [])
        let remote = AppSettings(focusSeconds: 900, idleThresholdSeconds: 120, blockApps: [], blockDomains: [])
        XCTAssertEqual(SettingsStore.merge(local: local, remote: remote, localDirty: false), .useRemote(remote))
        XCTAssertEqual(SettingsStore.merge(local: local, remote: remote, localDirty: true), .pushLocal)
    }

    func testProfileDrivesFocusBreakAndBlocklist() {
        var s = AppSettings(focusSeconds: 1500, idleThresholdSeconds: 120, blockApps: ["g.app"], blockDomains: ["g.com"])
        s.profiles["coding"] = CategoryProfile(focusSeconds: 3000, breakSeconds: 1500, inheritBlocklist: true,
                                               blockApps: ["p.app"], blockDomains: ["P.com"])
        s.profiles["solo"] = CategoryProfile(focusSeconds: 1200, breakSeconds: 300, inheritBlocklist: false, blockDomains: ["only.com"])
        s = s.normalized()
        XCTAssertEqual(s.focusSeconds(for: "coding"), 3000)
        XCTAssertEqual(s.focusSeconds(for: nil), 1500)
        XCTAssertEqual(s.breakSeconds(for: "coding", kind: .long), 1500)
        XCTAssertEqual(s.breakSeconds(for: "other", kind: .short), AppSettings.shortBreakSeconds)
        XCTAssertEqual(s.breakSeconds(for: nil, kind: .long), AppSettings.longBreakSeconds)
        XCTAssertEqual(s.blocklist(for: "coding"), BlockList(apps: ["g.app", "p.app"], domains: ["g.com", "p.com"]))
        XCTAssertEqual(s.blocklist(for: "solo"), BlockList(apps: [], domains: ["only.com"]))
        XCTAssertEqual(s.blocklist(for: nil), BlockList(apps: ["g.app"], domains: ["g.com"]))
    }

    @MainActor
    func testProfilesPersistAcrossStores() {
        let suite = "profiles-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = SettingsStore(defaults: defaults, env: [:])
        a.update { $0.profiles["c1"] = CategoryProfile(focusSeconds: 3000, breakSeconds: 600) }
        let b = SettingsStore(defaults: defaults, env: [:])
        XCTAssertEqual(b.values.profiles["c1"]?.focusSeconds, 3000)
    }

    func testRemoteSettingsWithoutProfilesDecode() throws {
        let r = try JSONDecoder().decode(RemoteSettings.self, from: Data(#"{"focusSeconds":1500,"idleThresholdSeconds":120,"blockApps":[],"blockDomains":[]}"#.utf8))
        XCTAssertEqual(r.profiles, [:])
    }
}
