import SwiftUI

/// Lists the documents that link to the open one (issue #36), under the outline. It reads the
/// local search index, so it also lists files that are not open. It shows nothing when no
/// document links here, or when the file sits in no workspace.
struct BacklinksSection: View {
    let fileURL: URL?
    let library: WorkspaceLibrary
    let open: (URL) -> Void
    @State private var backlinks: [Backlink] = []

    private struct Key: Equatable {
        let url: URL?
        let indexRevision: Int
        let listingRevision: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            if !backlinks.isEmpty {
                Divider()
                Text("Linked from")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                List(backlinks) { link in
                    Button {
                        if let url = library.fileURL(workspaceID: link.workspaceID, relativePath: link.relativePath) {
                            open(url)
                        }
                    } label: {
                        Label(link.title, systemImage: "arrow.turn.up.left")
                            .lineLimit(1)
                            .help(link.relativePath)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
                .frame(height: min(CGFloat(backlinks.count) * 30 + 12, 180))
            }
        }
        .accessibilityIdentifier("BacklinksSection")
        .task(id: Key(
            url: fileURL, indexRevision: library.search.revision, listingRevision: library.listingRevision
        )) {
            backlinks = await library.backlinks(to: fileURL)
        }
    }
}
