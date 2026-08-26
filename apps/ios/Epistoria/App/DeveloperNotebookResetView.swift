#if DEBUG
import SwiftUI

struct DeveloperNotebookResetView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var encryptedBackupURL: URL?

    let onExport: () async throws -> URL
    let onDelete: () async throws -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Local development reset") {
                    Text("This permanently deletes the local encrypted database, local files, account key, device token, and setup information for this development build.")
                    Text("A connected server copy is not deleted. You need the account ID and 24 recovery words to recover it later.")
                        .foregroundStyle(.secondary)
                }

                Section("Back up first") {
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
                    }
                    .foregroundStyle(.primary)
                    .disabled(confirmation != "DELETE" || isWorking)
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
    }

    @MainActor
    private func createBackup() async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            encryptedBackupURL = try await onExport()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deleteNotebook() async {
        guard confirmation == "DELETE", !isWorking else { return }
        isWorking = true
        errorMessage = nil
        do {
            try await onDelete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isWorking = false
        }
    }
}
#endif
