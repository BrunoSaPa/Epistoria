import EpistoriaCore
import XCTest
@testable import Epistoria

@MainActor
final class AIProviderProfileStoreTests: XCTestCase {
    func testProfileMetadataRoundTripsWithoutSecretField() throws {
        let suite = "AIProviderProfileStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AIProviderProfileStore(defaults: defaults)
        let accountId = UUID()
        let profile = AIProviderProfile(
            id: UUID(),
            configurationRevisionId: UUID(),
            displayName: "Local test",
            adapter: .openAICompatible,
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:11434/v1")),
            textModel: "test-model",
            transcriptionModel: nil,
            capabilities: [.text],
            structuredOutput: true,
            inputUSDPerMillion: nil,
            outputUSDPerMillion: nil,
            transcriptionUSDPerMinute: nil,
            isActive: true,
            state: .ready,
            pendingOperation: nil,
            lastJobId: nil,
            lastErrorCode: nil,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        try store.save([profile], accountId: accountId)

        XCTAssertEqual(try store.load(accountId: accountId), [profile])
        let stored = try XCTUnwrap(
            defaults.data(forKey: "epistoria.ai-provider-profiles.v1.\(accountId.uuidString.lowercased())")
        )
        XCTAssertNil(String(data: stored, encoding: .utf8)?.range(of: "apiKey"))
    }

    func testURLPolicyAllowsOnlyLocalHTTPOrHTTPS() throws {
        XCTAssertEqual(
            AIProviderURLPolicy.normalized(
                "http://localhost:11434",
                adapter: .openAICompatible
            )?.absoluteString,
            "http://localhost:11434/v1"
        )
        XCTAssertEqual(
            AIProviderURLPolicy.normalized(
                "https://models.example.test/v1/",
                adapter: .openAICompatible
            )?.absoluteString,
            "https://models.example.test/v1"
        )
        XCTAssertNil(
            AIProviderURLPolicy.normalized(
                "http://models.example.test/v1",
                adapter: .openAICompatible
            )
        )
        XCTAssertNil(
            AIProviderURLPolicy.normalized(
                "https://key@models.example.test/v1",
                adapter: .openAICompatible
            )
        )
        XCTAssertNil(
            AIProviderURLPolicy.normalized(
                "http://10.example.test/v1",
                adapter: .openAICompatible
            )
        )
    }

    func testHostedAdaptersUseFixedEndpoints() {
        XCTAssertEqual(
            AIProviderURLPolicy.normalized("ignored", adapter: .openAIResponses)?.absoluteString,
            "https://api.openai.com/v1"
        )
        XCTAssertEqual(
            AIProviderURLPolicy.normalized("ignored", adapter: .anthropicMessages)?.absoluteString,
            "https://api.anthropic.com/v1"
        )
        XCTAssertEqual(
            AIProviderURLPolicy.normalized(
                "ignored",
                adapter: .geminiGenerateContent
            )?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta"
        )
    }

    func testLegacyProfileWithoutConfigurationRevisionUsesStableProfileFallback() throws {
        let suite = "AIProviderProfileStoreTests.legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accountId = UUID()
        let profileId = UUID()
        let key = "epistoria.ai-provider-profiles.v1.\(accountId.uuidString.lowercased())"
        let data = try XCTUnwrap(
            """
            [{
              "id":"\(profileId.uuidString)",
              "displayName":"Existing local model",
              "adapter":"OPENAI_COMPATIBLE",
              "baseURL":"http://127.0.0.1:11434/v1",
              "textModel":"legacy-model",
              "capabilities":["TEXT"],
              "structuredOutput":true,
              "isActive":true,
              "state":"READY",
              "updatedAt":0
            }]
            """.data(using: .utf8)
        )
        defaults.set(data, forKey: key)

        let profile = try XCTUnwrap(
            AIProviderProfileStore(defaults: defaults).load(accountId: accountId).first
        )
        XCTAssertNil(profile.configurationRevisionId)
        XCTAssertEqual(profile.routeSnapshot.configurationRevisionId, profileId)
    }
}
