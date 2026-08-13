import EpistoriaCore
import SwiftUI
import UniformTypeIdentifiers

enum PrivateServerEndpoint {
    static func validatedURL(from rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { return nil }
        let normalizedPath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        guard normalizedPath == "/v1" else { return nil }
        components.scheme = scheme
        components.path = "/v1"
        return components.url
    }
}

struct DataHealthView: View {
    @Bindable var model: AppModel
    @State private var health: DataHealthSnapshot?
    @State private var serverURL = "http://127.0.0.1:3000/v1"
    @State private var bootstrapSecret = ""
    @State private var recoveryWords: String?
    @State private var pairing: MacPairingMaterial?
    @State private var devices: [DeviceSummary] = []
    @State private var deviceListError: String?
    @State private var isLoadingDevices = false
    @State private var hasLoadedDevices = false
    @State private var pendingDeviceRevocation: DeviceSummary?
    @State private var isWorking = false
    @State private var showAdvanced = false
    @State private var showServerSetup = false
    @State private var showExportConfirmation = false
    @State private var includeDerivedAI = true
    @State private var exportResult: EpistoriaExportResult?
    @State private var isChoosingExportDirectory = false
    @State private var validationMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if model.isCreatingPortableExport {
                    exportProgressSection
                }
                Group {
                    securitySection
                    syncSection
                    serverSection
                    macSection
                    devicesSection
                    recoverySection
                    exportSection
                    advancedSection
                }
                .disabled(model.isCreatingPortableExport)
            }
            .navigationTitle("Data Health")
            .toolbar {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                    .disabled(model.isCreatingPortableExport)
            }
            .task { await load() }
            .refreshable {
                guard !model.isCreatingPortableExport else { return }
                await load()
            }
            .sheet(item: $pairing) { PairMacView(material: $0, apiURL: model.configuration?.apiURL) }
            .sheet(item: $exportResult) { result in
                ExportReadyView(result: result) {
                    removeExport(result)
                }
            }
            .confirmationDialog(
                "Create a readable export?",
                isPresented: $showExportConfirmation,
                titleVisibility: .visible
            ) {
                Button("Create decrypted export") { Task { await createExport() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The ZIP will contain readable notes, drawings, annotations, and original PDFs. Store it only in a location you trust; recovery words and account keys are never included.")
            }
            .confirmationDialog(
                "Revoke this trusted device?",
                isPresented: Binding(
                    get: { pendingDeviceRevocation != nil },
                    set: { if !$0 { pendingDeviceRevocation = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Revoke device", role: .destructive) {
                    guard let device = pendingDeviceRevocation else { return }
                    pendingDeviceRevocation = nil
                    Task { await revoke(device) }
                }
                Button("Cancel", role: .cancel) { pendingDeviceRevocation = nil }
            } message: {
                Text("That device will lose server access immediately. Its local encrypted copy is not erased remotely.")
            }
            .fileImporter(
                isPresented: $isChoosingExportDirectory,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                Task { await validateExport(result) }
            }
            .sheet(isPresented: Binding(
                get: { recoveryWords != nil },
                set: { if !$0 { recoveryWords = nil } }
            )) {
                RecoveryExportView(
                    accountId: model.configuration?.accountId,
                    words: recoveryWords ?? ""
                ) { recoveryWords = nil }
            }
            .alert("Data Health error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .onDisappear { discardSensitiveState() }
            .epistoriaPageBackground()
            .tint(EpistoriaDesign.accent)
        }
    }

    private var securitySection: some View {
        Section("Your data is protected") {
            healthRow(
                "SQLCipher integrity",
                value: health?.databaseIntegrity ?? "Checking…",
                symbol: health?.databaseIntegrity == "ok" ? "checkmark.shield" : "lock.shield"
            )
            Text("Notes, search, metadata, and cached files are encrypted on this iPad. A connected sync server receives encrypted content, never readable titles or note text.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var exportProgressSection: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                ProgressView()
                    .controlSize(.regular)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Creating a consistent portable export…")
                        .font(.headline)
                    Text("Keep Epistoria open. Editing, sync changes, and section switching resume automatically after the archive is validated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Creating a consistent portable export. Editing is temporarily paused.")
            .accessibilityIdentifier("dataHealth.exportProgress")
        } header: {
            Text("Export in progress")
        }
    }

    private var syncSection: some View {
        Section("Sync status") {
            Label(model.syncStatusText, systemImage: model.syncStatusSymbol)
                .foregroundStyle(model.syncError == nil ? Color.primary : EpistoriaDesign.attention)
                .accessibilityIdentifier("dataHealth.syncStatus")
            LabeledContent("Pending records", value: (health?.pendingMutations ?? 0).formatted())
            LabeledContent("Pending files", value: (health?.pendingAssets ?? 0).formatted())
            LabeledContent("Unresolved conflicts", value: (health?.unresolvedConflicts ?? 0).formatted())
            if (health?.unresolvedConflicts ?? 0) > 0 {
                NavigationLink {
                    ConflictResolutionView(model: model) { Task { await load() } }
                } label: {
                    Label("Review preserved versions", systemImage: "arrow.triangle.branch")
                }
            }
            if let report = model.lastSyncReport {
                Text("Last run: \(report.pushedMutations) pushed, \(report.pulledChanges) pulled, \(report.uploadedAssets) files, \(report.conflictsCreated) conflicts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task {
                    await model.synchronize()
                    await load()
                }
            } label: {
                if model.isSyncing {
                    Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(model.isSyncing || model.syncEngine == nil)
            .accessibilityIdentifier("dataHealth.syncNow")
        }
    }

    private var serverSection: some View {
        Section {
            if model.configuration?.serverConnected == true,
               model.api != nil,
               !showServerSetup
            {
                Label(model.configuration?.apiURL?.absoluteString ?? "Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(EpistoriaDesign.positive)
                Button("Change or repair connection", systemImage: "wrench.and.screwdriver") {
                    showServerSetup = true
                }
            } else {
                if model.configuration?.serverConnected == true, model.api == nil {
                    Label("Sync credentials are unavailable. Reconnect to keep local work syncing.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(EpistoriaDesign.attention)
                }
                TextField("API URL", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Bootstrap secret", text: $bootstrapSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Connect private server") { Task { await connect() } }
                    .disabled(isWorking || bootstrapSecret.count < 32)
                if model.configuration?.serverConnected == true {
                    Button("Cancel") {
                        bootstrapSecret = ""
                        showServerSetup = false
                    }
                }
            }
        } header: {
            Text("Optional private sync server")
        } footer: {
            Text("Use the private HTTPS or Tailscale address ending in /v1. Reconnecting rotates this iPad's device token without changing the account key.")
        }
    }

    private var macSection: some View {
        Section {
            Button("Create one-time Mac pairing material", systemImage: "desktopcomputer") {
                Task { await pairMac() }
            }
            .disabled(isWorking || model.api == nil)
        } header: {
            Text("Trusted Mac worker")
        } footer: {
            Text("The Mac worker is required only for PDF text extraction and optional AI jobs. It stores the account key in macOS Keychain; the server never receives it.")
        }
    }

    private var devicesSection: some View {
        Section {
            if model.api == nil {
                Text("Connect a private sync server to view and revoke enrolled devices.")
                    .foregroundStyle(.secondary)
            } else if isLoadingDevices {
                ProgressView("Loading trusted devices…")
            } else if devices.isEmpty, hasLoadedDevices, deviceListError == nil {
                Label("No trusted devices were returned by the server.", systemImage: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(devices) { device in
                    HStack(spacing: 12) {
                        Image(systemName: device.kind == "MAC" ? "desktopcomputer" : "ipad")
                            .foregroundStyle(EpistoriaDesign.accent)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text(device.id == model.configuration?.deviceId ? "This iPad" : device.kind.capitalized)
                                    .font(.headline)
                                if device.revokedAt != nil {
                                    EpistoriaStatusPill(title: "Revoked", symbol: "xmark.circle")
                                }
                            }
                            Text(deviceDetail(device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if device.id != model.configuration?.deviceId, device.revokedAt == nil {
                            Button("Revoke", role: .destructive) {
                                pendingDeviceRevocation = device
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Revoke \(device.kind.capitalized) device")
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            if let deviceListError {
                Label(deviceListError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(EpistoriaDesign.attention)
                Button("Try loading devices again") { Task { await loadDevices() } }
            }
        } header: {
            Text("Trusted devices")
        } footer: {
            Text("Revoke a lost or retired Mac here. Revocation stops future server access but cannot remotely erase data already stored on that device.")
        }
    }

    private var recoverySection: some View {
        Section {
            Button("Reveal recovery kit", systemImage: "key") {
                do { recoveryWords = try model.recoveryWords() }
                catch { errorMessage = error.localizedDescription }
            }
        } header: {
            Text("Recovery")
        } footer: {
            Text("Keep the 24 words and account ID offline. They are more important than any server backup because Epistoria cannot decrypt a backup without them.")
        }
    }

    private var exportSection: some View {
        Section {
            Toggle("Include reviewed AI artifacts", isOn: $includeDerivedAI)
            Button("Create portable export", systemImage: "square.and.arrow.up") {
                showExportConfirmation = true
            }
            .disabled(isWorking)
            .accessibilityIdentifier("dataHealth.createExport")
            Button("Verify an unzipped export", systemImage: "checkmark.seal") {
                isChoosingExportDirectory = true
            }
            .disabled(isWorking)
            if let validationMessage {
                Label(validationMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(EpistoriaDesign.positive)
            }
        } header: {
            Text("Portable export")
        } footer: {
            Text("The generated ZIP is validated with SHA-256 checksums and includes open JSON, original PDFs, and original PencilKit drawing data. It is readable, so store it securely.")
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced diagnostics", isExpanded: $showAdvanced) {
                if let configuration = model.configuration {
                    LabeledContent("Account ID", value: configuration.accountId.uuidString.lowercased())
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    LabeledContent("iPad device ID", value: configuration.deviceId.uuidString.lowercased())
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Server cursor", value: health?.lastServerSequence ?? "0")
                    .font(.caption.monospaced())
                VStack(alignment: .leading, spacing: 8) {
                    Label("Lowest-cost profile", systemImage: "laptopcomputer")
                        .font(.headline)
                    Text("Mac-hosted Docker plus private networking has no required recurring infrastructure cost, but sync pauses while the Mac sleeps.")
                    Label("Always-on profile", systemImage: "cloud")
                        .font(.headline)
                        .padding(.top, 4)
                    Text("A small VM, independent backups, and object storage add convenience without changing the encryption boundary.")
                    Text("AI remains optional and pay-per-use. Core notebook features never require an AI subscription.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func healthRow(_ title: String, value: String, symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        do {
            health = try await model.database?.dataHealth()
            await model.refreshDataHealth()
            if let configured = model.configuration?.apiURL?.absoluteString {
                serverURL = configured
            }
        } catch { errorMessage = error.localizedDescription }
        await loadDevices()
    }

    private func loadDevices() async {
        guard model.api != nil else {
            devices = []
            deviceListError = nil
            hasLoadedDevices = false
            return
        }
        guard !isLoadingDevices else { return }
        isLoadingDevices = true
        defer { isLoadingDevices = false }
        do {
            devices = try await model.trustedDevices()
            deviceListError = nil
            hasLoadedDevices = true
        } catch is CancellationError {
            return
        } catch {
            deviceListError = "Device roster is temporarily unavailable: \(error.localizedDescription)"
            hasLoadedDevices = true
        }
    }

    private func connect() async {
        guard let url = PrivateServerEndpoint.validatedURL(from: serverURL) else {
            errorMessage = "Enter a full HTTP or HTTPS API URL ending in /v1."
            return
        }
        serverURL = url.absoluteString
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.connectServer(apiURL: url, bootstrapSecret: bootstrapSecret)
            bootstrapSecret = ""
            showServerSetup = false
            await model.synchronize()
            await load()
        } catch is CancellationError {
            return
        } catch { errorMessage = error.localizedDescription }
    }

    private func pairMac() async {
        isWorking = true
        defer { isWorking = false }
        do {
            pairing = try await model.enrollMac()
            await loadDevices()
        } catch is CancellationError {
            return
        }
        catch { errorMessage = error.localizedDescription }
    }

    private func revoke(_ device: DeviceSummary) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.revokeTrustedDevice(id: device.id)
            await loadDevices()
        } catch {
            errorMessage = "The device could not be revoked: \(error.localizedDescription)"
        }
    }

    private func deviceDetail(_ device: DeviceSummary) -> String {
        let idSuffix = String(device.id.uuidString.lowercased().suffix(8))
        guard let lastSeen = RFC3339Milliseconds.date(from: device.lastSeenAt) else {
            return "ID …\(idSuffix)"
        }
        return "Last seen \(lastSeen.formatted(.relative(presentation: .named))) · ID …\(idSuffix)"
    }

    private func createExport() async {
        isWorking = true
        defer { isWorking = false }
        do {
            exportResult = try await model.createPortableExport(
                includingDerivedAI: includeDerivedAI
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeExport(_ result: EpistoriaExportResult) {
        do {
            try EpistoriaExportService.removeTemporaryArchive(result.archiveURL)
            exportResult = nil
        } catch {
            errorMessage = "The temporary readable export could not be removed: \(error.localizedDescription)"
        }
    }

    private func validateExport(_ result: Result<[URL], Error>) async {
        guard let configuration = model.configuration,
              let store = model.store,
              let database = model.database,
              let assetManager = model.assetManager
        else {
            errorMessage = EpistoriaExportError.dependenciesUnavailable.localizedDescription
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            guard let directory = try result.get().first else { return }
            let service = EpistoriaExportService(
                accountId: configuration.accountId,
                store: store,
                database: database,
                assetManager: assetManager
            )
            let validation = try await service.validateDecryptedDirectory(at: directory)
            validationMessage = "Validated \(validation.fileCount) files (\(ByteCountFormatter.string(fromByteCount: validation.byteCount, countStyle: .file)))."
        } catch {
            validationMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func discardSensitiveState() {
        bootstrapSecret = ""
        recoveryWords = nil
        pairing = nil
        pendingDeviceRevocation = nil
        if let exportResult {
            do {
                try EpistoriaExportService.removeTemporaryArchive(exportResult.archiveURL)
                self.exportResult = nil
            } catch {
                errorMessage = "The temporary readable export still needs cleanup: \(error.localizedDescription)"
            }
        }
    }
}

private struct ExportReadyView: View {
    let result: EpistoriaExportResult
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Label("Export validated", systemImage: "checkmark.seal.fill")
                    .font(.title2.bold())
                    .foregroundStyle(EpistoriaDesign.positive)
                Text("\(result.fileCount) files · \(ByteCountFormatter.string(fromByteCount: result.byteCount, countStyle: .file))")
                    .foregroundStyle(.secondary)
                Label(
                    "This archive is readable personal data. Save it only to an encrypted drive or another location you trust.",
                    systemImage: "exclamationmark.shield"
                )
                .foregroundStyle(EpistoriaDesign.attention)
                ShareLink(item: result.archiveURL) {
                    Label("Save or share export", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("export.share")
                Spacer()
            }
            .padding(30)
            .navigationTitle("Portable export")
            .toolbar { Button("Done") { onDone() } }
        }
        .interactiveDismissDisabled()
    }
}

private struct RecoveryExportView: View {
    let accountId: UUID?
    let words: String
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Secret recovery material", systemImage: "exclamationmark.shield")
                        .font(.title2.bold())
                        .foregroundStyle(EpistoriaDesign.attention)
                    Text("Do not paste this into chat, email, cloud notes, or screenshots. Write it down and store it separately from your iPad.")
                    Text(words)
                        .font(.title3.monospaced().bold())
                        .textSelection(.enabled)
                        .privacySensitive()
                        .padding()
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                    if let accountId {
                        Text("Account ID\n\(accountId.uuidString.lowercased())")
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .privacySensitive()
                    }
                }
                .padding(30)
            }
            .navigationTitle("Recovery kit")
            .toolbar { Button("Hide") { onDone() } }
        }
        .interactiveDismissDisabled()
    }
}

private struct PairMacView: View {
    @Environment(\.dismiss) private var dismiss
    let material: MacPairingMaterial
    let apiURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Complete this on your trusted Mac")
                        .font(.title2.bold())
                    Text("1. From the repository root, run `make worker-install`. Copy services/worker/.env.example to services/worker/.env and add these values. Keep that file private; the device token is shown only now.")
                    secretValue("EPISTORIA_API_URL", apiURL?.absoluteString ?? "")
                    secretValue("EPISTORIA_ACCOUNT_ID", material.accountId.uuidString.lowercased())
                    secretValue("EPISTORIA_DEVICE_ID", material.deviceId.uuidString.lowercased())
                    secretValue("EPISTORIA_DEVICE_TOKEN", material.deviceToken)
                    Text("2. Run `./scripts/run-worker.sh key-import`. Type the 24 words from your offline recovery kit only at its hidden prompt.")
                    Text("3. Run `./scripts/run-worker.sh doctor`, then `make worker-service-install` to start the supported background service.")
                    Label("Epistoria does not show the recovery words in this pairing sheet. Never place them in a shell command, environment variable, QR code, or pairing file.", systemImage: "hand.raised.fill")
                        .foregroundStyle(EpistoriaDesign.attention)
                }
                .padding(30)
            }
            .navigationTitle("Pair Mac")
            .toolbar { Button("Done") { dismiss() } }
        }
        .interactiveDismissDisabled()
    }

    private func secretValue(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.caption.bold())
            Text(value)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .privacySensitive()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
