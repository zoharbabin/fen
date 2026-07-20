#if os(macOS)
    import Foundation

    /// Format `fen-export` can convert a document to (issue #34).
    public enum CLIExportFormat: String, CaseIterable, Sendable {
        case html
        case pdf
    }

    /// Parsed command-line arguments for `fen-export <input.md>... --format <html|pdf>
    /// [--output-dir <dir>] [--linked-assets]` (issue #34).
    public struct CLIExportArguments: Sendable, Equatable {
        public let inputPaths: [String]
        public let format: CLIExportFormat
        public let outputDirectory: String?
        public let linkedAssets: Bool

        public enum ParseError: Error, Equatable, CustomStringConvertible {
            case noInputFiles
            case unknownFormat(String)
            case linkedAssetsRequiresHTML
            case missingValueForOption(String)
            case unknownOption(String)

            public var description: String {
                switch self {
                case .noInputFiles:
                    "no input files given"
                case let .unknownFormat(value):
                    "unknown --format value '\(value)' (expected html or pdf)"
                case .linkedAssetsRequiresHTML:
                    "--linked-assets is only valid with --format html"
                case let .missingValueForOption(option):
                    "missing value for \(option)"
                case let .unknownOption(option):
                    "unknown option \(option)"
                }
            }
        }

        /// Returns `arguments[index]`, having advanced `index` past it, or throws
        /// `.missingValueForOption(option)` if `index` already ran off the end -- shared by every
        /// `--flag <value>` case in `parse` so each one is a single call instead of its own guard.
        private static func takeValue(for option: String, from arguments: [String], index: inout Int) throws -> String {
            index += 1
            guard index < arguments.count else { throw ParseError.missingValueForOption(option) }
            return arguments[index]
        }

        /// Parses `arguments` (typically `CommandLine.arguments.dropFirst()`) into a validated
        /// `CLIExportArguments`, or throws a `ParseError` describing exactly what's wrong -- the
        /// CLI's own entry point is responsible for printing that description and exiting
        /// non-zero, this type does no I/O of its own.
        public static func parse(_ arguments: [String]) throws -> CLIExportArguments {
            var inputPaths: [String] = []
            var format: CLIExportFormat = .html
            var outputDirectory: String?
            var linkedAssets = false

            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                switch argument {
                case "--format":
                    let value = try takeValue(for: "--format", from: arguments, index: &index)
                    guard let parsed = CLIExportFormat(rawValue: value) else {
                        throw ParseError.unknownFormat(value)
                    }
                    format = parsed
                case "--output-dir":
                    outputDirectory = try takeValue(for: "--output-dir", from: arguments, index: &index)
                case "--linked-assets":
                    linkedAssets = true
                default:
                    guard !argument.hasPrefix("--") else { throw ParseError.unknownOption(argument) }
                    inputPaths.append(argument)
                }
                index += 1
            }

            guard !inputPaths.isEmpty else { throw ParseError.noInputFiles }
            guard format == .html || !linkedAssets else { throw ParseError.linkedAssetsRequiresHTML }

            return CLIExportArguments(
                inputPaths: inputPaths, format: format, outputDirectory: outputDirectory, linkedAssets: linkedAssets
            )
        }
    }

    /// One input file's export outcome -- either the file it wrote, or an error message, never
    /// thrown out of the batch (rule 3.1).
    public struct CLIExportResult: Sendable, Equatable {
        public let outputURL: URL?
        public let errorMessage: String?

        public var succeeded: Bool {
            errorMessage == nil
        }
    }

    /// Batch-converts Markdown files to HTML or PDF from the command line (issue #34) -- reuses
    /// `DocumentHTMLExporter`/`DocumentPDFExporter`/`PDFRenderer` (issues #31/#30) exactly as
    /// `SplitEditorView`'s own export menu already does, adding only argument parsing and the
    /// sequential batch loop (rule 5.1: no parallel rendering/composition path). Holds no stored
    /// state: every call is a pure function of its arguments and the filesystem at call time, so
    /// two concurrent runs in one process never share or corrupt each other's output (rule 1.1).
    @MainActor
    public struct ExportCLIRunner {
        public init() {}

        /// Exports every input path in `arguments`, one at a time (rule 4.1 -- bounded memory
        /// regardless of batch size). A file that fails to read, render, or write is reported via
        /// `reportError` and skipped; the rest of the batch still runs (rule 3.1/3.2). Returns one
        /// result per input path, in order, so the caller can compute an aggregate exit code.
        public func run(
            _ arguments: CLIExportArguments,
            preferences: Preferences = Preferences(),
            reportError: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        ) async -> [CLIExportResult] {
            if let outputDirectory = arguments.outputDirectory {
                do {
                    try FileManager.default.createDirectory(
                        atPath: outputDirectory, withIntermediateDirectories: true
                    )
                } catch {
                    let message =
                        "could not create output directory '\(outputDirectory)': \(error.localizedDescription)"
                    return arguments.inputPaths.map { path in
                        reportError("\(path): \(message)")
                        return CLIExportResult(outputURL: nil, errorMessage: message)
                    }
                }
            }

            var results: [CLIExportResult] = []
            for path in arguments.inputPaths {
                let result = await exportOne(path: path, arguments: arguments, preferences: preferences)
                if let errorMessage = result.errorMessage {
                    reportError("\(path): \(errorMessage)")
                }
                results.append(result)
            }
            return results
        }

        private func exportOne(
            path: String, arguments: CLIExportArguments, preferences: Preferences
        ) async -> CLIExportResult {
            let inputURL = URL(fileURLWithPath: path)
            let markdown: String
            do {
                markdown = try String(contentsOf: inputURL, encoding: .utf8)
            } catch {
                return CLIExportResult(
                    outputURL: nil,
                    errorMessage: "could not read file: \(error.localizedDescription)"
                )
            }

            let baseName = inputURL.deletingPathExtension().lastPathComponent
            let outputDirectoryURL = arguments.outputDirectory.map { URL(fileURLWithPath: $0) }
                ?? inputURL.deletingLastPathComponent()

            switch arguments.format {
            case .html:
                let mode: ExportAssetMode = arguments.linkedAssets
                    ? .linkedAssets(exportBaseName: baseName)
                    : .selfContained
                let exported = DocumentHTMLExporter().export(
                    markdown: markdown, documentURL: inputURL, preferences: preferences, mode: mode
                )
                let destination = outputDirectoryURL.appendingPathComponent("\(baseName).html")
                do {
                    try HTMLExportController().write(exported, to: destination)
                    return CLIExportResult(outputURL: destination, errorMessage: nil)
                } catch {
                    return CLIExportResult(outputURL: nil, errorMessage: error.localizedDescription)
                }
            case .pdf:
                let html = DocumentPDFExporter().export(
                    markdown: markdown, documentURL: inputURL, preferences: preferences
                )
                let destination = outputDirectoryURL.appendingPathComponent("\(baseName).pdf")
                do {
                    try await PDFRenderer().renderPDF(
                        html: html, baseDirectory: inputURL.deletingLastPathComponent(), to: destination
                    )
                    return CLIExportResult(outputURL: destination, errorMessage: nil)
                } catch {
                    return CLIExportResult(outputURL: nil, errorMessage: error.localizedDescription)
                }
            }
        }
    }
#endif
