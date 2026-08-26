import SwiftUI

struct LocalProcessingSettingsView: View {
    @Bindable var model: AppModel
    @Bindable private var settings: LocalProcessingSettings

    @State private var formulaState: OnDeviceFormulaModelState = .unavailable
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
                        if value, !modelIsInstalled { showInstallApproval = true }
                        else { settings.localMathOCR = value }
                    }
                ))
                .disabled(modelIsUnavailable)
                LabeledContent("Runtime", value: "Core ML on this iPad")
                LabeledContent("Model", value: modelName)
                LabeledContent("Verification", value: statusLabel)

                switch formulaState {
                case .installing:
                    HStack {
                        ProgressView()
                        Text("Downloading and verifying on this iPad")
                    }
                case .installed:
                    Button("Remove model…", role: .destructive) { showRemoveApproval = true }
                case .notInstalled, .invalid:
                    Button("Download and verify…") { showInstallApproval = true }
                case .unavailable:
                    Label(
                        "The converted model remains disabled until accuracy, latency, memory, thermal, and license validation passes.",
                        systemImage: "hammer"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Text("The verified model is stored only on this iPad. Model files are excluded from synchronization, notebook backups, and readable exports.")
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
            Button("Download and verify") { Task { await install() } }
            Button("Cancel", role: .cancel) { settings.localMathOCR = false }
        } message: {
            Text("Epistoria downloads the pinned model over HTTPS, verifies its size and SHA-256 digest, and compiles it locally with Core ML.")
        }
        .confirmationDialog(
            "Remove the Local Math OCR model?",
            isPresented: $showRemoveApproval,
            titleVisibility: .visible
        ) {
            Button("Remove model", role: .destructive) { Task { await remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing encrypted recognition artifacts and corrections remain in the notebook.")
        }
        .alert("Local processing problem", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var modelName: String {
        FormulaModelRegistry.productionManifest?.modelId ?? "Development candidate"
    }

    private var modelIsInstalled: Bool {
        if case .installed = formulaState { return true }
        return false
    }

    private var modelIsUnavailable: Bool {
        if case .unavailable = formulaState { return true }
        return false
    }

    private var statusLabel: String {
        switch formulaState {
        case .unavailable: "Validation required"
        case .notInstalled: "Not installed"
        case .installing: "Installing"
        case let .installed(version): "Installed · \(version)"
        case .invalid: "Verification failed"
        }
    }

    private func saveLanguages() {
        settings.preferredLanguages = languageText.split(separator: ",").map(String.init)
        languageText = settings.normalizedLanguages.joined(separator: ", ")
    }

    @MainActor
    private func loadStatus() async {
        languageText = settings.normalizedLanguages.joined(separator: ", ")
        await model.formulaModelManager.refresh()
        formulaState = await model.formulaModelManager.state
        if !modelIsInstalled { settings.localMathOCR = false }
    }

    @MainActor
    private func install() async {
        do {
            try await model.formulaModelManager.install()
            await loadStatus()
            settings.localMathOCR = modelIsInstalled
        } catch {
            settings.localMathOCR = false
            await loadStatus()
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func remove() async {
        do {
            try await model.formulaModelManager.remove()
            settings.localMathOCR = false
            await loadStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
