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
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Suppress untitled document on launch", isOn: $prefs.suppressesUntitledDocumentOnLaunch)
                Toggle("Create file for link targets", isOn: $prefs.createFileForLinkTarget)
                Toggle("Ensure newline at end of file", isOn: $prefs.editorEnsuresNewlineAtEndOfFile)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
            .padding()
        #else
            .navigationTitle("General")
        #endif
    }
}

// MARK: - Editor

struct EditorSettingsTab: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Font") {
                HStack {
                    Text("Font")
                    Spacer()
                    Text("\(prefs.editorFontName), \(Int(prefs.editorFontSize))pt")
                        .foregroundStyle(.secondary)
                }
                Stepper("Font Size: \(Int(prefs.editorFontSize))", value: $prefs.editorFontSize, in: 8 ... 48)
            }

            Section("Theme") {
                Picker("Editor Theme", selection: $prefs.editorStyleName) {
                    ForEach(MarkdownSyntaxHighlighter.availableThemes, id: \.self) { theme in
                        Text(theme).tag(theme)
                    }
                }
            }

            Section("Layout") {
                HStack {
                    Text("Horizontal Inset")
                    Slider(value: $prefs.editorHorizontalInset, in: 0 ... 50)
                }
                HStack {
                    Text("Vertical Inset")
                    Slider(value: $prefs.editorVerticalInset, in: 0 ... 80)
                }
                HStack {
                    Text("Line Spacing")
                    Slider(value: $prefs.editorLineSpacing, in: 0 ... 20)
                }
                Toggle("Limit editor width", isOn: $prefs.editorWidthLimited)
                if prefs.editorWidthLimited {
                    Stepper(
                        "Max Width: \(Int(prefs.editorMaximumWidth))",
                        value: $prefs.editorMaximumWidth,
                        in: 400 ... 2000,
                        step: 50
                    )
                }
            }

            Section("Behavior") {
                Toggle("Auto-increment numbered lists", isOn: $prefs.editorAutoIncrementNumberedLists)
                Toggle("Convert tabs to spaces", isOn: $prefs.editorConvertTabs)
                Toggle("Insert prefix in block", isOn: $prefs.editorInsertPrefixInBlock)
                Toggle("Complete matching characters", isOn: $prefs.editorCompleteMatchingCharacters)
                Toggle("Sync scrolling with preview", isOn: $prefs.editorSyncScrolling)
                Toggle("Scroll past end", isOn: $prefs.editorScrollsPastEnd)
                Toggle("Show word count", isOn: $prefs.editorShowWordCount)
                #if os(macOS)
                    Toggle("Smart Home key", isOn: $prefs.editorSmartHome)
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
}

// MARK: - Markdown

struct MarkdownSettingsTab: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Extensions") {
                Toggle("Tables", isOn: $prefs.extensionTables)
                Toggle("Fenced code blocks", isOn: $prefs.extensionFencedCode)
                Toggle("Autolinks", isOn: $prefs.extensionAutolink)
                Toggle("Strikethrough", isOn: $prefs.extensionStrikethrough)
                Toggle("Underline", isOn: $prefs.extensionUnderline)
                Toggle("Superscript", isOn: $prefs.extensionSuperscript)
                Toggle("Highlight", isOn: $prefs.extensionHighlight)
                Toggle("Footnotes", isOn: $prefs.extensionFootnotes)
                Toggle("Quote", isOn: $prefs.extensionQuote)
                Toggle("Intra-emphasis", isOn: $prefs.extensionIntraEmphasis)
            }

            Section("Processing") {
                Toggle("SmartyPants", isOn: $prefs.extensionSmartyPants)
                Toggle("Manual render", isOn: $prefs.markdownManualRender)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
            .padding()
        #else
            .navigationTitle("Markdown")
        #endif
    }
}

// MARK: - Rendering

struct RenderingSettingsTab: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Preview Style") {
                Picker("CSS Theme", selection: $prefs.htmlStyleName) {
                    ForEach(HTMLComposer.availablePreviewStyles(), id: \.self) { style in
                        Text(style).tag(style)
                    }
                }
            }

            Section("Features") {
                Toggle("Detect front matter", isOn: $prefs.htmlDetectFrontMatter)
                Toggle("Task lists", isOn: $prefs.htmlTaskList)
                Toggle("Hard wrap", isOn: $prefs.htmlHardWrap)
                Toggle("Render table of contents", isOn: $prefs.htmlRendersTOC)
            }

            Section("Syntax Highlighting") {
                Toggle("Enable syntax highlighting", isOn: $prefs.htmlSyntaxHighlighting)
                if prefs.htmlSyntaxHighlighting {
                    TextField("Highlighting theme", text: $prefs.htmlHighlightingThemeName)
                    Toggle("Show line numbers", isOn: $prefs.htmlLineNumbers)
                }
            }

            Section("Math & Diagrams") {
                Toggle("MathJax", isOn: $prefs.htmlMathJax)
                if prefs.htmlMathJax {
                    Toggle("Inline $ delimiters", isOn: $prefs.htmlMathJaxInlineDollar)
                }
                Toggle("Mermaid diagrams", isOn: $prefs.htmlMermaid)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
            .padding()
        #else
            .navigationTitle("Rendering")
        #endif
    }
}
