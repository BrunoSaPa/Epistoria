#if DEBUG
import EpistoriaCore
import SwiftUI
import UniformTypeIdentifiers

struct DeveloperNotebookResetView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var encryptedBackupURL: URL?
    @State private var readableExport: EpistoriaExportResult?
    @State private var confirmedReadableExportSaved = false
    @State private var isChoosingReadableArchive = false
    @State private var readableArchive: PortableArchiveInspection?

    let onReadableExport: () async throws -> EpistoriaExportResult
    let onEncryptedExport: () async throws -> URL
    let onDelete: (PortableArchiveInspection) async throws -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Local development reset") {
                    Text("This permanently deletes the local encrypted database, local files, account key, device token, and setup information for this development build.")
                    Text("The replacement notebook uses a new generation ID. Records from the previous synchronized generation cannot reappear in it.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        Task { await createReadableArchive() }
                    } label: {
                        Label("Create readable archive", systemImage: "archivebox")
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier("development.reset.create-readable")

                    Button {
                        isChoosingReadableArchive = true
                    } label: {
                        Label("Verify an existing archive", systemImage: "checkmark.shield")
                    }
                    .disabled(isWorking)

                    if let readableExport {
                        ShareLink(item: readableExport.archiveURL) {
                            Label("Save readable archive", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("development.reset.share-readable")
                        Toggle(
                            "I saved this archive outside Epistoria",
                            isOn: $confirmedReadableExportSaved
                        )
                        .accessibilityIdentifier("development.reset.confirm-saved")
                    }

                    if let readableArchive {
                        LabeledContent("Format", value: readableArchive.formatVersion)
                        LabeledContent(
                            "Size",
                            value: ByteCountFormatter.string(
                                fromByteCount: readableArchive.byteCount,
                                countStyle: .file
                            )
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SHA-256")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(readableArchive.sha256)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("Required readable archive")
                } footer: {
                    Text("Create and save the current version 8 archive, or verify an existing version 7 or 8 archive. Reset stays disabled until Epistoria calculates a complete SHA-256 checksum.")
                }

                Section("Optional encrypted copy") {
                    Button {
                        Task { await createBackup() }
                    } label: {
                        Label("Create encrypted notebook backup", systemImage: "lock.doc")
                    }
                    .disabled(isWorking)

                    if let encryptedBackupURL {
                        ShareLink(item: encryptedBackupURL) {
                            Label("Save encrypted backup", systemImage: "square.and.arrow.up")
                        }
                        Text("This backup contains the SQLCipher database and encrypted assets. Keep the account ID and recovery words separately.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Type DELETE", text: $confirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("development.reset.confirmation")

                    Button {
                        Task { await deleteNotebook() }
                    } label: {
                        Label("Delete local development notebook", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(EpistoriaDesign.ink)
                    .controlSize(.large)
                    .disabled(
                        confirmation != "DELETE"
                            || readableArchive == nil
                            || (readableExport != nil && !confirmedReadableExportSaved)
                            || isWorking
                    )
                    .accessibilityIdentifier("development.reset.delete")
                } footer: {
                    Text("This control exists only in Debug builds.")
                }

                if let errorMessage {
                    Section("Reset error") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                if isWorking {
                    Section {
                        ProgressView("Working…")
                            .accessibilityIdentifier("development.reset.progress")
                    }
                }
            }
            .navigationTitle("Delete development data")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
        .presentationDetents([.medium, .large])
        .fileImporter(
            isPresented: $isChoosingReadableArchive,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            Task { await verifyReadableArchive(result) }
        }
    }

    @MainActor
    private func createReadableArchive() async {
        guard !isWorking else { return }
        isWorking = true
        readableExport = nil
        readableArchive = nil
        confirmedReadableExportSaved = false
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await onReadableExport()
            let inspection = try PortableArchiveInspector().inspect(
                zipURL: result.archiveURL,
                allowedFormats: ["epistoria-export/8"]
            )
            readableExport = result
            readableArchive = inspection
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func createBackup() async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            encryptedBackupURL = try await onEncryptedExport()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func verifyReadableArchive(_ result: Result<[URL], Error>) async {
        guard !isWorking else { return }
        isWorking = true
        readableExport = nil
        confirmedReadableExportSaved = false
        readableArchive = nil
        errorMessage = nil
        defer { isWorking = false }
        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            readableArchive = try PortableArchiveInspector().inspect(
                zipURL: url,
                allowedFormats: ["epistoria-export/7", "epistoria-export/8"]
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deleteNotebook() async {
        guard confirmation == "DELETE", let readableArchive, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        do {
            try await onDelete(readableArchive)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isWorking = false
        }
    }
}
#endif
