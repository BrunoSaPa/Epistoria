import Foundation

struct AccountConfiguration: Codable, Equatable {
    var accountId: UUID
    var deviceId: UUID
    var apiURL: URL?
    var serverConnected: Bool
}

@MainActor
final class AccountConfigurationStore {
    private let key = "epistoria.account-configuration.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AccountConfiguration? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AccountConfiguration.self, from: data)
    }

    func save(_ configuration: AccountConfiguration) throws {
        defaults.set(try JSONEncoder().encode(configuration), forKey: key)
    }
}

