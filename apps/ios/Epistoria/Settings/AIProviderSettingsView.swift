import EpistoriaCore
import SwiftUI

struct AIProviderSettingsView: View {
    @Bindable var model: AppModel
    @State private var profiles: [AIProviderProfile] = []
    @State private var editingProfile: AIProviderProfile?
    @State private var errorMessage: String?
    @State private var profileToDelete: AIProviderProfile?

    var body: some View {
        List {
            Section {
                if profiles.isEmpty {
                    ContentUnavailableView(
                        "No AI provider",
                        systemImage: "cpu",
                        description: Text(
                            "Add OpenAI or an OpenAI-compatible service running locally or remotely."
                        )
                    )
                } else {
                    ForEach(profiles) { profile in
                        Button {
                            editingProfile = profile
                        } label: {
                            AIProviderRow(profile: profile)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                profileToDelete = profile
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if !profile.isActive, profile.state == .ready {
                                Button {
                                    Task { await activate(profile) }
                                } label: {
                                    Label("Use", systemImage: "checkmark.circle")
                                }
                                .tint(.primary)
                            }
                        }
                    }
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("One provider is active for all AI requests. Each completed result records the provider and model that processed it.")
            }

            Section("How provider access works") {
                ProviderDisclosureRow(
                    symbol: "key",
                    title: "Keys stay in Keychain",
                    detail: "This iPad stores API keys in device-only Keychain. Keys are not synchronized or included in notebook exports."
                )
                ProviderDisclosureRow(
                    symbol: "lock",
                    title: "Connections stay on this device",
                    detail: "Provider configuration does not pass through Epistoria sync. Another device must supply its own key."
                )
                ProviderDisclosureRow(
                    symbol: "arrow.up.right",
                    title: "Content goes to the selected service",
                    detail: "After approval, this iPad sends only the disclosed notebook content directly to the selected endpoint."
                )
            }

            Section {
                Text("OpenAI-compatible supports Ollama, LM Studio, vLLM, LocalAI, and compatible hosted gateways. OpenAI Responses, Anthropic Messages, and Gemini Generate Content connect directly from this iPad.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("AI Providers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editingProfile = .newCompatible
                } label: {
                    Label("Add provider", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editingProfile) { profile in
            NavigationStack {
                AIProviderEditorView(model: model, profile: profile) {
                    await reload()
                }
            }
        }
        .confirmationDialog(
            "Remove this provider from this iPad?",
            isPresented: Binding(
                get: { profileToDelete != nil },
                set: { if !$0 { profileToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove provider", role: .destructive) {
                guard let profile = profileToDelete else { return }
                profileToDelete = nil
                Task { await remove(profile) }
            }
            Button("Cancel", role: .cancel) { profileToDelete = nil }
        } message: {
            Text("The device-only key is removed immediately. Accepted AI results and learning records remain available.")
        }
        .alert("AI provider problem", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .task { await reload() }
        .refreshable { await reload() }
        .epistoriaPageBackground()
    }

    private func reload() async {
        do {
            try await model.refreshAIProviderProfiles()
            profiles = try model.aiProviderProfiles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func activate(_ profile: AIProviderProfile) async {
        do {
            try await model.activateAIProviderProfile(id: profile.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ profile: AIProviderProfile) async {
        do {
            try await model.removeAIProviderProfile(id: profile.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AIProviderRow: View {
    let profile: AIProviderProfile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: profile.isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(profile.isActive ? .primary : .tertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(profile.displayName)
                        .foregroundStyle(.primary)
                    if profile.isActive {
                        Text("Active")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text("\(profile.destinationHost) · \(profile.textModel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if profile.state != .ready {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(profile.state == .failed ? .red : .secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch profile.state {
        case .local: "Saved on this iPad"
        case .queued: "Updating this iPad"
        case .ready: "Ready"
        case .failed: "Could not configure: \(profile.lastErrorCode ?? "unknown error")"
        case .deleting: "Removing from this iPad"
        }
    }
}

private struct ProviderDisclosureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AIProviderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    @State private var profile: AIProviderProfile
    @State private var apiKey = ""
    @State private var makeActive: Bool
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var connectionResult: String?
    @State private var connectionTestTask: Task<Void, Never>?
    let onSaved: () async -> Void

    init(model: AppModel, profile: AIProviderProfile, onSaved: @escaping () async -> Void) {
        self.model = model
        _profile = State(initialValue: profile)
        _makeActive = State(initialValue: profile.isActive)
        self.onSaved = onSaved
    }

    var body: some View {
        Form {
            Section {
                Picker("Adapter", selection: $profile.adapter) {
                    Text("OpenAI").tag(AIProviderAdapter.openAIResponses)
                    Text("OpenAI-compatible").tag(AIProviderAdapter.openAICompatible)
                    Text("Anthropic").tag(AIProviderAdapter.anthropicMessages)
                    Text("Google Gemini").tag(AIProviderAdapter.geminiGenerateContent)
                }
                .onChange(of: profile.adapter) { _, adapter in
                    if adapter == .openAICompatible {
                        profile.baseURL = URL(string: "http://127.0.0.1:11434/v1")!
                    } else if let endpoint = AIProviderURLPolicy.normalized("", adapter: adapter) {
                        profile.baseURL = endpoint
                    }
                    if !adapter.supportsTimestampedTranscription {
                        profile.transcriptionModel = nil
                        profile.capabilities.removeAll(where: { $0 == .transcription })
                        profile.transcriptionUSDPerMinute = nil
                        profile.structuredOutput = true
                    }
                }
                TextField("Name", text: $profile.displayName)
                if profile.adapter == .openAICompatible {
                    TextField(
                        "Server URL",
                        text: Binding(
                            get: { profile.baseURL.absoluteString },
                            set: { if let value = URL(string: $0) { profile.baseURL = value } }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                } else {
                    LabeledContent("Server", value: profile.adapter.fixedServerName)
                }
                SecureField(
                    profile.adapter == .openAICompatible
                        ? "API key (optional for local servers)"
                        : "API key",
                    text: $apiKey
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            } header: {
                Text("Connection")
            } footer: {
                if profile.adapter == .openAICompatible {
                    Text("This iPad resolves this URL. HTTP is accepted only for loopback, private-network, or .local addresses. Leave the key empty for a local server that does not require one.")
                    if usesLoopbackAddress {
                        #if targetEnvironment(simulator)
                        Text("Loopback reaches the Mac from the iPad Simulator. A physical iPad must use the Mac's private IP address or .local hostname.")
                        #else
                        Text("127.0.0.1 and localhost refer to this iPad, not your Mac. For Ollama on a Mac, use http://MAC-IP:11434/v1 and expose Ollama to the local network first.")
                        #endif
                    }
                } else {
                    Text("The API key is stored in device-only Keychain. Leave this field empty when editing to retain the existing key.")
                }
                Text("Changing the adapter clears the previous key unless you enter a replacement.")
            }

            Section("Models") {
                TextField("Text model", text: $profile.textModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if profile.adapter.supportsTimestampedTranscription {
                    TextField(
                        "Transcription model (optional)",
                        text: Binding(
                            get: { profile.transcriptionModel ?? "" },
                            set: { profile.transcriptionModel = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
            }

            Section {
                Button {
                    if isTesting {
                        connectionTestTask?.cancel()
                    } else {
                        connectionTestTask = Task { await testConnection() }
                    }
                } label: {
                    if isTesting {
                        Label("Stop connection test", systemImage: "stop.circle")
                    } else {
                        Label("Test server and model", systemImage: "bolt.horizontal.circle")
                    }
                }
                .disabled(!isTesting && (!isValid || isSaving))

                if isTesting {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Waiting for the model… The first Ollama load can take longer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let connectionResult {
                    Label(connectionResult, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(EpistoriaDesign.positive)
                }
            } header: {
                Text("Connection test")
            } footer: {
                if profile.adapter == .openAICompatible {
                    Text("Epistoria first checks /v1/models for the exact model name, then requests a short response. The model response has a three-minute timeout and is not saved.")
                } else {
                    Text("Epistoria requests a short response and discards it. The model response has a three-minute timeout and does not change notebook data.")
                }
            }

            Section {
                Toggle("Vision input", isOn: capability(.vision))
                if profile.adapter.supportsTimestampedTranscription {
                    Toggle("Audio transcription", isOn: capability(.transcription))
                }
                if profile.adapter.usesNativeStructuredOutput {
                    LabeledContent("Structured output", value: "Required")
                } else {
                    Toggle("JSON output mode", isOn: $profile.structuredOutput)
                }
            } header: {
                Text("Capabilities")
            } footer: {
                Text("Epistoria validates every provider response against its own schema. Capability switches describe what this endpoint actually supports.")
            }

            Section {
                if profile.isActive {
                    LabeledContent("Active provider", value: "Yes")
                } else {
                    Toggle("Make active provider", isOn: $makeActive)
                }
            } header: {
                Text("Routing")
            } footer: {
                Text("An approved AI request freezes this connection and model. Changing the active provider later does not reroute approved work. The saved result records the provider and model used.")
            }

            Section("Estimated pricing (optional)") {
                OptionalPriceField("Input per million tokens", value: $profile.inputUSDPerMillion)
                OptionalPriceField("Output per million tokens", value: $profile.outputUSDPerMillion)
                if profile.adapter.supportsTimestampedTranscription {
                    OptionalPriceField(
                        "Transcription per minute",
                        value: $profile.transcriptionUSDPerMinute
                    )
                }
            }
        }
        .navigationTitle(profile.state == .local ? "Add Provider" : "Edit Provider")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(!isValid || isSaving)
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onDisappear { connectionTestTask?.cancel() }
        .onChange(of: profile) { _, _ in connectionResult = nil }
        .onChange(of: apiKey) { _, _ in connectionResult = nil }
        .alert("Could not save provider", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var isValid: Bool {
        let name = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = profile.textModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcription = profile.transcriptionModel?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return !name.isEmpty && name.count <= 200
            && !model.isEmpty && model.count <= 200
            && (transcription?.count ?? 0) <= 200
            && (!requiresNewHostedKey || !apiKey.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty)
            && validPrice(profile.inputUSDPerMillion)
            && validPrice(profile.outputUSDPerMillion)
            && validPrice(profile.transcriptionUSDPerMinute)
            && AIProviderURLPolicy.normalized(
                profile.baseURL.absoluteString,
                adapter: profile.adapter
            ) != nil
    }

    private func validPrice(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value >= 0
    }

    private var requiresNewHostedKey: Bool {
        profile.state == .local && profile.adapter != .openAICompatible
    }

    private var usesLoopbackAddress: Bool {
        guard profile.adapter == .openAICompatible,
              let host = profile.baseURL.host()?.lowercased()
        else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func capability(_ value: AIProviderCapability) -> Binding<Bool> {
        Binding(
            get: { profile.capabilities.contains(value) },
            set: { enabled in
                profile.capabilities.removeAll(where: { $0 == value })
                if enabled { profile.capabilities.append(value) }
            }
        )
    }

    private func save() async {
        guard let normalized = AIProviderURLPolicy.normalized(
            profile.baseURL.absoluteString,
            adapter: profile.adapter
        ) else { return }
        isSaving = true
        profile.baseURL = normalized
        profile.displayName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.textModel = profile.textModel.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.isActive = makeActive
        if !profile.capabilities.contains(.text) { profile.capabilities.append(.text) }
        if profile.adapter.usesNativeStructuredOutput { profile.structuredOutput = true }
        do {
            let replacementSecret = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try await model.saveAIProviderProfile(
                profile,
                replacementSecret: replacementSecret.isEmpty ? nil : replacementSecret
            )
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }

    @MainActor
    private func testConnection() async {
        guard let normalized = AIProviderURLPolicy.normalized(
            profile.baseURL.absoluteString,
            adapter: profile.adapter
        ) else { return }
        isTesting = true
        connectionResult = nil
        errorMessage = nil
        defer {
            isTesting = false
            connectionTestTask = nil
        }
        var tested = profile
        tested.baseURL = normalized
        tested.displayName = tested.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        tested.textModel = tested.textModel.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await model.testAIProviderProfile(
                tested,
                replacementSecret: apiKey
            )
            connectionResult = "Connected to \(result.verifiedModel) in \(formattedDuration(result.elapsedMilliseconds))."
        } catch is CancellationError {
            connectionResult = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formattedDuration(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 { return "\(milliseconds) ms" }
        return String(format: "%.1f s", Double(milliseconds) / 1_000)
    }
}

private extension AIProviderAdapter {
    var fixedServerName: String {
        switch self {
        case .openAIResponses: "api.openai.com"
        case .openAICompatible: "Custom server"
        case .anthropicMessages: "api.anthropic.com"
        case .geminiGenerateContent: "generativelanguage.googleapis.com"
        }
    }

    var supportsTimestampedTranscription: Bool {
        self == .openAIResponses || self == .openAICompatible
    }

    var usesNativeStructuredOutput: Bool {
        self == .anthropicMessages || self == .geminiGenerateContent
    }
}

private struct OptionalPriceField: View {
    let title: String
    @Binding var value: Double?

    init(_ title: String, value: Binding<Double?>) {
        self.title = title
        _value = value
    }

    var body: some View {
        TextField(title, value: $value, format: .number)
            .keyboardType(.decimalPad)
    }
}

private extension AIProviderProfile {
    static var newCompatible: AIProviderProfile {
        AIProviderProfile(
            id: UUID(),
            configurationRevisionId: nil,
            displayName: "Local AI",
            adapter: .openAICompatible,
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            textModel: "",
            transcriptionModel: nil,
            capabilities: [.text],
            structuredOutput: true,
            inputUSDPerMillion: nil,
            outputUSDPerMillion: nil,
            transcriptionUSDPerMinute: nil,
            isActive: true,
            state: .local,
            pendingOperation: nil,
            lastJobId: nil,
            lastErrorCode: nil,
            updatedAt: Date()
        )
    }
}
