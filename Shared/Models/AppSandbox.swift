import Foundation

/// Whether this process runs in the App Sandbox, as the Mac App Store build does (issue #40).
/// The sandbox sets `APP_SANDBOX_CONTAINER_ID` in every process it starts.
public enum AppSandbox {
    static let marker = "APP_SANDBOX_CONTAINER_ID"

    public static func isActive(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[marker] != nil
    }
}
