#if os(macOS)
    import AppKit
#else
    import UIKit
#endif
import SwiftUI

/// Fen's custom About window/screen — replaces the default system About panel on
/// macOS (via `CommandGroup(replacing: .appInfo)`) and doubles as an "About" entry
/// in iOS Settings, so both platforms share the same branding and content.
public struct AboutView: View {
    public init() {}

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Fen"
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    public var body: some View {
        content
        #if os(macOS)
        .padding(24)
        .frame(width: 360)
        #else
        .padding()
        .navigationTitle("About")
        #endif
    }

    private var content: some View {
        VStack(spacing: 16) {
            appIcon
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text(appName)
                    .font(.title)
                    .bold()
                Text("Version \(version) (\(build))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("A native Markdown editor for macOS and iOS —\nfast, minimal, and built for Apple Silicon.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(spacing: 8) {
                linkRow("Website", url: "https://zoharbabin.com/fen/")
                linkRow("Source Code", url: "https://github.com/zoharbabin/fen")
                linkRow("Report an Issue", url: "https://github.com/zoharbabin/fen/issues")
                linkRow("Release Notes", url: "https://github.com/zoharbabin/fen/releases")
                linkRow("Third-Party Licenses", url: "https://github.com/zoharbabin/fen/tree/master/LICENSE")
            }

            Divider()

            VStack(spacing: 4) {
                Text("Free and open source, released under the MIT License.")
                Text(
                    "Fen grew out of a full rewrite of MacDown by Tzu-ping Chung — an independent rewrite, not a fork."
                )
                Text("Also builds on Highlightr, highlight.js, MathJax, and Mermaid, and Mou's editor themes.")
                Text("© 2014 Tzu-ping Chung · © 2026 Zohar Babin")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        #if os(macOS)
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
        #else
            if let icon = UIImage(named: "AppIcon") {
                Image(uiImage: icon)
                    .resizable()
            } else {
                Image(systemName: "app")
                    .resizable()
            }
        #endif
    }

    private func linkRow(_ title: String, url: String) -> some View {
        Link(title, destination: URL(string: url)!)
            .font(.callout)
    }
}
