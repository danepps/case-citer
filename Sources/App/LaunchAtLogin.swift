#if canImport(ServiceManagement)
import ServiceManagement
import Foundation

/// Thin wrapper over `SMAppService.mainApp` (macOS 13+), the modern replacement for
/// the deprecated `SMLoginItemSetEnabled`. The system is the source of truth here —
/// we never mirror the flag into `UserDefaults`; instead we read `.status` and
/// register/unregister on change.
///
/// Note: this only works when the executable is launched from inside a proper `.app`
/// bundle (with a bundle identifier). A bare `swift run` binary has no bundle, so
/// `register()` throws and the toggle reverts — expected in dev (see README).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                switch (newValue, SMAppService.mainApp.status) {
                case (true, let s) where s != .enabled:
                    try SMAppService.mainApp.register()
                case (false, .enabled):
                    try SMAppService.mainApp.unregister()
                default:
                    break // already in the desired state
                }
            } catch {
                NSLog("Case Citer: failed to set launch-at-login to \(newValue): \(error.localizedDescription)")
            }
        }
    }
}
#endif
