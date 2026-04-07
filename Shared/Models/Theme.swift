import Foundation
#if canImport(AppKit)
import AppKit
public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
#else
import UIKit
public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
#endif

/// Represents a parsed editor theme from a `.style` file.
/// Format: blocks of element name followed by key-value properties.
public struct EditorTheme: Sendable {
    public struct Style: Sendable {
        public var foreground: PlatformColor?
        public var background: PlatformColor?
        public var fontStyle: FontStyle
        public var fontSize: CGFloat?

        public enum FontStyle: Sendable {
            case regular
            case bold
            case italic
            case boldItalic
        }

        public init(
            foreground: PlatformColor? = nil,
            background: PlatformColor? = nil,
            fontStyle: FontStyle = .regular,
            fontSize: CGFloat? = nil
        ) {
            self.foreground = foreground
            self.background = background
            self.fontStyle = fontStyle
            self.fontSize = fontSize
        }
    }

    public let name: String
    public let editorForeground: PlatformColor
    public let editorBackground: PlatformColor
    public let caretColor: PlatformColor
    public let selectionForeground: PlatformColor?
    public let selectionBackground: PlatformColor?
    public let elementStyles: [String: Style]

    /// Loads a theme from a `.style` file in the Themes resource bundle.
    public static func load(named name: String) -> EditorTheme? {
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: "style",
            subdirectory: "Themes"
        ) else {
            return nil
        }
        return load(from: url, name: name)
    }

    /// Loads all available themes from the Themes resource directory.
    public static func availableThemes() -> [String] {
        guard let url = Bundle.main.url(forResource: "Themes", withExtension: nil),
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: url,
                  includingPropertiesForKeys: nil
              ) else {
            return []
        }
        return contents
            .filter { $0.pathExtension == "style" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    public static func load(from url: URL, name: String) -> EditorTheme? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return parse(content, name: name)
    }

    // MARK: - Parser

    static func parse(_ content: String, name: String) -> EditorTheme {
        var elementStyles: [String: Style] = [:]
        var editorForeground: PlatformColor = .white
        var editorBackground: PlatformColor = .black
        var caretColor: PlatformColor = .white
        var selectionFg: PlatformColor?
        var selectionBg: PlatformColor?

        var currentElement: String?
        var currentFg: PlatformColor?
        var currentBg: PlatformColor?
        var currentFontStyle: Style.FontStyle = .regular
        var currentFontSize: CGFloat?

        func flushElement() {
            guard let element = currentElement else { return }
            switch element {
            case "editor":
                if let fg = currentFg { editorForeground = fg }
                if let bg = currentBg { editorBackground = bg }
            case "editor-selection":
                selectionFg = currentFg
                selectionBg = currentBg
            default:
                elementStyles[element] = Style(
                    foreground: currentFg,
                    background: currentBg,
                    fontStyle: currentFontStyle,
                    fontSize: currentFontSize
                )
            }
            currentFg = nil
            currentBg = nil
            currentFontStyle = .regular
            currentFontSize = nil
        }

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.contains(":") {
                let parts = trimmed.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespaces)

                switch key {
                case "foreground":
                    currentFg = PlatformColor(hex: value)
                case "background":
                    currentBg = PlatformColor(hex: value)
                case "caret":
                    caretColor = PlatformColor(hex: value) ?? caretColor
                case "font-style":
                    switch value.lowercased() {
                    case "bold": currentFontStyle = .bold
                    case "italic": currentFontStyle = .italic
                    case "bold italic", "bold-italic": currentFontStyle = .boldItalic
                    default: currentFontStyle = .regular
                    }
                case "font-size":
                    let numeric = value.replacingOccurrences(of: "px", with: "")
                    currentFontSize = CGFloat(Double(numeric) ?? 0)
                default:
                    break
                }
            } else {
                // New element block
                flushElement()
                currentElement = trimmed
            }
        }
        flushElement()

        return EditorTheme(
            name: name,
            editorForeground: editorForeground,
            editorBackground: editorBackground,
            caretColor: caretColor,
            selectionForeground: selectionFg,
            selectionBackground: selectionBg,
            elementStyles: elementStyles
        )
    }
}

// MARK: - Color Hex Extension

extension PlatformColor {
    convenience init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6,
              let rgb = UInt64(cleaned, radix: 16) else {
            return nil
        }
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
