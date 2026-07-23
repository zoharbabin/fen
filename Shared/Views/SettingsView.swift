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
                    Text("\(prefs.editorFontName), \(Int(prefs.fontSize))pt")
                        .foregroundStyle(.secondary)
                }
                Stepper(
                    "Font Size: \(Int(prefs.fontSize)) (applies to editor and preview)",
                    value: $prefs.fontSize,
                    in: Preferences.minFontSize ... Preferences.maxFontSize
                )
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
                Toggle("Editor on right", isOn: $prefs.editorOnRight)
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
                Toggle("Autolinks", isOn: $prefs.extensionAutolink)
                Toggle("Strikethrough", isOn: $prefs.extensionStrikethrough)
                Toggle("Highlight", isOn: $prefs.extensionHighlight)
                Toggle("Footnotes", isOn: $prefs.extensionFootnotes)
                Toggle("Alerts", isOn: $prefs.extensionAlerts)
            }

            Section("Processing") {
                Toggle("SmartyPants", isOn: $prefs.extensionSmartyPants)
                Toggle("Update preview instantly (skip typing delay)", isOn: $prefs.markdownManualRender)
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

    private var themeFamilyNames: [String] {
        HTMLComposer.availableThemeFamilyNames()
    }

    var body: some View {
        Form {
            Section("Preview Style") {
                Picker("Theme", selection: $prefs.htmlStyleName) {
                    ForEach(themeFamilyNames, id: \.self) { family in
                        themeRow(family).tag(family)
                    }
                }
                Picker("Appearance", selection: $prefs.previewAppearanceMode) {
                    Text("Follow System").tag(PreviewAppearanceMode.system)
                    Text("Light").tag(PreviewAppearanceMode.light)
                    Text("Dark").tag(PreviewAppearanceMode.dark)
                }
            }

            Section("Print / PDF Theme") {
                Picker("Theme", selection: $prefs.printStyleName) {
                    Text("Same as Preview").tag(String?.none)
                    ForEach(themeFamilyNames, id: \.self) { family in
                        themeRow(family).tag(String?.some(family))
                    }
                }
                Picker("Appearance", selection: $prefs.printAppearanceMode) {
                    Text("Same as Preview").tag(PreviewAppearanceMode?.none)
                    Text("Follow System").tag(PreviewAppearanceMode?.some(.system))
                    Text("Light").tag(PreviewAppearanceMode?.some(.light))
                    Text("Dark").tag(PreviewAppearanceMode?.some(.dark))
                }
            }

            Section("Custom CSS") {
                Toggle("Layer custom CSS on the preview", isOn: $prefs.customCSSEnabled)
                if prefs.customCSSEnabled {
                    TextEditor(text: $prefs.customCSS)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                    Text("\(prefs.customCSS.count)/\(HTMLComposer.customCSSCharacterLimit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    Picker("Highlighting theme", selection: $prefs.htmlHighlightingThemeName) {
                        ForEach(HTMLComposer.availableHighlightThemeFamilyNames(), id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    Toggle("Show line numbers in code blocks", isOn: $prefs.htmlLineNumbers)
                }
                Toggle("Show copy button on code blocks", isOn: $prefs.htmlCopyButton)
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

    private func themeRow(_ family: String) -> some View {
        HStack {
            if let colors = HTMLComposer.themeSwatchColors(forFamily: family) {
                VStack(spacing: 0) {
                    Rectangle().fill(colors.background).frame(width: 16, height: 8)
                    Rectangle().fill(colors.text).frame(width: 16, height: 8)
                }
                .overlay(Rectangle().strokeBorder(.secondary, lineWidth: 0.5))
            }
            Text(family)
        }
    }
}
