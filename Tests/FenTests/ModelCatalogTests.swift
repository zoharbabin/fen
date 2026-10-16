@testable import FenCore
import Foundation
import Testing

@Suite("The model catalog (issue #234)")
struct ModelCatalogTests {
    @Test("every entry pins a commit, a hash and a size, and only talks to https")
    func entriesArePinned() throws {
        for model in ModelCatalog.all {
            #expect(model.url.scheme == "https", "\(model.id)")
            #expect(model.host == "huggingface.co", "\(model.id)")
            let parts = model.url.pathComponents
            let commit = try #require(parts.drop { $0 != "resolve" }.dropFirst().first)
            #expect(commit.count == 40 && commit.allSatisfy(\.isHexDigit), "\(model.id) is not pinned to a commit")
            #expect(model.sha256.count == 64 && model.sha256.allSatisfy(\.isHexDigit), "\(model.id)")
            #expect(model.byteCount > 0)
            #expect(model.fileName == model.url.lastPathComponent)
            #expect(!model.fileName.contains("/"))
            #expect(model.licenseName == "Apache-2.0")
            #expect(!model.languages.isEmpty)
            #expect(model.redirectHostSuffixes == ["huggingface.co", "hf.co"])
        }
    }

    @Test("ids and file names are unique, and both roles have a choice")
    func unique() {
        #expect(Set(ModelCatalog.all.map(\.id)).count == ModelCatalog.all.count)
        #expect(Set(ModelCatalog.all.map(\.fileName)).count == ModelCatalog.all.count)
        #expect(ModelCatalog.models(for: .embedding).count >= 2)
        #expect(ModelCatalog.models(for: .answer).count >= 2)
        #expect(ModelCatalog.model(id: "gemma-4-e2b-q4")?.kind == .gemma4)
        #expect(ModelCatalog.model(id: "nope") == nil)
    }

    @Test("the big answer models stay off phones")
    func phones() {
        #expect(!ModelCatalog.gemma4E4B.platforms.contains(.iPhone))
        #expect(!ModelCatalog.gemma4E2B.platforms.contains(.iPhone))
        #expect(ModelCatalog.embeddingGemma2.platforms.contains(.iPhone))
        #expect(ModelCatalog.gemma4E2BMobile.platforms.contains(.iPhone))
    }

    @Test("a download may be handed to Hugging Face's network and to nowhere else")
    func redirects() throws {
        let model = ModelCatalog.embeddingGemma2
        #expect(try model.allowsRedirect(to: #require(URL(string: "https://us.aws.cdn.hf.co/xet-bridge-us/a?x=1"))))
        #expect(try !model.allowsRedirect(to: #require(URL(string: "https://example.com/a"))))
        #expect(try !model.allowsRedirect(to: #require(URL(string: "http://us.aws.cdn.hf.co/a"))))
        #expect(model.consentText.contains("huggingface.co") && model.consentText.contains("hf.co"))
    }

    @Test("the license texts for the weights and the runtime ship in LICENSE/")
    func licenseFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("LICENSE")
        let weights = try String(
            contentsOf: root.appendingPathComponent("model-weights-apache-2.0.txt"),
            encoding: .utf8
        )
        #expect(weights.contains("Apache License"))
        let runtime = try String(contentsOf: root.appendingPathComponent("llamacpp.txt"), encoding: .utf8)
        #expect(runtime.contains("MIT License"))
    }

    @Test("a device sold as 8 GB can run every model that is meant for a phone or an iPad")
    func eightGigabyteDeviceIsEnough() {
        // An iPhone 15 Pro Max (8 GB) reports 7655 MB. The run on that phone found a catalog that asked for 8 GiB.
        let reported = Int64(7655) * 1_048_576
        for model in ModelCatalog.all where model.platforms.contains(.iPhone) || model.platforms.contains(.iPad) {
            #expect(model.minimumMemory <= reported, "\(model.displayName) needs more than an 8 GB device reports")
        }
    }
}
