import Foundation
import Observation

@MainActor
@Observable
final class LocalProcessingSettings {
    private enum Key {
        static let automaticNotebookOCR = "localProcessing.automaticNotebookOCR"
        static let automaticSourceOCR = "localProcessing.automaticSourceOCR"
        static let localMathOCR = "localProcessing.localMathOCR"
        static let preferredLanguages = "localProcessing.preferredLanguages"
    }

    var automaticNotebookOCR: Bool {
        didSet { defaults.set(automaticNotebookOCR, forKey: Key.automaticNotebookOCR) }
    }
    var automaticSourceOCR: Bool {
        didSet { defaults.set(automaticSourceOCR, forKey: Key.automaticSourceOCR) }
    }
    var localMathOCR: Bool {
        didSet { defaults.set(localMathOCR, forKey: Key.localMathOCR) }
    }
    var preferredLanguages: [String] {
        didSet { defaults.set(preferredLanguages, forKey: Key.preferredLanguages) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticNotebookOCR = defaults.object(forKey: Key.automaticNotebookOCR) as? Bool ?? true
        automaticSourceOCR = defaults.object(forKey: Key.automaticSourceOCR) as? Bool ?? true
        localMathOCR = defaults.object(forKey: Key.localMathOCR) as? Bool ?? false
        let stored = defaults.stringArray(forKey: Key.preferredLanguages) ?? []
        preferredLanguages = stored.isEmpty
            ? Array(Locale.preferredLanguages.prefix(3))
            : stored
    }

    var normalizedLanguages: [String] {
        var seen = Set<String>()
        return preferredLanguages.compactMap { value in
            let language = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
            guard !language.isEmpty, seen.insert(language).inserted else { return nil }
            return language
        }
    }
}
