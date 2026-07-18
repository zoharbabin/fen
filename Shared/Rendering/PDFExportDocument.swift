import SwiftUI
import UniformTypeIdentifiers

/// Wraps an already-rendered PDF `Data` for iOS's `.fileExporter` (issue #30) -- mirrors
/// `HTMLExportDocument`: `.fileExporter` needs a fully-prepared document before the user picks a
/// destination, so the render happens up front and this type only packages the result.
public struct PDFExportDocument: FileDocument {
    public static var readableContentTypes: [UTType] {
        []
    }

    public static var writableContentTypes: [UTType] {
        [.pdf]
    }

    private let data: Data

    public init(data: Data) {
        self.data = data
    }

    /// Never read back -- this document type only exists to be written out by `.fileExporter`.
    public init(configuration _: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    public func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
