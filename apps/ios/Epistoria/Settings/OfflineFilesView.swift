import EpistoriaCore
import SwiftUI

/// Foreground-only, owner-started transfers. Closing the screen or backgrounding cancels the
/// actual task. Successfully verified files remain cached; retry starts only missing files.
struct OfflineFilesView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var items: [OfflineAssetItem] = []
    @State private var selectedIDs = Set<UUID>()
    @State private var availableBytes: Int64?
    @State private var loading = true
    @State private var transferTask: Task<Void, Never>?
    @State private var currentID: UUID?
    @State private var receivedBytes: Int64 = 0
    @State private var expectedBytes: Int64 = 0
    @State private var failures: [UUID: String] = [:]
    @State private var message: String?
    @State private var visibleCount = 100

    private var estimate: OfflineDownloadEstimate? {
        try? OfflineDownloadEstimate(items: items, selectedIDs: selectedIDs)
    }

    var body: some View {
        List {
            Section {
                Text("Save encrypted originals on this iPad before going offline. This includes note images and older Source versions; it does not capture online-only links or download AI models.")
                    .font(.subheadline)
                if let availableBytes {
                    LabeledContent("Available storage", value: bytes(availableBytes))
                } else if !loading {
                    Text("Available storage could not be measured. The download will stop if storage runs out.")
                        .foregroundStyle(.secondary)
                }
                if let estimate {
                    LabeledContent("Selected files", value: String(estimate.fileCount))
                    LabeledContent("Download size", value: bytes(estimate.downloadBytes))
                    LabeledContent("Free space needed", value: bytes(estimate.requiredFreeBytes))
                }
            } footer: {
                Text("The space estimate includes a safety allowance. Keep this screen open. Closing it, locking the notebook, or leaving the app stops unfinished downloads. Completed files are kept.")
            }

            Section {
                if loading {
                    ProgressView("Checking local files…")
                } else if transferTask != nil {
                    if let currentID, let item = items.first(where: { $0.id == currentID }) {
                        Text(item.filename)
                        ProgressView(value: Double(receivedBytes), total: Double(max(1, expectedBytes)))
                            .accessibilityLabel("Download progress")
                        Text(receivedBytes == expectedBytes && expectedBytes > 0
                             ? "Verifying and saving…"
                             : "\(bytes(receivedBytes)) of \(bytes(expectedBytes)) received")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Cancel downloads", role: .cancel) { transferTask?.cancel() }
                        .accessibilityIdentifier("offline.cancel")
                } else {
                    Button("Select all missing files") {
                        selectedIDs = Set(items.filter { !$0.isAvailable }.map(\.id))
                    }
                    .disabled(items.allSatisfy(\.isAvailable))
                    Button("Download selected files") { startDownload() }
                        .disabled(estimate == nil || estimate?.fileCount == 0)
                        .accessibilityIdentifier("offline.download")
                    Button("Check again") { loading = true }
                        .disabled(loading)
                }
                if let message { Text(message).font(.subheadline).accessibilityIdentifier("offline.status") }
            }

            Section("Files") {
                if !loading && items.isEmpty { Text("No original files in this notebook.") }
                ForEach(items.prefix(visibleCount)) { item in
                    HStack {
                        if item.isAvailable {
                            Image(systemName: "checkmark.circle").accessibilityLabel("Saved on this iPad")
                        } else {
                            Toggle("Select \(item.filename)", isOn: Binding(
                                get: { selectedIDs.contains(item.id) },
                                set: { if $0 { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) } }
                            ))
                            .labelsHidden()
                            .disabled(transferTask != nil)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.filename)
                            Text("\(bytes(item.encryptedByteSize)) · \(item.isAvailable ? "On this iPad" : "Not downloaded")")
                                .font(.caption).foregroundStyle(.secondary)
                            if let failure = failures[item.id] {
                                Text(failure).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if visibleCount < items.count {
                    Button("Show more files") { visibleCount += 100 }
                }
            }
        }
        .navigationTitle("Offline Files")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loading) { if loading { await load() } }
        .onDisappear { transferTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { transferTask?.cancel() }
        }
    }

    private func load() async {
        defer { loading = false }
        guard let manager = model.assetManager else {
            message = "Unlock the notebook to check its files."
            return
        }
        do {
            items = try await manager.offlineAssetInventory()
            availableBytes = try await manager.availableStorageBytes()
            selectedIDs.formIntersection(items.filter { !$0.isAvailable }.map(\.id))
            message = nil
        } catch is CancellationError {
            return
        } catch { message = "Could not check files. Try again. \(error.localizedDescription)" }
    }

    private func startDownload() {
        guard transferTask == nil, let manager = model.assetManager,
              let estimate, estimate.fileCount > 0 else { return }
        let selected = items.filter { selectedIDs.contains($0.id) && !$0.isAvailable }
        message = nil
        failures = [:]
        transferTask = Task {
            defer { transferTask = nil; currentID = nil }
            do {
                availableBytes = try await manager.availableStorageBytes()
                if let availableBytes, availableBytes < estimate.requiredFreeBytes {
                    throw AssetManagerError.insufficientStorage
                }
                for item in selected {
                    try Task.checkCancellation()
                    currentID = item.id
                    receivedBytes = 0
                    expectedBytes = item.encryptedByteSize
                    do {
                        _ = try await manager.cacheAsset(assetId: item.id) { received, expected in
                            await MainActor.run {
                                receivedBytes = received
                                expectedBytes = expected
                            }
                        }
                        if let index = items.firstIndex(where: { $0.id == item.id }) {
                            items[index] = OfflineAssetItem(id: item.id, filename: item.filename,
                                encryptedByteSize: item.encryptedByteSize, isAvailable: true)
                        }
                        selectedIDs.remove(item.id)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failures[item.id] = error.localizedDescription
                        // Stop on the first failure. A revoked connection or full disk must not
                        // trigger one more request per remaining file.
                        throw error
                    }
                }
                availableBytes = try await manager.availableStorageBytes()
                message = "Selected files are saved on this iPad."
            } catch is CancellationError {
                message = "Downloads stopped. Completed files are kept. Download the remaining selection when ready."
            } catch {
                message = "Downloads stopped. Completed files are kept. Check storage and the sync connection, then retry the remaining selection. \(error.localizedDescription)"
            }
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
