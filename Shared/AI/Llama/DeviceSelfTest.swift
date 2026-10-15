#if DEBUG && canImport(llama)
    import Darwin
    import Foundation

    /// A debug-only check that runs one catalog model on the device it is installed on and prints
    /// what it measured (issue #234). `scripts/test-models-device.sh` copies the file into the app,
    /// launches it with `FEN_MODEL_SELFTEST=<model id>` and reads the lines that start with
    /// `SELFTEST`. A release build has none of this code.
    public enum DeviceSelfTest {
        public static func runIfRequested() {
            guard let id = ProcessInfo.processInfo.environment["FEN_MODEL_SELFTEST"] else { return }
            Task.detached {
                await run(modelID: id)
                if let model = ModelCatalog.model(id: id) {
                    try? ModelStore(home: .standard).remove(model)
                    report("deleted the copy of \(model.fileName)")
                }
                exit(0)
            }
        }

        private static func report(_ text: String) {
            print("SELFTEST \(text)")
            fflush(stdout)
        }

        private static func peakMegabytes() -> Int {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return status == KERN_SUCCESS ? Int(info.ledger_phys_footprint_peak / 1_048_576) : -1
        }

        private static func state() -> String {
            "thermal \(ProcessInfo.processInfo.thermalState.rawValue) peak \(peakMegabytes()) MB"
        }

        private static func run(modelID: String) async {
            let home = FenHome.standard
            report("models folder \(home.modelsDirectory.path)")
            report("memory \(ProcessInfo.processInfo.physicalMemory / 1_048_576) MB, \(state())")
            guard let model = ModelCatalog.model(id: modelID) else { return report("unknown model \(modelID)") }
            let store = ModelStore(home: home)
            guard store.isInstalled(model), let file = try? store.fileURL(for: model) else {
                return report("\(model.fileName) is not installed at the exact size")
            }
            do {
                try ModelStore.checkDevice(for: model)
            } catch {
                return report("device check refused it: \(error.localizedDescription)")
            }
            report("device check allows \(model.displayName)")
            let start = ContinuousClock.now
            if model.role == .embedding {
                guard let provider = LlamaEmbeddingProvider(model: model, file: file) else {
                    return report("the model did not load, \(state())")
                }
                report("loaded in \(ContinuousClock.now - start), \(state())")
                let began = ContinuousClock.now
                for text in ["Water the tomatoes early in the morning.", "Riega los tomates por la mañana."] {
                    let vector = try? await provider.embed(text)
                    report("embedded \(vector?.count ?? 0) values in \(ContinuousClock.now - began), \(state())")
                }
            } else {
                let provider = LlamaAnswerProvider(model: model, file: file)
                let note = AIContextItem(
                    workspaceID: nil,
                    label: "vault.md",
                    text: "The vault code word is PELICAN-42."
                )
                var first: Duration?
                var text = ""
                do {
                    for try await piece in provider.send(prompt: "What is the vault code word?", context: [note]) {
                        if first == nil {
                            first = ContinuousClock.now - start
                        }
                        text += piece
                    }
                } catch {
                    report("answer failed: \(error.localizedDescription), \(state())")
                }
                report(
                    "first text after \(first.map { "\($0)" } ?? "never"), all done in \(ContinuousClock.now - start)"
                )
                report("answer: \(text)")
                report("answer is right: \(text.contains("PELICAN-42")), \(state())")
            }
        }
    }
#endif
