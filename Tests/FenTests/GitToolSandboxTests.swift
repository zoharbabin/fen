@testable import FenCore
import Testing

@Suite("The sandboxed App Store build (issue #40)")
struct GitToolSandboxTests {
    @Test("a sandboxed process finds no git, so sync and agent branches stay off")
    func noGitInTheSandbox() {
        #if os(macOS)
            #expect(GitTool.locate(environment: [AppSandbox.marker: "com.zoharbabin.fen"]) == nil)
        #endif
    }

    @Test("an unsandboxed process still finds git")
    func gitOutsideTheSandbox() {
        #if os(macOS)
            #expect(GitTool.locate(environment: [:]) != nil)
        #endif
    }

    @Test("the sandbox marker decides AppSandbox.isActive")
    func sandboxMarker() {
        #expect(AppSandbox.isActive(environment: [AppSandbox.marker: "com.zoharbabin.fen"]))
        #expect(!AppSandbox.isActive(environment: [:]))
    }
}
