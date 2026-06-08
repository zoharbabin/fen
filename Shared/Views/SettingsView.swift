import SwiftUI

public struct SettingsView: View {
    public init() {}

    public var body: some View {
        #if os(macOS)
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsTab()
            }
            Tab("Editor", systemImage: "pencil") {
                EditorSettingsTab()
            }
            Tab("Markdown", systemImage: "doc.text") {
                MarkdownSettingsTab()
            }
            Tab("Rendering", systemImage: "eye") {
                RenderingSettingsTab()
            }
        }
        .frame(width: 500)
        #else
        NavigationStack {
            Form {
                NavigationLink("General") { GeneralSettingsTab() }
                NavigationLink("Editor") { EditorSettingsTab() }
                NavigationLink("Markdown") { MarkdownSettingsTab() }
                NavigationLink("Rendering") { RenderingSettingsTab() }
            }
            .navigationTitle("Settings")
        }
        #endif
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    private let prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Suppress untitled document on launch", isOn: binding(\.suppressesUntitledDocumentOnLaunch))
                Toggle("Create file for link targets", isOn: binding(\.createFileForLinkTarget))
                Toggle("Ensure newline at end of file", isOn: binding(\.editorEnsuresNewlineAtEndOfFile))
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .padding()
        #else
        .navigationTitle("General")
        #endif
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
        Binding(get: { prefs[keyPath: keyPath] }, set: { prefs[keyPath: keyPath] = $0 })
    }
}

// MARK: - Editor

struct EditorSettingsTab: View {
    private let prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Font") {
                HStack {
                    Text("Font")
                    Spacer()
                    Text("\(prefs.editorFontName), \(Int(prefs.editorFontSize))pt")
                        .foregroundStyle(.secondary)
                }
                Stepper("Font Size: \(Int(prefs.editorFontSize))", value: fontSizeBinding, in: 8...48)
            }

            Section("Theme") {
                Picker("Editor Theme", selection: editorStyleBinding) {
                    ForEach(MarkdownSyntaxHighlighter.availableThemes, id: \.self) { theme in
                        Text(theme).tag(theme)
                    }
                }
            }

            Section("Layout") {
                HStack {
                    Text("Horizontal Inset")
                    Slider(value: horizontalInsetBinding, in: 0...50)
                }
                HStack {
                    Text("Vertical Inset")
                    Slider(value: verticalInsetBinding, in: 0...80)
                }
                HStack {
                    Text("Line Spacing")
                    Slider(value: lineSpacingBinding, in: 0...20)
                }
                Toggle("Limit editor width", isOn: binding(\.editorWidthLimited))
                if prefs.editorWidthLimited {
                    Stepper("Max Width: \(Int(prefs.editorMaximumWidth))", value: maxWidthBinding, in: 400...2000, step: 50)
                }
            }

            Section("Behavior") {
                Toggle("Auto-increment numbered lists", isOn: binding(\.editorAutoIncrementNumberedLists))
                Toggle("Convert tabs to spaces", isOn: binding(\.editorConvertTabs))
                Toggle("Insert prefix in block", isOn: binding(\.editorInsertPrefixInBlock))
                Toggle("Complete matching characters", isOn: binding(\.editorCompleteMatchingCharacters))
                Toggle("Sync scrolling with preview", isOn: binding(\.editorSyncScrolling))
                Toggle("Scroll past end", isOn: binding(\.editorScrollsPastEnd))
                Toggle("Show word count", isOn: binding(\.editorShowWordCount))
                #if os(macOS)
                Toggle("Smart Home key", isOn: binding(\.editorSmartHome))
                #endif
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .padding()
        #else
        .navigationTitle("Editor")
        #endif
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
        Binding(get: { prefs[keyPath: keyPath] }, set: { prefs[keyPath: keyPath] = $0 })
    }

    private var fontSizeBinding: Binding<CGFloat> {
        Binding(get: { prefs.editorFontSize }, set: { prefs.editorFontSize = $0 })
    }

    private var horizontalInsetBinding: Binding<CGFloat> {
        Binding(get: { prefs.editorHorizontalInset }, set: { prefs.editorHorizontalInset = $0 })
    }

    private var verticalInsetBinding: Binding<CGFloat> {
        Binding(get: { prefs.editorVerticalInset }, set: { prefs.editorVerticalInset = $0 })
    }

    private var lineSpacingBinding: Binding<CGFloat> {
        Binding(get: { prefs.editorLineSpacing }, set: { prefs.editorLineSpacing = $0 })
    }

    private var maxWidthBinding: Binding<CGFloat> {
        Binding(get: { prefs.editorMaximumWidth }, set: { prefs.editorMaximumWidth = $0 })
    }

    private var editorStyleBinding: Binding<String> {
        Binding(get: { prefs.editorStyleName }, set: { prefs.editorStyleName = $0 })
    }
}

// MARK: - Markdown

struct MarkdownSettingsTab: View {
    private let prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Extensions") {
                Toggle("Tables", isOn: binding(\.extensionTables))
                Toggle("Fenced code blocks", isOn: binding(\.extensionFencedCode))
                Toggle("Autolinks", isOn: binding(\.extensionAutolink))
                Toggle("Strikethrough", isOn: binding(\.extensionStrikethrough))
                Toggle("Underline", isOn: binding(\.extensionUnderline))
                Toggle("Superscript", isOn: binding(\.extensionSuperscript))
                Toggle("Highlight", isOn: binding(\.extensionHighlight))
                Toggle("Footnotes", isOn: binding(\.extensionFootnotes))
                Toggle("Quote", isOn: binding(\.extensionQuote))
                Toggle("Intra-emphasis", isOn: binding(\.extensionIntraEmphasis))
            }

            Section("Processing") {
                Toggle("SmartyPants", isOn: binding(\.extensionSmartyPants))
                Toggle("Manual render", isOn: binding(\.markdownManualRender))
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .padding()
        #else
        .navigationTitle("Markdown")
        #endif
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
        Binding(get: { prefs[keyPath: keyPath] }, set: { prefs[keyPath: keyPath] = $0 })
    }
}

// MARK: - Rendering

struct RenderingSettingsTab: View {
    private let prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Preview Style") {
                Picker("CSS Theme", selection: htmlStyleBinding) {
                    ForEach(HTMLComposer.availablePreviewStyles(), id: \.self) { style in
                        Text(style).tag(style)
                    }
                }
            }

            Section("Features") {
                Toggle("Detect front matter", isOn: binding(\.htmlDetectFrontMatter))
                Toggle("Task lists", isOn: binding(\.htmlTaskList))
                Toggle("Hard wrap", isOn: binding(\.htmlHardWrap))
                Toggle("Render table of contents", isOn: binding(\.htmlRendersTOC))
            }

            Section("Syntax Highlighting") {
                Toggle("Enable syntax highlighting", isOn: binding(\.htmlSyntaxHighlighting))
                if prefs.htmlSyntaxHighlighting {
                    TextField("Highlighting theme", text: highlightThemeBinding)
                    Toggle("Show line numbers", isOn: binding(\.htmlLineNumbers))
                }
            }

            Section("Math & Diagrams") {
                Toggle("MathJax", isOn: binding(\.htmlMathJax))
                if prefs.htmlMathJax {
                    Toggle("Inline $ delimiters", isOn: binding(\.htmlMathJaxInlineDollar))
                }
                Toggle("Mermaid diagrams", isOn: binding(\.htmlMermaid))
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .padding()
        #else
        .navigationTitle("Rendering")
        #endif
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
        Binding(get: { prefs[keyPath: keyPath] }, set: { prefs[keyPath: keyPath] = $0 })
    }

    private var htmlStyleBinding: Binding<String> {
        Binding(get: { prefs.htmlStyleName }, set: { prefs.htmlStyleName = $0 })
    }

    private var highlightThemeBinding: Binding<String> {
        Binding(get: { prefs.htmlHighlightingThemeName }, set: { prefs.htmlHighlightingThemeName = $0 })
    }
}
