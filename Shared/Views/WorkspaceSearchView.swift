import SwiftUI

/// Where a search from the Workspaces window looks.
enum WorkspaceSearchScope: Hashable {
    case workspace
    case all
}

/// Results of a search across the workspace indexes (issue #35). Searching reads the indexes only,
/// never the files, so nothing needs to be open.
struct WorkspaceSearchView: View {
    let library: WorkspaceLibrary
    let query: String
    let scope: WorkspaceScope
    let origin: SearchOrigin?
    let showsWorkspace: Bool
    let open: (SearchResult) -> Void

    @State private var results: [SearchResult] = []
    @State private var searched = false

    private struct Request: Equatable {
        let query: String
        let scope: WorkspaceScope
        let revision: Int
    }

    var body: some View {
        content
            .task(id: Request(query: query, scope: scope, revision: library.search.revision)) {
                // A debounce that a new keystroke cancels. It waits out typing, not another task.
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                let found = await library.search(query, scope: scope, origin: origin)
                guard !Task.isCancelled else { return }
                results = found
                searched = true
            }
    }

    @ViewBuilder
    private var content: some View {
        if !searched {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            ContentUnavailableView {
                Label("No matches", systemImage: "magnifyingglass")
            } description: {
                Text(emptyHint)
            }
        } else {
            List(results) { result in
                ResultRow(result: result, showsWorkspace: showsWorkspace)
                    .contentShape(Rectangle())
                    .onTapGesture(count: tapsToOpen) { open(result) }
                    .contextMenu { Button("Open") { open(result) } }
            }
        }
    }

    private var emptyHint: String {
        let indexing = library.workspaces.contains {
            if case .indexing = library.indexStatus(for: $0.id).phase {
                return true
            }
            return false
        }
        return indexing
            ? "Fen is still indexing. Results can appear as it finishes."
            : "Nothing matches \"\(query)\". Try other words or a shorter query."
    }

    private var tapsToOpen: Int {
        #if os(macOS)
            2
        #else
            1
        #endif
    }
}

private struct ResultRow: View {
    let result: SearchResult
    let showsWorkspace: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(result.fileName, systemImage: "doc.text").font(.body)
                Spacer()
                if result.match == .meaning {
                    Text("Similar meaning").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(location)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !result.snippet.isEmpty {
                Text(result.snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var location: String {
        var parts: [String] = []
        if showsWorkspace {
            parts.append(result.workspaceName)
        }
        let folder = (result.relativePath as NSString).deletingLastPathComponent
        if !folder.isEmpty {
            parts.append(folder)
        }
        if !result.heading.isEmpty {
            parts.append(result.heading)
        }
        return parts.joined(separator: " · ")
    }
}
