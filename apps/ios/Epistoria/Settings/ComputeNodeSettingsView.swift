import EpistoriaCore
import SwiftUI

struct ComputeNodeSettingsView: View {
    @Bindable var model: AppModel
    @State private var nodes: [DeviceSummary] = []
    @State private var jobs: [ProcessingJob] = []
    @State private var nodeToRemove: DeviceSummary?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Text("Epistoria works without a Mac. A Compute Node is optional and can accelerate larger local models, transcription, document conversion, and local AI providers.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    "Prefer a Compute Node for heavy local work",
                    isOn: Binding(
                        get: {
                            model.workspacePreferences.processingRoutePreference.mode
                                == .preferComputeNodeForHeavyWork
                        },
                        set: { enabled in
                            var preference = model.workspacePreferences.processingRoutePreference
                            preference.mode = enabled ? .preferComputeNodeForHeavyWork : .ipadFirst
                            model.workspacePreferences.processingRoutePreference = preference
                        }
                    )
                )
                Text("Every job still shows its route. Epistoria never changes to a paid or external provider silently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Routing")
            }

            if model.workspacePreferences.processingRoutePreference.mode
                == .preferComputeNodeForHeavyWork
            {
                Section("Eligible work") {
                    capabilityToggle("Long transcription", capability: .transcription)
                    capabilityToggle("Office conversion", capability: .officeConversion)
                    capabilityToggle("Larger formula models", capability: .formulaRecognition)
                    capabilityToggle("Private-network AI", capability: .localProvider)
                }
            }

            Section("Compute Nodes") {
                if isLoading && nodes.isEmpty {
                    ProgressView("Checking nodes…")
                } else if nodes.isEmpty {
                    ContentUnavailableView(
                        "No Compute Node",
                        systemImage: "desktopcomputer",
                        description: Text("Recognition, search, and direct AI providers remain available on this iPad.")
                    )
                } else {
                    ForEach(nodes) { node in
                        ComputeNodeRow(node: node) {
                            nodeToRemove = node
                        }
                    }
                }
            }

            Section {
                if nodeJobs.isEmpty {
                    Text("No work currently depends on a Compute Node.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(nodeJobs) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.kind.replacingOccurrences(of: "_", with: " ").capitalized)
                            Text(jobStateLabel(job.state))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Node work")
            } footer: {
                Text("Removing a node preserves notebook data. Unfinished node work waits for another valid route or can be cancelled.")
            }

            Section("Capabilities") {
                capability("Larger local models", symbol: "cpu")
                capability("Long transcription", symbol: "waveform")
                capability("Office document conversion", symbol: "doc.badge.gearshape")
                capability("Ollama, LM Studio, vLLM, and LocalAI", symbol: "network")
            }
        }
        .navigationTitle("Compute Nodes")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            "Remove this Compute Node?",
            isPresented: Binding(
                get: { nodeToRemove != nil },
                set: { if !$0 { nodeToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Compute Node", role: .destructive) {
                if let nodeToRemove { Task { await remove(nodeToRemove) } }
            }
            Button("Cancel", role: .cancel) { nodeToRemove = nil }
        } message: {
            Text("Pairing is revoked immediately. If the Mac is offline, erase its Epistoria Keychain items locally before disposing of it.")
        }
        .alert("Compute Node problem", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var nodeJobs: [ProcessingJob] {
        jobs.filter { $0.selectedRoute == .computeNode || $0.computeNodeId != nil }
    }

    @ViewBuilder
    private func capability(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(.primary)
    }

    private func capabilityToggle(
        _ title: String,
        capability: ProcessingCapability
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: {
                    model.workspacePreferences.processingRoutePreference.computeNodeCapabilities
                        .contains(capability)
                },
                set: { enabled in
                    var preference = model.workspacePreferences.processingRoutePreference
                    if enabled { preference.computeNodeCapabilities.insert(capability) }
                    else { preference.computeNodeCapabilities.remove(capability) }
                    model.workspacePreferences.processingRoutePreference = preference
                }
            )
        )
    }

    private func jobStateLabel(_ state: ProcessingJobState) -> String {
        switch state {
        case .queued: "Queued"
        case .running: "Running"
        case .paused: "Paused"
        case .waitingForCapability: "Waiting for a compatible route"
        case .waitingForNetwork: "Waiting for network"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            nodes = try await model.trustedDevices().filter { $0.kind == "MAC" && $0.revokedAt == nil }
            jobs = try await model.database?.processingJobs() ?? []
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func remove(_ node: DeviceSummary) async {
        nodeToRemove = nil
        do {
            try await model.removeComputeNode(id: node.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ComputeNodeRow: View {
    let node: DeviceSummary
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Compute Node", systemImage: "desktopcomputer")
                    .font(.headline)
                Spacer()
                Text(verbatim: status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Remove Compute Node", role: .destructive, action: onRemove)
                .disabled(node.revokedAt != nil)
        }
        .padding(.vertical, 4)
    }

    private var status: String {
        node.revokedAt == nil ? "Available" : "Removed"
    }

    private var detail: String {
        let suffix = String(node.id.uuidString.lowercased().suffix(8))
        guard let date = RFC3339Milliseconds.date(from: node.lastSeenAt) else {
            return "ID …\(suffix)"
        }
        let lastSeen = date.formatted(date: .abbreviated, time: .shortened)
        return "Last seen \(lastSeen) · ID …\(suffix)"
    }
}
