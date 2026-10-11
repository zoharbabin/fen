#if os(macOS)
    import AppKit

    /// The "Check for Updates…" menu command (issue #39).
    public extension UpdateChecker {
        @MainActor
        static func checkAndShow() async {
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let alert = NSAlert()
            do {
                switch try await check(current: current) {
                case let .available(version, page):
                    alert.messageText = "Fen \(version) is available"
                    alert.informativeText = "You have \(current). Open the download page to get the new version."
                    alert.addButton(withTitle: "Open Download Page")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(page)
                    }
                    return
                case let .upToDate(current):
                    alert.messageText = "You're up to date"
                    alert.informativeText = "Fen \(current) is the newest version."
                case let .development(latest):
                    alert.messageText = "This is a development build"
                    alert.informativeText = "The newest release is Fen \(latest)."
                }
            } catch {
                alert.alertStyle = .warning
                alert.messageText = "Fen couldn't check for updates"
                alert.informativeText = error.localizedDescription
            }
            alert.runModal()
        }
    }
#endif
