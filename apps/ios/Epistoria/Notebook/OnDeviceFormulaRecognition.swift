@preconcurrency import CoreML
import CryptoKit
import EpistoriaCore
import Foundation
import UIKit

struct FormulaModelManifest: Codable, Equatable, Sendable {
    let modelId: String
    let version: String
    let downloadURL: URL
    let byteCount: Int64
    let sha256: String
    let license: String
    let attribution: String
    let inputFeatureName: String
    let outputFeatureName: String
}

enum OnDeviceFormulaModelState: Equatable, Sendable {
    case unavailable
    case notInstalled
    case installing(progress: Double?)
    case installed(version: String)
    case invalid
}

enum OnDeviceFormulaModelError: Error, LocalizedError {
    case manifestUnavailable
    case invalidManifest
    case downloadFailed
    case sizeMismatch
    case checksumMismatch
    case compilationFailed
    case modelUnavailable
    case invalidInput
    case unsupportedModelContract

    var errorDescription: String? {
        switch self {
        case .manifestUnavailable: "The on-device formula model is still being validated for release."
        case .invalidManifest: "The formula model manifest is invalid."
        case .downloadFailed: "The formula model could not be downloaded."
        case .sizeMismatch: "The formula model download has the wrong size."
        case .checksumMismatch: "The formula model download failed verification."
        case .compilationFailed: "The verified formula model could not be compiled on this iPad."
        case .modelUnavailable: "The on-device formula model is not installed."
        case .invalidInput: "The selected equation image could not be read."
        case .unsupportedModelContract: "The installed formula model does not match Epistoria's verified interface."
        }
    }
}

/// The production manifest remains nil until the converted model passes the Paddle parity,
/// latency, memory, thermal, and license gates. This prevents a development placeholder from
/// silently becoming a release dependency.
enum FormulaModelRegistry {
    static let productionManifest: FormulaModelManifest? = nil
}

actor OnDeviceFormulaModelManager {
    private let rootURL: URL
    private(set) var state: OnDeviceFormulaModelState = .unavailable

    init(rootURL: URL? = nil) {
        let base = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appending(path: "Epistoria", directoryHint: .isDirectory)
        self.rootURL = base.appending(path: "Models/Formula", directoryHint: .isDirectory)
        state = FormulaModelRegistry.productionManifest == nil ? .unavailable : .notInstalled
    }

    func refresh() {
        guard let manifest = FormulaModelRegistry.productionManifest else {
            state = .unavailable
            return
        }
        state = FileManager.default.fileExists(atPath: compiledURL(for: manifest).path)
            ? .installed(version: manifest.version) : .notInstalled
    }

    func installedModel() throws -> (FormulaModelManifest, URL) {
        guard let manifest = FormulaModelRegistry.productionManifest else {
            throw OnDeviceFormulaModelError.manifestUnavailable
        }
        let url = compiledURL(for: manifest)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OnDeviceFormulaModelError.modelUnavailable
        }
        return (manifest, url)
    }

    func install() async throws {
        guard let manifest = FormulaModelRegistry.productionManifest else {
            throw OnDeviceFormulaModelError.manifestUnavailable
        }
        guard manifest.downloadURL.scheme == "https", manifest.byteCount > 0,
              manifest.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
        else { throw OnDeviceFormulaModelError.invalidManifest }
        state = .installing(progress: nil)
        do {
            let (temporaryURL, response) = try await URLSession.shared.download(from: manifest.downloadURL)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode)
            else { throw OnDeviceFormulaModelError.downloadFailed }
            let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == manifest.byteCount else {
                throw OnDeviceFormulaModelError.sizeMismatch
            }
            let data = try Data(contentsOf: temporaryURL, options: [.mappedIfSafe])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == manifest.sha256 else { throw OnDeviceFormulaModelError.checksumMismatch }
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: rootURL.path
            )
            var excludedRoot = rootURL
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try excludedRoot.setResourceValues(resourceValues)
            let staging = rootURL.appending(path: "staging-\(UUID().uuidString).mlmodel")
            try data.write(to: staging, options: [.atomic, .completeFileProtection])
            let compiled: URL
            do {
                compiled = try await MLModel.compileModel(at: staging)
            } catch {
                throw OnDeviceFormulaModelError.compilationFailed
            }
            let destination = compiledURL(for: manifest)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: compiled, to: destination)
            try? FileManager.default.removeItem(at: staging)
            state = .installed(version: manifest.version)
        } catch {
            state = .notInstalled
            throw error
        }
    }

    func remove() throws {
        if let manifest = FormulaModelRegistry.productionManifest {
            try? FileManager.default.removeItem(at: compiledURL(for: manifest))
        }
        state = FormulaModelRegistry.productionManifest == nil ? .unavailable : .notInstalled
    }

    private func compiledURL(for manifest: FormulaModelManifest) -> URL {
        rootURL.appending(path: "\(manifest.modelId)-\(manifest.version).mlmodelc", directoryHint: .isDirectory)
    }
}

actor CoreMLFormulaRecognitionEngine: FormulaRecognitionEngine {
    nonisolated let capabilities: Set<ProcessingCapability> = [.formulaRecognition]

    private let modelManager: OnDeviceFormulaModelManager
    private var loadedModel: MLModel?
    private var loadedVersion: String?

    init(modelManager: OnDeviceFormulaModelManager) {
        self.modelManager = modelManager
    }

    func recognize(_ request: LocalOCRRequest) async throws -> LocalOCRResponse {
        guard request.mode == .formula || request.mode == .mixed,
              let imageData = Data(base64Encoded: request.imageContent),
              let image = UIImage(data: imageData)?.cgImage
        else { throw OnDeviceFormulaModelError.invalidInput }
        let (manifest, url) = try await modelManager.installedModel()
        let model: MLModel
        if let loadedModel, loadedVersion == manifest.version {
            model = loadedModel
        } else {
            let loaded = try await MLModel.load(contentsOf: url)
            loadedModel = loaded
            loadedVersion = manifest.version
            model = loaded
        }
        guard let inputConstraint = model.modelDescription
            .inputDescriptionsByName[manifest.inputFeatureName]?.imageConstraint else {
            throw OnDeviceFormulaModelError.unsupportedModelContract
        }
        let imageValue = try MLFeatureValue(cgImage: image, constraint: inputConstraint)
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            manifest.inputFeatureName: imageValue,
        ])
        // The engine actor serializes access to this model instance.
        let output = try await model.prediction(from: provider)
        guard let latex = output.featureValue(for: manifest.outputFeatureName)?.stringValue,
              !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OnDeviceFormulaModelError.unsupportedModelContract
        }
        return LocalOCRResponse(
            engine: .coreMLFormula,
            engineVersion: "coreml/v1",
            modelVersion: manifest.version,
            regions: [
                LocalOCRRegion(
                    kind: .formula,
                    text: latex,
                    latex: latex,
                    normalizedExpression: latex.trimmingCharacters(in: .whitespacesAndNewlines)
                ),
            ]
        )
    }
}
