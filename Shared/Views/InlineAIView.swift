import SwiftUI

/// The toolbar button for "Ask AI" and "Enrich" (issue #6). It opens a panel for the selection, or
/// the paragraph at the caret.
struct InlineAIButton: View {
    @Bindable var controller: InlineAIController
    let document: MarkdownDocument
    let caret: EditorCaret

    var body: some View {
        Button {
            controller.present(target: EditorTarget.resolve(in: document.text, selected: caret.range))
        } label: {
            Image(systemName: "sparkles")
        }
        .help("Ask AI to rewrite or expand your text, or enrich bullets from your notes")
        .accessibilityIdentifier("InlineAIButton")
        .popover(isPresented: $controller.isPresented, arrowEdge: .bottom) {
            InlineAIPanel(controller: controller, document: document)
        }
    }
}

private struct InlineAIPanel: View {
    @Bindable var controller: InlineAIController
    let document: MarkdownDocument
    @State private var instruction = ""
    @State private var scope = InlineScope.selection
    @Bindable private var preferences = Preferences.shared

    private let presets = ["Rewrite", "Expand", "Summarize", "Make it shorter", "Fix grammar"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Action", selection: $controller.action) {
                ForEach(InlineAIController.Action.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(controller.isWorking)
            Text(targetSummary).font(.caption).foregroundStyle(.secondary)
            if let reason = unavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            } else if controller.target != nil {
                controls
            }
            status
            if let disclosure = AIService.shared.disclosure {
                Label(disclosure, systemImage: "network").font(.caption).foregroundStyle(.orange)
            }
            Toggle("Preview before applying", isOn: $preferences.inlineAIPreviewFirst)
                .font(.caption)
                .help("Show the result and wait for your click. Undo works either way.")
        }
        .padding(14)
        .frame(width: 360)
        .accessibilityIdentifier("InlineAIPanel")
    }

    private var unavailableReason: String? {
        controller.target == nil ? nil : controller.unavailableReason(
            fileURL: document.fileURL,
            action: controller.action
        )
    }

    private var targetSummary: String {
        guard let target = controller.target else {
            return "Select some text, or put the cursor in a paragraph."
        }
        let what = target.kind == .selection ? "Selected text" : "Paragraph at the cursor"
        return "\(what): \(target.text.count) characters"
    }

    @ViewBuilder
    private var controls: some View {
        switch controller.action {
        case .rewrite:
            presetButtons
            TextField("What should Fen do?", text: $instruction)
                .textFieldStyle(.roundedBorder)
                .onSubmit(runRewrite)
                .disabled(controller.isWorking)
            Picker("Context", selection: $scope) {
                ForEach(InlineScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(controller.isWorking)
            if scope == .document {
                Text("The whole document is sent for this call.").font(.caption).foregroundStyle(.secondary)
            }
            runRow("Ask AI", enabled: !instruction.trimmingCharacters(in: .whitespaces).isEmpty, run: runRewrite)
        case .enrich:
            Text(
                "Adds facts from your other notes under each selected bullet, with a link to the source. "
                    + "Your text stays as it is."
            )
            .font(.callout)
            runRow("Enrich", enabled: true) {
                controller.enrich(document: document.text, fileURL: document.fileURL)
            }
        }
    }

    private var presetButtons: some View {
        HStack {
            ForEach(presets, id: \.self) { preset in
                Button(preset) { instruction = preset }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .disabled(controller.isWorking)
    }

    private func runRow(_ title: String, enabled: Bool, run: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            if controller.isWorking {
                ProgressView().controlSize(.small)
                Button("Stop") { controller.cancel() }
            } else {
                Button(title, action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(!enabled)
            }
        }
    }

    private func runRewrite() {
        controller.rewrite(instruction: instruction, scope: scope, document: document.text, fileURL: document.fileURL)
    }

    @ViewBuilder
    private var status: some View {
        switch controller.phase {
        case .idle:
            EmptyView()
        case .working:
            if !controller.streamed.isEmpty {
                resultBox(controller.streamed)
            }
        case let .preview(proposal):
            Text("Result").font(.caption.bold())
            resultBox(proposal.replacement)
            HStack {
                Spacer()
                Button("Discard") { controller.discard() }
                Button("Apply") { controller.applyPreview() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        case let .applied(summary):
            Label(summary, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green)
        case let .notice(text):
            Label(text, systemImage: "info.circle").font(.callout)
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon").font(.callout).foregroundStyle(.red)
        }
    }

    private func resultBox(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}
