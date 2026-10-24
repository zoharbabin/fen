import SwiftUI

public extension Notification.Name {
    /// Posted by the "Toggle Preview" menu command (`ViewCommands`) to show or hide the preview pane
    /// of the focused `SplitEditorView` (issue #42).
    static let togglePreview = Notification.Name("togglePreview")
    /// Posted by the "Toggle Editor" menu command (`ViewCommands`). Mirrors `.togglePreview`.
    static let toggleEditor = Notification.Name("toggleEditor")
}

extension SplitEditorView {
    enum ViewMode: String, CaseIterable {
        case split = "Split"
        case editorOnly = "Editor"
        case previewOnly = "Preview"
    }
}

/// Which panes show for a view mode at a given width (issue #42). A phone, or an iPad in Slide Over
/// or a narrow Split View, is too narrow for two panes, so it shows one at a time.
extension SplitEditorView.ViewMode {
    /// The modes the picker offers.
    static func available(compactWidth: Bool) -> [Self] {
        compactWidth ? [.editorOnly, .previewOnly] : allCases
    }

    /// What is on screen. `.split` falls back to the editor when the window is narrow. The stored
    /// mode doesn't change, so the window gets its two panes back when it widens again.
    func shown(compactWidth: Bool) -> Self {
        compactWidth && self == .split ? .editorOnly : self
    }

    /// Whether the editor is on screen. Edits from Properties and Ask AI go through the editor, so
    /// they are off when it isn't.
    func showsEditor(compactWidth: Bool) -> Bool {
        shown(compactWidth: compactWidth) != .previewOnly
    }

    /// The mode after "Toggle Preview": hide the preview if it shows, otherwise show it.
    func afterTogglingPreview(compactWidth: Bool) -> Self {
        switch shown(compactWidth: compactWidth) {
        case .split, .previewOnly: .editorOnly
        case .editorOnly: compactWidth ? .previewOnly : .split
        }
    }

    /// The mode after "Toggle Editor": hide the editor if it shows, otherwise show it.
    func afterTogglingEditor(compactWidth: Bool) -> Self {
        switch shown(compactWidth: compactWidth) {
        case .split, .editorOnly: .previewOnly
        case .previewOnly: compactWidth ? .editorOnly : .split
        }
    }
}

extension SplitEditorView {
    /// Narrow windows show one pane at a time (issue #42). macOS windows are never narrow in this sense.
    var isCompactWidth: Bool {
        #if os(iOS)
            horizontalSizeClass == .compact
        #else
            false
        #endif
    }

    var isEditorShown: Bool {
        viewMode.showsEditor(compactWidth: isCompactWidth)
    }

    /// The Editor/Preview/Split picker. A narrow screen has `compactPaneBar` instead.
    @ViewBuilder
    var viewModePicker: some View {
        if !isCompactWidth {
            Picker("View", selection: shownViewMode) {
                ForEach(ViewMode.available(compactWidth: false), id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("ViewModePicker")
        }
    }

    /// Switches a narrow screen between the editor and the preview. It sits at the bottom, in the open,
    /// because the toolbar folds whatever doesn't fit into a "More" menu where nobody finds it.
    @ViewBuilder
    var compactPaneBar: some View {
        if isCompactWidth {
            Picker("View", selection: shownViewMode) {
                ForEach(ViewMode.available(compactWidth: true), id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityIdentifier("ViewModePicker")
        }
    }

    /// The picker shows what is on screen, and writes the chosen mode through.
    var shownViewMode: Binding<ViewMode> {
        Binding(
            get: { viewMode.shown(compactWidth: isCompactWidth) },
            set: { viewMode = $0 }
        )
    }
}

/// Runs the View menu commands (`ViewCommands`) against one `SplitEditorView`. Focus Mode and Live Preview
/// flip a preference every window shares, so only the window in use runs them (`HostWindowProbe`). Two
/// windows would flip it twice. Outline, Preview and Editor change this window's own state, so every window
/// runs them.
struct ViewCommandReceivers: ViewModifier {
    let outline: () -> Void
    let focusMode: () -> Void
    let livePreview: () -> Void
    let preview: () -> Void
    let editor: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: DocumentOutline.toggleOutlineNotification)) { _ in
                outline()
            }
            .onWindowCommand(FocusModeEditing.toggleFocusModeNotification, perform: focusMode)
            .onWindowCommand(LivePreviewEditing.toggleLivePreviewNotification, perform: livePreview)
            .onReceive(NotificationCenter.default.publisher(for: .togglePreview)) { _ in preview() }
            .onReceive(NotificationCenter.default.publisher(for: .toggleEditor)) { _ in editor() }
    }
}

extension SplitEditorView {
    /// A phone in portrait cuts off what doesn't fit the bar, so there the actions go into the More menu.
    var toolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
            horizontalSizeClass == .compact ? .secondaryAction : .automatic
        #else
            .automatic
        #endif
    }
}
