import Foundation

/// The app's preferences. Scripted test runs get a store of their own, so they never change
/// the user's last page, panel state or model choice.
enum AppDefaults {
    /// UserDefaults is thread-safe, but this SDK does not mark it Sendable.
    nonisolated(unsafe) static let store: UserDefaults = {
        #if DEBUG || SELFTEST
        let environment = ProcessInfo.processInfo.environment
        if ["FLOTION_SELFTEST", "FLOTION_PERFTEST", "FLOTION_MEMTEST"].contains(where: { environment[$0] != nil }),
           let tests = UserDefaults(suiteName: TestHost.defaultsSuite) {
            return tests
        }
        #endif
        return .standard
    }()
}
