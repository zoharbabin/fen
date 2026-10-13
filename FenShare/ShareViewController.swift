import UIKit
import UniformTypeIdentifiers

/// The Share Extension (issue #43). It takes the text or web address you share, leaves it as a `.md`
/// file in Fen's App Group inbox, and closes. Fen turns the file into a document the next time it
/// opens. This makes no network call and never opens Fen's documents.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        Task { await save() }
    }

    private func save() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        guard let inbox = SharedTextInbox.standard else {
            return fail("Fen's shared storage isn't available. Open Fen once, then try again.")
        }
        do {
            guard let text = await Self.text(from: items), try inbox.add(text) != nil else {
                return fail("There was no text to save.")
            }
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            fail("That text is too large to save.")
        }
    }

    private func fail(_ message: String) {
        let alert = UIAlertController(title: "Couldn't save to Fen", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        })
        present(alert, animated: true)
    }

    /// Text first, then a web address as a Markdown link.
    private static func text(from items: [NSExtensionItem]) async -> String? {
        for item in items {
            for provider in item.attachments ?? []
                where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = await load(provider, UTType.plainText) {
                    return text
                }
            }
        }
        for item in items {
            let title = item.attributedContentText?.string ?? item.attributedTitle?.string
            for provider in item.attachments ?? []
                where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                guard let address = await load(provider, UTType.url) else { continue }
                let label = (title?.isEmpty == false ? title : nil) ?? address
                return "[\(label)](\(address))"
            }
        }
        return nil
    }

    private static func load(_ provider: NSItemProvider, _ type: UTType) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier) { item, _ in
                switch item {
                case let text as String: continuation.resume(returning: text)
                case let url as URL where type == .url: continuation.resume(returning: url.absoluteString)
                case let url as URL: continuation.resume(returning: try? String(contentsOf: url, encoding: .utf8))
                case let data as Data: continuation.resume(returning: String(data: data, encoding: .utf8))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }
}
