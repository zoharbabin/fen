import SwiftUI

/// Earlier versions of the open document (issue #59), for iOS, which has no system screen for them.
/// macOS uses the system's Browse All Versions instead (File, Revert To).
///
/// Restoring puts the text of a version into the editor. It is not saved until the document
/// saves, and you can undo it in the editor. iOS can't make a version of the text it replaces.
struct VersionHistoryView: View {
    let fileURL: URL
    let restore: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [FileVersion] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                } else if versions.isEmpty {
                    ContentUnavailableView(
                        "No earlier versions",
                        systemImage: "clock.arrow.circlepath",
                        description: Text(
                            "iOS only has versions of a document that iCloud kept. Documents outside iCloud Drive have none."
                        )
                    )
                } else {
                    List(versions) { version in
                        NavigationLink(value: version) { row(version) }
                    }
                }
            }
            .navigationTitle("Version History")
            .navigationDestination(for: FileVersion.self) { version in
                VersionPreview(version: version) { text in
                    restore(text)
                    dismiss()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            versions = await FileVersionHistory.versions(of: fileURL)
            loading = false
        }
    }

    private func row(_ version: FileVersion) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(version.date?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown date")
            HStack(spacing: 6) {
                if let device = version.device {
                    Text(device)
                }
                if !version.isLocal {
                    Label("In iCloud", systemImage: "icloud")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

extension FileVersion: Hashable {
    public static func == (lhs: FileVersion, rhs: FileVersion) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private struct VersionPreview: View {
    let version: FileVersion
    let restore: (String) -> Void
    @State private var text: String?
    @State private var failure: String?
    @State private var confirming = false

    var body: some View {
        Group {
            if let text {
                ScrollView {
                    Text(text)
                        .font(.body.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
            } else if let failure {
                ContentUnavailableView(
                    "Can't read this version",
                    systemImage: "exclamationmark.triangle",
                    description: Text(failure)
                )
            } else {
                ProgressView(version.isLocal ? "Reading…" : "Downloading from iCloud…")
            }
        }
        .navigationTitle(version.date?.formatted(date: .abbreviated, time: .shortened) ?? "Version")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Restore") { confirming = true }.disabled(text == nil)
            }
        }
        .confirmationDialog(
            "Replace the text in the editor with this version?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Restore This Version", role: .destructive) {
                if let text {
                    restore(text)
                }
            }
        } message: {
            Text("The current text is replaced. You can undo it in the editor.")
        }
        .task {
            do {
                text = try await FileVersionHistory.text(of: version)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// The toolbar button that opens `VersionHistoryView`.
struct VersionHistoryButton: View {
    let document: MarkdownDocument
    @State private var showing = false

    var body: some View {
        if let url = document.fileURL {
            Button {
                showing = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .help("Earlier versions of this document")
            .accessibilityIdentifier("VersionHistoryButton")
            .sheet(isPresented: $showing) {
                VersionHistoryView(fileURL: url) { document.text = $0 }
            }
        }
    }
}
