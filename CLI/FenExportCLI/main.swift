import AppKit
import FenCore
import Foundation

// Entry point for `fen-export` (issue #34) -- parses arguments, then drives `ExportCLIRunner`'s
// batch loop. All real logic lives in `FenCore` (`ExportCLIRunner`, tested via
// `@testable import FenCore`); this file only wires `CommandLine.arguments` to it and maps the
// result to a process exit code (rule 5.1: no export logic duplicated here).
//
// PDF export renders through `WKWebView` + `NSPrintOperation`, both of which need a live
// `NSApplication` context to run their internal Objective-C runloop callbacks -- confirmed via a
// standalone repro before writing this that this works from a bare executable with no `.app`
// bundle and no `NSApplication.run()`, as long as the process's main thread keeps spinning
// `RunLoop.main` until the async work calls `exit(_:)` itself.
_ = NSApplication.shared
NSApplication.shared.setActivationPolicy(.prohibited)

Task { @MainActor in
    let usage = "usage: fen-export <input.md> [<input2.md> ...] --format <html|pdf> "
        + "[--output-dir <dir>] [--linked-assets]"
    let arguments: CLIExportArguments
    do {
        arguments = try CLIExportArguments.parse(Array(CommandLine.arguments.dropFirst()))
    } catch {
        FileHandle.standardError.write(Data("fen-export: \(error)\n\(usage)\n".utf8))
        exit(2)
    }

    let results = await ExportCLIRunner().run(arguments)
    for result in results where result.succeeded {
        print(result.outputURL?.path ?? "")
    }
    exit(results.allSatisfy(\.succeeded) ? 0 : 1)
}

RunLoop.main.run()
