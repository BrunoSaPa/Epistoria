import CryptoKit
import EpistoriaCore
import SwiftUI

@main
struct EpistoriaApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel

    init() {
        _model = State(initialValue: Self.makeModel())
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(model: model)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, next in
                    switch next {
                    case .background:
                        Task { await model.lock() }
                    case .active:
                        Task { await model.start() }
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }

    @MainActor
    private static func makeModel() -> AppModel {
        #if DEBUG
        let process = ProcessInfo.processInfo
        if process.arguments.contains("-ui-testing-ephemeral"),
           let rawIdentifier = process.environment["EPISTORIA_UI_TEST_RUN_ID"],
           let identifier = UUID(uuidString: rawIdentifier),
           let defaults = UserDefaults(
               suiteName: "com.epistoria.ui-tests.\(identifier.uuidString.lowercased())"
           ),
           let applicationSupport = FileManager.default.urls(
               for: .applicationSupportDirectory,
               in: .userDomainMask
           ).first
        {
            let suffix = identifier.uuidString.lowercased()
            let testKey = Data(SHA256.hash(data: Data(suffix.utf8)))
            let supportURL = applicationSupport
                .appendingPathComponent("EpistoriaUITests", isDirectory: true)
                .appendingPathComponent(suffix, isDirectory: true)
            return AppModel(
                configurationStore: AccountConfigurationStore(defaults: defaults),
                accountKeyStore: KeychainStore(service: "com.epistoria.ui-tests.account-key.\(suffix)"),
                tokenStore: DeviceTokenStore(service: "com.epistoria.ui-tests.device-token.\(suffix)"),
                aiProviderProfileStore: AIProviderProfileStore(defaults: defaults),
                aiProviderSecretStore: AIProviderSecretStore(
                    service: "com.epistoria.ui-tests.ai-provider-key.\(suffix)"
                ),
                localProcessingSettings: LocalProcessingSettings(defaults: defaults),
                formulaModelManager: OnDeviceFormulaModelManager(
                    rootURL: supportURL.appendingPathComponent("Models", isDirectory: true)
                ),
                workspacePreferences: WorkspacePreferences(defaults: defaults),
                sharedCaptureImporter: nil,
                isolatedUITestIdentity: (identifier, testKey),
                applicationSupportURL: supportURL
            )
        }
        #endif
        return AppModel()
    }
}
