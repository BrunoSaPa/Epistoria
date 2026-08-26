import EpistoriaCore
import SwiftUI
import UIKit

struct OCRReviewView: View {
    @Bindable var model: AppModel
    let parentId: UUID
    @Binding var artifacts: [IdentifiedPayload<OCRArtifactPayload>]
    let onCreateEquation: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if artifacts.isEmpty {
                    ContentUnavailableView(
                        "No recognized handwriting",
                        systemImage: "text.viewfinder",
                        description: Text(
                            "Run local recognition, then sync the encrypted result to this device."
                        )
                    )
                } else {
                    List(artifacts, id: \.id) { artifact in
                        NavigationLink {
                            OCRArtifactReviewDetail(
                                model: model,
                                artifact: artifact,
                                onUpdated: replace,
                                onCreateEquation: onCreateEquation
                            )
                        } label: {
                            OCRArtifactReviewRow(artifact: artifact.payload)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Recognized text")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await reload() }
        }
    }

    private func reload() async {
        guard let store = model.store else { return }
        artifacts = (try? await store.ocrArtifacts(parentId: parentId)) ?? artifacts
    }

    private func replace(_ changed: IdentifiedPayload<OCRArtifactPayload>) {
        guard let index = artifacts.firstIndex(where: { $0.id == changed.id }) else { return }
        artifacts[index] = changed
    }
}

private struct OCRArtifactReviewRow: View {
    let artifact: OCRArtifactPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(sourceLabel, systemImage: "text.viewfinder")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(stateLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(artifact.recognizedText.isEmpty ? "No text detected" : artifact.recognizedText)
                .lineLimit(3)
                .foregroundStyle(artifact.recognizedText.isEmpty ? .secondary : .primary)
            if artifact.state == .stale {
                Text("The original ink changed after this result was created.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var sourceLabel: String {
        switch artifact.targetKind {
        case .notebookRegion: "Recognized from handwriting"
        case .image: "Recognized from image"
        case .sourcePage: "Recognized from scanned Source"
        }
    }

    private var stateLabel: String {
        if artifact.state == .stale { return "Stale" }
        switch artifact.reviewState {
        case .accepted: return "Accepted"
        case .edited: return "Corrected"
        case .rejected: return "Rejected"
        case nil: return "Review"
        }
    }
}

private struct OCRArtifactReviewDetail: View {
    @Bindable var model: AppModel
    @State private var current: IdentifiedPayload<OCRArtifactPayload>
    @State private var draftByRegion: [UUID: String]
    @State private var baselineByRegion: [UUID: String]
    @State private var errorMessage: String?
    @State private var hasCorrectionConflict = false
    @State private var correctionConflicts: [UUID: [String]] = [:]
    let onUpdated: (IdentifiedPayload<OCRArtifactPayload>) -> Void
    let onCreateEquation: ((String) -> Void)?

    init(
        model: AppModel,
        artifact: IdentifiedPayload<OCRArtifactPayload>,
        onUpdated: @escaping (IdentifiedPayload<OCRArtifactPayload>) -> Void,
        onCreateEquation: ((String) -> Void)?
    ) {
        self.model = model
        _current = State(initialValue: artifact)
        _draftByRegion = State(initialValue: Dictionary(uniqueKeysWithValues: artifact.payload.response.regions.map {
            ($0.id, $0.latex ?? $0.text)
        }))
        _baselineByRegion = State(initialValue: Dictionary(uniqueKeysWithValues: artifact.payload.response.regions.map {
            ($0.id, $0.latex ?? $0.text)
        }))
        self.onUpdated = onUpdated
        self.onCreateEquation = onCreateEquation
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                originalPreview
                ForEach(current.payload.response.regions) { region in
                    regionEditor(region)
                }
                if !current.payload.response.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recognition notes").font(.headline)
                        ForEach(current.payload.response.warnings, id: \.self) { Text($0) }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Review recognition")
        .task { await loadResolvedDrafts() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Reject", role: .destructive) { Task { await review(.rejected) } }
                Button(hasCorrectionConflict ? "Resolve edits" : "Accept") {
                    Task { await acceptChanges(resolvingConflicts: hasCorrectionConflict) }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        current.payload.state == .stale
                            || current.payload.response.regions.isEmpty
                    )
            }
        }
        .alert("Recognition review problem", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var originalPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Original selection").font(.headline)
            if let encoded = current.payload.inputPreview,
                let data = Data(base64Encoded: encoded),
                let image = UIImage(data: data)
            {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }
                    .accessibilityLabel("Original handwriting crop")
            } else {
                Text("The encrypted preview is not available on this device.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func regionEditor(_ region: LocalOCRRegion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(region.kind == .formula ? "LaTeX" : "Text").font(.headline)
                Spacer()
                Text(confidenceLabel(region))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: Binding(
                get: { draftByRegion[region.id] ?? "" },
                set: { draftByRegion[region.id] = $0 }
            ))
            .font(region.kind == .formula ? .system(.body, design: .monospaced) : .body)
            .frame(minHeight: 88)
            .padding(8)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if let choices = correctionConflicts[region.id] {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Conflicting saved edits").font(.caption.weight(.semibold))
                    ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                        Button(choice) { draftByRegion[region.id] = choice }
                            .buttonStyle(.borderless)
                            .lineLimit(3)
                    }
                    Text("Choose one or edit the field, then select Resolve edits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Copy") { UIPasteboard.general.string = draftByRegion[region.id] }
                if region.kind == .formula, let onCreateEquation {
                    Button("Create equation") {
                        let value = draftByRegion[region.id] ?? ""
                        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            return
                        }
                        onCreateEquation(value)
                    }
                    .disabled(!canCreateEquation)
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private func confidenceLabel(_ region: LocalOCRRegion) -> String {
        guard let confidence = region.confidence else { return "Unverified" }
        return "\(Int((confidence * 100).rounded()))% confidence"
    }

    private var canCreateEquation: Bool {
        guard current.payload.state == .current,
              let review = current.payload.reviewState
        else { return false }
        return review == .accepted || review == .edited
    }

    private func acceptChanges(resolvingConflicts: Bool = false) async {
        guard let store = model.store else { return }
        do {
            var changed = false
            for region in current.payload.response.regions {
                let original = baselineByRegion[region.id] ?? region.latex ?? region.text
                let draft = (draftByRegion[region.id] ?? original)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !draft.isEmpty else { continue }
                if draft != original
                    || (resolvingConflicts && correctionConflicts[region.id] != nil)
                {
                    _ = try await store.createOCRCorrection(
                        artifactId: current.id,
                        regionId: region.id,
                        correctedText: draft,
                        resolvesConflict: resolvingConflicts
                    )
                    changed = true
                }
            }
            await review(changed ? .edited : .accepted)
            if resolvingConflicts {
                hasCorrectionConflict = false
                correctionConflicts = [:]
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadResolvedDrafts() async {
        guard let store = model.store else { return }
        do {
            let resolved = try await store.resolvedOCRRegions(artifactId: current.id)
            let values = Dictionary(uniqueKeysWithValues: resolved.map {
                ($0.region.id, $0.content)
            })
            draftByRegion = values
            baselineByRegion = values
        } catch {
            hasCorrectionConflict = true
            correctionConflicts = (try? await store.ocrCorrectionConflicts(
                artifactId: current.id
            )) ?? [:]
            errorMessage = "This recognition has conflicting corrections. Resolve the synchronized conflict before using it."
        }
    }

    private func review(_ state: AIArtifactReviewState) async {
        guard let store = model.store else { return }
        do {
            try await store.reviewOCRArtifact(id: current.id, state: state)
            current = try await store.payload(OCRArtifactPayload.self, id: current.id)
            model.noteLocalMutation()
            onUpdated(current)
        } catch { errorMessage = error.localizedDescription }
    }
}
