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
}
