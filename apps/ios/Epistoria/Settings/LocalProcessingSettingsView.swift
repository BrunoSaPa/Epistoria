import EpistoriaCore
import SwiftUI

struct LocalProcessingSettingsView: View {
    @Bindable var model: AppModel
    @Bindable private var settings: LocalProcessingSettings

    @State private var latestStatus: LocalModelStatusArtifact?
    @State private var pendingOperation: LocalModelControlOperation?
    @State private var pendingJobId: UUID?
    @State private var errorMessage: String?
    @State private var showInstallApproval = false
    @State private var showRemoveApproval = false
    @State private var languageText = ""

    init(model: AppModel) {
        self.model = model
        settings = model.localProcessingSettings
    }

    var body: some View {
        Form {
            Section("General OCR") {
                LabeledContent("Printed text and handwriting", value: "On-device Apple Vision")
                Toggle("Recognize notebook handwriting automatically", isOn: $settings.automaticNotebookOCR)
                Toggle("Recognize scanned Source pages automatically", isOn: $settings.automaticSourceOCR)
                Text("Recognition waits until drawing stops and never replaces original ink or Source files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OCR languages") {
                TextField("Language codes", text: $languageText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(saveLanguages)
                Button("Save languages", action: saveLanguages)
                Text("Use comma-separated language tags, such as en-US, es-MX. Device languages are used by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local Math OCR") {
                Toggle("Enable formula recognition", isOn: Binding(
                    get: { settings.localMathOCR },
                    set: { value in
                        if value, latestStatus?.state != .installed {
                            showInstallApproval = true
                        } else {
                            settings.localMathOCR = value
                        }
                    }
                ))
                LabeledContent("Model", value: "PP-FormulaNet_plus-S")
                LabeledContent("Version", value: shortModelVersion)
                LabeledContent("License", value: latestStatus?.license ?? "Apache-2.0")
                LabeledContent("Download size", value: modelSize)
                LabeledContent("Verification", value: statusLabel)

                if pendingOperation != nil {
                    HStack {
                        ProgressView()
                        Text("Encrypted request queued for the trusted Mac")
                        if pendingOperation == .install {
                            Spacer()
                            Button("Pause") { Task { await pauseDownload() } }
                        }
                    }
                } else {
                    HStack {
                        Button("Check status") { Task { await submit(.status) } }
                        if latestStatus?.state == .installed {
                            if latestStatus?.modelVersion != pinnedModelVersion {
                                Button("Update…") { showInstallApproval = true }
                            }
                            Button("Remove…", role: .destructive) { showRemoveApproval = true }
                        } else {
                            Button("Download and verify…") { showInstallApproval = true }
                        }
                    }
                }
                Text(
                    "The model is stored only on the trusted Mac. Inference does not use the network, and model files are excluded from sync and exports."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Review policy") {
                Label("Unreviewed OCR is available only in local search", systemImage: "magnifyingglass")
                Label("Acceptance is required before learning features can use it", systemImage: "checkmark.shield")
                Label("Results without engine confidence are marked Unverified", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle("Local Processing")
        .task { await loadStatus() }
        .confirmationDialog(
            "Download Local Math OCR?",
            isPresented: $showInstallApproval,
            titleVisibility: .visible
        ) {
            Button("Download and verify") {
                Task { await submit(.install) }
            }
            Button("Cancel", role: .cancel) { settings.localMathOCR = false }
        } message: {
            Text(
                "The trusted Mac will download about 264 MB from the pinned official model repository, verify every file, and install it outside notebook sync and backups."
            )
        }
        .confirmationDialog(
            "Remove the Local Math OCR model?",
            isPresented: $showRemoveApproval,
            titleVisibility: .visible
        ) {
            Button("Remove model", role: .destructive) {
                settings.localMathOCR = false
                Task { await submit(.remove) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing encrypted OCR artifacts and corrections remain in the notebook.")
        }
        .alert("Local processing problem", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var shortModelVersion: String {
        guard let value = latestStatus?.modelVersion else { return "Pinned" }
        return String(value.prefix(12))
    }

    private var pinnedModelVersion: String {
        "3d46f557e3a1752f4bf81202395af3b5ecfadfd2"
    }

    private var modelSize: String {
        let bytes = latestStatus?.expectedBytes ?? 263_548_202
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var statusLabel: String {
        if pendingOperation != nil { return "Queued" }
        switch latestStatus?.state {
        case .installed: return "Installed and verified"
        case .invalid: return "Verification failed"
        case .notInstalled, nil: return "Not installed"
        }
    }

    private func saveLanguages() {
        settings.preferredLanguages = languageText.split(separator: ",").map(String.init)
        languageText = settings.normalizedLanguages.joined(separator: ", ")
    }

    private func loadStatus() async {
        languageText = settings.normalizedLanguages.joined(separator: ", ")
        guard let store = model.store else { return }
        latestStatus = try? await store.localModelStatuses().first?.payload
    }

    private func submit(_ operation: LocalModelControlOperation) async {
        guard let accountId = model.configuration?.accountId, let aiJobs = model.aiJobs else {
            errorMessage = "Connect private sync and pair the trusted Mac before managing the formula model."
            return
        }
        pendingOperation = operation
        do {
            let summary = try await aiJobs.submitLocalModelControl(
                LocalModelControlRequest(accountId: accountId, operation: operation)
            )
            pendingJobId = summary.id
            model.noteLocalMutation()
            await waitForCompletion(jobId: summary.id)
        } catch {
            pendingOperation = nil
            errorMessage = error.localizedDescription
        }
    }

    private func waitForCompletion(jobId: UUID) async {
        guard let aiJobs = model.aiJobs else { return }
        for _ in 0 ..< 600 {
            guard pendingJobId == jobId else { return }
            do {
                let job = try await aiJobs.localProcessingJob(id: jobId)
                switch job.status {
                case "COMPLETE":
                    await model.synchronize()
                    await loadStatus()
                    if pendingOperation == .install {
                        settings.localMathOCR = latestStatus?.state == .installed
                    }
                    pendingOperation = nil
                    pendingJobId = nil
                    return
                case "FAILED":
                    if pendingOperation == .install { settings.localMathOCR = false }
                    pendingOperation = nil
                    pendingJobId = nil
                    errorMessage = "The trusted Mac could not complete local model management (\(job.errorCode ?? "unknown error"))."
                    return
                case "CANCELLED":
                    pendingOperation = nil
                    pendingJobId = nil
                    return
                default:
                    try await Task.sleep(for: .seconds(1))
                }
            } catch {
                try? await Task.sleep(for: .seconds(2))
            }
        }
        pendingOperation = nil
        pendingJobId = nil
        errorMessage = "The model request is still running. Reopen Local Processing to check its result."
    }

    private func pauseDownload() async {
        guard let id = pendingJobId, let aiJobs = model.aiJobs else { return }
        do {
            _ = try await aiJobs.cancelLocalProcessingJob(id: id)
            pendingOperation = nil
            pendingJobId = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
