import EpistoriaCore
import Foundation
@preconcurrency import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let progress = UIActivityIndicatorView(style: .medium)
    private let doneButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureInterface()
        Task { await captureInput() }
    }

    private func configureInterface() {
        view.backgroundColor = .systemBackground
        view.layer.cornerRadius = 20
        view.layer.cornerCurve = .continuous

        let mark = UIView()
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.backgroundColor = .label
        mark.layer.cornerRadius = 8
        mark.isAccessibilityElement = false
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 16),
            mark.heightAnchor.constraint(equalToConstant: 16),
        ])

        let title = UILabel()
        title.text = "Epistoria"
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true

        let brand = UIStackView(arrangedSubviews: [mark, title])
        brand.axis = .horizontal
        brand.alignment = .center
        brand.spacing = 12

        statusLabel.text = "Preparing capture"
        statusLabel.font = .preferredFont(forTextStyle: .title2)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0

        detailLabel.text = "The item is encrypted on this device before it enters Source Inbox."
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.textColor = .secondaryLabel
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.numberOfLines = 0

        progress.startAnimating()
        progress.setContentHuggingPriority(.required, for: .horizontal)
        let statusRow = UIStackView(arrangedSubviews: [progress, statusLabel])
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = 12

        doneButton.configuration = .filled()
        doneButton.configuration?.baseBackgroundColor = .label
        doneButton.configuration?.baseForegroundColor = .systemBackground
        doneButton.configuration?.title = "Done"
        doneButton.isHidden = true
        doneButton.addAction(UIAction { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }, for: .touchUpInside)

        cancelButton.configuration = .plain()
        cancelButton.configuration?.title = "Cancel"
        cancelButton.addAction(UIAction { [weak self] _ in
            let error = NSError(
                domain: NSCocoaErrorDomain,
                code: NSUserCancelledError,
                userInfo: nil
            )
            self?.extensionContext?.cancelRequest(withError: error)
        }, for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [cancelButton, doneButton])
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 12

        let stack = UIStackView(arrangedSubviews: [brand, statusRow, detailLabel, buttons])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 18
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
    }

    private func captureInput() async {
        do {
            guard let inbox = SharedCaptureInbox.live() else {
                throw SharedCaptureInboxError.unavailable
            }
            let key = try SharedCaptureKeyStore.configured().loadOrCreate()
            let extensionItems = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
            let providers = extensionItems.flatMap { $0.attachments ?? [] }
            guard !providers.isEmpty, providers.count <= 10 else {
                throw SharedCaptureInboxError.invalidItem
            }

            var saved = 0
            var failures: [Error] = []
            for (index, provider) in providers.enumerated() {
                statusLabel.text = "Encrypting \(index + 1) of \(providers.count)"
                do {
                    let title = extensionItems
                        .first(where: { $0.attachments?.contains(where: { $0 === provider }) == true })?
                        .attributedTitle?.string
                    let item = try await sharedCapture(from: provider, title: title)
                    try inbox.enqueue(item, key: key)
                    saved += 1
                } catch {
                    failures.append(error)
                }
            }
            guard saved > 0 else { throw failures.first ?? SharedCaptureInboxError.invalidItem }

            progress.stopAnimating()
            progress.isHidden = true
            statusLabel.text = saved == 1 ? "Saved to Source Inbox" : "Saved \(saved) items to Source Inbox"
            if failures.isEmpty {
                detailLabel.text = "Open Epistoria to validate and import the encrypted capture."
            } else {
                detailLabel.text = "\(failures.count) item\(failures.count == 1 ? " was" : "s were") not saved. Files shared this way must be supported and 32 MB or smaller."
            }
            cancelButton.isHidden = true
            doneButton.isHidden = false
        } catch {
            progress.stopAnimating()
            progress.isHidden = true
            statusLabel.text = "Capture not saved"
            detailLabel.text = error.localizedDescription
            cancelButton.configuration?.title = "Close"
        }
    }

    private func sharedCapture(from provider: NSItemProvider, title: String?) async throws -> SharedCaptureItem {
        if let imageType = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) {
            let data = try await loadFileData(provider, typeIdentifier: imageType)
            let type = UTType(imageType)
            let filename = resolvedFilename(
                suggestedName: provider.suggestedName,
                fallback: "Shared image",
                type: type
            )
            return SharedCaptureItem(
                kind: .image,
                filename: filename,
                typeIdentifier: imageType,
                title: title,
                payload: data
            )
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let url = try await loadURL(provider)
            if !url.isFileURL {
                return SharedCaptureItem(
                    kind: .link,
                    typeIdentifier: UTType.url.identifier,
                    title: title,
                    payload: Data(url.absoluteString.utf8)
                )
            }
            let data = try readFileData(at: url)
            let type = UTType(filenameExtension: url.pathExtension)
            return SharedCaptureItem(
                kind: type?.conforms(to: .image) == true ? .image : .file,
                filename: resolvedFilename(
                    suggestedName: provider.suggestedName ?? url.lastPathComponent,
                    fallback: "Shared file",
                    type: type
                ),
                typeIdentifier: type?.identifier ?? UTType.data.identifier,
                title: title,
                payload: data
            )
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let text = try await loadText(provider)
            return SharedCaptureItem(
                kind: .text,
                filename: "Shared text.txt",
                typeIdentifier: UTType.plainText.identifier,
                title: title,
                payload: Data(text.utf8)
            )
        }

        guard let fileTypeIdentifier = provider.registeredTypeIdentifiers.first(where: {
            guard let type = UTType($0) else { return false }
            return type.conforms(to: .data) || type.conforms(to: .content)
        }) else {
            throw SharedCaptureInboxError.invalidItem
        }
        let data = try await loadFileData(provider, typeIdentifier: fileTypeIdentifier)
        let type = UTType(fileTypeIdentifier)
        let filename = resolvedFilename(
            suggestedName: provider.suggestedName,
            fallback: "Shared file",
            type: type
        )
        return SharedCaptureItem(
            kind: .file,
            filename: filename,
            typeIdentifier: fileTypeIdentifier,
            title: title,
            payload: data
        )
    }

    private func loadFileData(_ provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _, error in
                if let error { continuation.resume(throwing: error); return }
                guard let url else {
                    continuation.resume(throwing: SharedCaptureInboxError.invalidItem)
                    return
                }
                do {
                    continuation.resume(returning: try self.readFileData(at: url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private func readFileData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw SharedCaptureInboxError.invalidItem
        }
        if let size = values.fileSize,
           size > SharedCaptureInbox.maximumPayloadBytes {
            throw SharedCaptureInboxError.itemTooLarge
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty else { throw SharedCaptureInboxError.invalidItem }
        guard data.count <= SharedCaptureInbox.maximumPayloadBytes else {
            throw SharedCaptureInboxError.itemTooLarge
        }
        return data
    }

    private func loadURL(_ provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { value, error in
                if let error { continuation.resume(throwing: error); return }
                if let url = value as? URL {
                    continuation.resume(returning: url)
                } else if let data = value as? Data,
                          let text = String(data: data, encoding: .utf8),
                          let url = URL(string: text) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: SharedCaptureInboxError.invalidItem)
                }
            }
        }
    }

    private func loadText(_ provider: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { value, error in
                if let error { continuation.resume(throwing: error); return }
                if let string = value as? String, !string.isEmpty {
                    guard string.utf8.count <= SharedCaptureInbox.maximumPayloadBytes else {
                        continuation.resume(throwing: SharedCaptureInboxError.itemTooLarge)
                        return
                    }
                    continuation.resume(returning: string)
                } else if let attributed = value as? NSAttributedString, !attributed.string.isEmpty {
                    guard attributed.string.utf8.count <= SharedCaptureInbox.maximumPayloadBytes else {
                        continuation.resume(throwing: SharedCaptureInboxError.itemTooLarge)
                        return
                    }
                    continuation.resume(returning: attributed.string)
                } else if let data = value as? Data,
                          let string = String(data: data, encoding: .utf8),
                          !string.isEmpty {
                    continuation.resume(returning: string)
                } else {
                    continuation.resume(throwing: SharedCaptureInboxError.invalidItem)
                }
            }
        }
    }

    private func resolvedFilename(suggestedName: String?, fallback: String, type: UTType?) -> String {
        let proposed = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let leaf = (proposed as NSString).lastPathComponent
            .replacingOccurrences(of: "\\", with: "-")
        var filename = leaf.isEmpty || leaf == "." || leaf == ".."
            ? fallback
            : String(leaf.prefix(220))
        if URL(fileURLWithPath: filename).pathExtension.isEmpty,
           let fileExtension = type?.preferredFilenameExtension {
            filename += ".\(fileExtension)"
        }
        return filename
    }
}
