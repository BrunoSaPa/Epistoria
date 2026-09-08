import EpistoriaCore
import Foundation

extension AppModel {
    /// Tests the exact unsaved route shown in Settings. The response is discarded and no
    /// processing record, notebook content, or provider credential is synchronized.
    func testAIProviderProfile(
        _ proposed: AIProviderProfile,
        replacementSecret: String?
    ) async throws -> ProviderConnectionResult {
        guard let accountId = configuration?.accountId else {
            throw AppModelOperationError.aiProviderUnavailable
        }
        guard AIProviderURLPolicy.normalized(
            proposed.baseURL.absoluteString,
            adapter: proposed.adapter
        ) == proposed.baseURL else {
            throw AppModelOperationError.aiProviderURLInvalid
        }
        let profiles = try aiProviderProfileStore.load(accountId: accountId)
        let existing = profiles.first(where: { $0.id == proposed.id })
        let replacement = replacementSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedSecret = try aiProviderSecretStore.secret(
            accountId: accountId,
            profileId: proposed.id
        )
        let secret = replacement?.isEmpty == false
            ? replacement
            : (existing?.adapter == proposed.adapter && existing?.baseURL == proposed.baseURL ? storedSecret : nil)
        if proposed.adapter != .openAICompatible, secret?.isEmpty != false {
            throw AppModelOperationError.aiProviderSecretRequired
        }
        var tested = proposed
        tested.displayName = tested.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        tested.textModel = tested.textModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tested.capabilities.contains(.text) { tested.capabilities.append(.text) }
        return try await directProviderClient.testConnection(
            route: tested.routeSnapshot,
            apiKey: secret
        )
    }

}
