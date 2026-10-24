#if os(macOS)
    import AppKit
    import SwiftUI

    /// The find bar above the panes (issue #255). One per document window. It edits `FindState`.
    struct FindBar: View {
        @Bindable var find: FindState
        /// Opens Workspace Search with the query, when other notes match it.
        var otherNotes: OtherNotesMatches?
        var searchOtherNotes: (String) -> Void = { _ in }

        @FocusState private var focus: Field?
        private enum Field { case find, replace }

        var body: some View {
            VStack(spacing: 6) {
                findRow
                if find.showsReplace, find.canReplace {
                    replaceRow
                }
                hintRow
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .onKeyPress(.escape) {
                find.dismiss()
                return .handled
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("FindBar")
            .onChange(of: find.focusRequest) { _, _ in focusFindField() }
            .onAppear { focusFindField() }
            .onChange(of: find.query) { _, _ in find.queryChanged() }
            .onChange(of: find.inSelection) { _, _ in find.inSelectionChanged() }
            .onChange(of: find.replacement) { _, _ in find.replacementChanged() }
            .onChange(of: find.keepCase) { _, _ in find.replacementChanged() }
            .onChange(of: find.summary) { _, summary in announce(summary) }
        }

        // MARK: Rows

        private var findRow: some View {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find", text: $find.query.text)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .find)
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains([.command, .option]) {
                                find.selectAllMatches()
                            } else if press.modifiers.contains(.shift) {
                                find.previous()
                            } else {
                                find.next()
                            }
                            return .handled
                        }
                        .accessibilityIdentifier("FindField")
                    Text(find.summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(find.hasInvalidPattern ? Color.red : .secondary)
                        .accessibilityIdentifier("FindSummary")
                        .accessibilityLabel(find.summary.isEmpty ? "No search" : find.summary)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

                option("Aa", isOn: $find.query.matchCase, help: "Match case (off: a capital letter matches exactly)")
                option("ab", isOn: $find.query.wholeWord, help: "Whole word")
                option(".*", isOn: $find.query.isRegex, help: "Regular expression")
                if find.visiblePanes.contains(.editor) {
                    option("sel", isOn: $find.inSelection, help: "Find in selection")
                }

                if find.visiblePanes.count > 1 {
                    panePicker
                }

                Button { find.previous() } label: { Image(systemName: "chevron.up") }
                    .help("Previous match (⇧⌘G)")
                    .accessibilityLabel("Previous match")
                    .accessibilityIdentifier("FindPrevious")
                Button { find.next() } label: { Image(systemName: "chevron.down") }
                    .help("Next match (⌘G)")
                    .accessibilityLabel("Next match")
                    .accessibilityIdentifier("FindNext")

                if find.canReplace {
                    Button { find.showsReplace.toggle() } label: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .help("Show replace (⌥⌘F)")
                    .accessibilityLabel("Show replace")
                    .accessibilityIdentifier("FindToggleReplace")
                }
                Button { find.dismiss() } label: { Image(systemName: "xmark") }
                    .help("Close (Esc)")
                    .accessibilityLabel("Close find")
                    .accessibilityIdentifier("FindClose")
            }
            .buttonStyle(.borderless)
        }

        private var panePicker: some View {
            Picker("Search in", selection: Binding(get: { find.activePane }, set: { find.switchPane(to: $0) })) {
                ForEach(FindState.Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            .help("Next and Previous move through this pane")
            .accessibilityIdentifier("FindPanePicker")
        }

        private var replaceRow: some View {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                    TextField("Replace", text: $find.replacement)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .replace)
                        .onKeyPress(.return, phases: .down) { _ in
                            find.replaceCurrent()
                            return .handled
                        }
                        .accessibilityIdentifier("ReplaceField")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

                option("AA", isOn: $find.keepCase, help: "Keep case: Foo becomes Bar, FOO becomes BAR")
                Button("Replace") { find.replaceCurrent() }
                    .disabled(find.current == nil || find.activePane != .editor)
                    .accessibilityIdentifier("ReplaceButton")
                Button("Replace All") { find.replaceAll() }
                    .disabled(find.editorCount < 1 || !find.canReplace)
                    .accessibilityIdentifier("ReplaceAllButton")
            }
        }

        @ViewBuilder
        private var hintRow: some View {
            let hints = hintItems
            if !hints.isEmpty {
                HStack(spacing: 10) {
                    ForEach(hints) { hint in hint.view }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }

        private struct Hint: Identifiable {
            let id: String
            let view: AnyView
        }

        private var hintItems: [Hint] {
            var hints: [Hint] = []
            if find.hasInvalidPattern {
                hints.append(Hint(id: "invalid", view: AnyView(
                    Label("That isn't a valid regular expression.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("FindInvalidPattern")
                )))
            }
            if find.showsReplace, find.query.isRegex, find.canReplace {
                hints.append(Hint(id: "groups", view: AnyView(Text("Use $1, $2 for groups."))))
            }
            if find.showsReplace, let preview = find.replacementPreview, find.canReplace {
                hints.append(Hint(id: "preview", view: AnyView(
                    Text("Replaces with “\(preview.isEmpty ? "nothing" : preview)”")
                        .accessibilityIdentifier("ReplacePreview")
                )))
            }
            if let suggestion = find.suggestion {
                hints.append(Hint(id: "suggestion", view: AnyView(
                    HStack(spacing: 0) {
                        Text("Did you mean ")
                        Button("“\(suggestion)”") { find.query.text = suggestion }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("FindSuggestion")
                        Text("?")
                    }
                )))
            }
            if let otherNotes, otherNotes.count >= 1, !find.query.isEmpty, !find.query.isRegex {
                let label = otherNotes.count == 1 ? "1 other note" : "\(otherNotes.count) other notes"
                hints.append(Hint(id: "others", view: AnyView(
                    Button("\(label) match") { searchOtherNotes(find.query.text) }
                        .buttonStyle(.link)
                        .help("Search all workspaces for this")
                        .accessibilityIdentifier("FindOtherNotes")
                )))
            }
            return hints
        }

        // MARK: Pieces

        private func option(_ title: String, isOn: Binding<Bool>, help: String) -> some View {
            Toggle(isOn: isOn) {
                Text(title).font(.system(.caption, design: .monospaced).weight(.semibold))
            }
            .toggleStyle(.button)
            .help(help)
            .accessibilityLabel(help)
        }

        private func focusFindField() {
            // A field that has only just appeared ignores focus set in the same turn, so ask on the next one.
            // The field editor exists a beat after focus lands, so select its text on the turn after.
            DispatchQueue.main.async {
                focus = .find
                DispatchQueue.main.async {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            }
        }

        private func announce(_ summary: String) {
            guard !summary.isEmpty else { return }
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: summary,
                    .priority: NSAccessibilityPriorityLevel.low.rawValue,
                ]
            )
        }
    }

    /// How many other notes in the user's workspaces match the query.
    struct OtherNotesMatches: Equatable {
        var count: Int
    }
#endif
