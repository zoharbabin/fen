#if os(macOS)
    import AppKit
    import SwiftUI

    /// Lets tools and agents on this Mac read your workspaces over MCP (issue #10). The server is off
    /// until you turn it on, listens on this Mac only, and every client needs its own token.
    struct MCPSettingsTab: View {
        private let controller: MCPController
        private let clients: MCPClientStore
        private let library: WorkspaceLibrary
        @Bindable private var preferences = Preferences.shared
        @State private var editing: ClientDraft?
        @State private var shownToken: IssuedToken?
        @State private var errorMessage: String?
        @State private var portText = ""

        init(
            controller: MCPController = .shared,
            clients: MCPClientStore = .shared,
            library: WorkspaceLibrary = .shared
        ) {
            self.controller = controller
            self.clients = clients
            self.library = library
        }

        var body: some View {
            Form {
                serverSection
                clientsSection
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .padding()
            .onAppear { portText = String(preferences.mcpPort) }
            .sheet(item: $editing) { draft in
                ClientEditor(draft: draft, workspaces: library.workspaces) { save($0) } cancel: { editing = nil }
            }
            .sheet(item: $shownToken) { issued in
                TokenSheet(issued: issued, port: preferences.mcpPort) { shownToken = nil }
            }
        }

        // MARK: - Server

        private var serverSection: some View {
            Section {
                Toggle("Let other tools connect", isOn: Binding(
                    get: { preferences.mcpServerEnabled },
                    set: { controller.setEnabled($0) }
                ))
                LabeledContent("Status") { Text(statusText).foregroundStyle(statusColor) }
                TextField("Port", text: $portText)
                    .disabled(controller.isRunning)
                    .onSubmit(applyPort)
                    .onChange(of: portText) { _, _ in applyPort() }
            } header: {
                Text("Server")
            } footer: {
                Text(
                    "Off by default. Only apps on this Mac can connect, and each needs a token from the list below. "
                        + "A workspace is shared only if you also turn on Agent access in its settings."
                )
            }
        }

        private func applyPort() {
            if let port = UInt16(portText), port >= 1024 {
                preferences.mcpPort = port
                errorMessage = nil
            } else if !portText.isEmpty {
                errorMessage = "Use a port from 1024 to 65535."
            }
        }

        private var statusText: String {
            switch controller.status {
            case .off: "Off"
            case let .running(port): "Listening on 127.0.0.1:\(port)"
            case let .failed(reason): reason
            }
        }

        private var statusColor: Color {
            switch controller.status {
            case .running: .green
            case .failed: .red
            case .off: .secondary
            }
        }

        // MARK: - Clients

        private var clientsSection: some View {
            Section {
                if let problem = clients.loadError {
                    Text(problem).foregroundStyle(.red)
                }
                if clients.clients.isEmpty {
                    Text("No client yet. Add one to get a token for a tool.").foregroundStyle(.secondary)
                }
                ForEach(clients.clients) { client in
                    row(client)
                }
                Button("Add Client", systemImage: "plus") { editing = ClientDraft() }
            } header: {
                Text("Clients")
            } footer: {
                Text(
                    "A client that proposes changes always waits for your approval, "
                        + "unless you wrote a rule for it in the workspace's settings."
                )
            }
        }

        private func row(_ client: MCPClient) -> some View {
            HStack {
                VStack(alignment: .leading) {
                    Text(client.name)
                    Text("\(client.level.title) · \(workspaceNames(client))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Actions", systemImage: "ellipsis.circle") {
                    Button("Edit…") { editing = ClientDraft(client) }
                    Button("New Token…") { regenerate(client) }
                    Divider()
                    Button("Remove", role: .destructive) { remove(client) }
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }

        private func workspaceNames(_ client: MCPClient) -> String {
            let names = library.workspaces.filter { client.workspaces.contains($0.id) }.map(\.name)
            return names.isEmpty ? "no workspace" : names.joined(separator: ", ")
        }

        private func save(_ draft: ClientDraft) {
            do {
                if let id = draft.id {
                    try clients.update(id, level: draft.level, workspaces: draft.workspaces)
                } else {
                    let added = try clients.add(name: draft.name, level: draft.level, workspaces: draft.workspaces)
                    shownToken = IssuedToken(name: added.client.name, token: added.token)
                }
                editing = nil
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        private func regenerate(_ client: MCPClient) {
            do {
                shownToken = try IssuedToken(name: client.name, token: clients.regenerateToken(for: client.id))
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        private func remove(_ client: MCPClient) {
            do {
                try clients.remove(client.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Editing

    private struct ClientDraft: Identifiable {
        /// The client being edited, or `nil` for a new one.
        let id: UUID?
        var name = ""
        var level = MCPLevel.read
        var workspaces: Set<UUID> = []

        init() {
            id = nil
        }

        init(_ client: MCPClient) {
            id = client.id
            name = client.name
            level = client.level
            workspaces = client.workspaces
        }
    }

    private struct ClientEditor: View {
        @State var draft: ClientDraft
        let workspaces: [Workspace]
        let save: (ClientDraft) -> Void
        let cancel: () -> Void

        var body: some View {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .disabled(draft.id != nil)
                    Picker("Can", selection: $draft.level) {
                        ForEach(MCPLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("The name shows in Activity next to each change this client proposes.")
                }
                Section("Workspaces") {
                    if workspaces.isEmpty {
                        Text("Add a workspace first.").foregroundStyle(.secondary)
                    }
                    ForEach(workspaces) { workspace in
                        Toggle(workspace.name, isOn: Binding(
                            get: { draft.workspaces.contains(workspace.id) },
                            set: { on in
                                if on {
                                    draft.workspaces.insert(workspace.id)
                                } else {
                                    draft.workspaces.remove(workspace.id)
                                }
                            }
                        ))
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel, action: cancel)
                    Button(draft.id == nil ? "Add" : "Save") { save(draft) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .formStyle(.grouped)
            .frame(width: 420, height: 380)
        }
    }

    // MARK: - Token

    private struct IssuedToken: Identifiable {
        let id = UUID()
        let name: String
        let token: String
    }

    private struct TokenSheet: View {
        let issued: IssuedToken
        let port: UInt16
        let done: () -> Void

        private var snippet: String {
            """
            {
              "mcpServers": {
                "fen": {
                  "url": "http://127.0.0.1:\(port)/mcp",
                  "headers": { "Authorization": "Bearer \(issued.token)" }
                }
              }
            }
            """
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Token for \(issued.name)").font(.headline)
                Text("Copy it now. Fen keeps only a fingerprint, so it can't show this token again.")
                    .foregroundStyle(.secondary)
                Text(snippet)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button("Copy Token") { copy(issued.token) }
                    Button("Copy Config") { copy(snippet) }
                    Spacer()
                    Button("Done", action: done).keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 460)
        }

        private func copy(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
#endif
