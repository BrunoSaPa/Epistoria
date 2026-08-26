import EpistoriaCore
import SwiftUI

// MARK: - Request

struct MathAssistanceSheetView: View {
    @Bindable var model: AppModel
    let noteId: UUID
    let selection: LassoSelection
    let onDismiss: () -> Void

    @State private var mode = MathAssistanceMode.recognize
    @State private var instructions = ""
    @State private var prepared: PreparedMathAssistanceRequest?
    @State private var isPreparing = false
    @State private var isSubmitting = false
    @State private var submitted = false
    @State private var errorMessage: String?

    private let maximumInstructionsLength = 2_000

    var body: some View {
        NavigationStack {
            Form {
                Section("Selected handwriting") {
                    LabeledContent(
                        "Canvas items",
                        value: selection.selectedBlockIds.count.formatted()
                    )
                    LabeledContent(
                        "Visual crops",
                        value: selection.drawingImagesByBlockId.count.formatted()
                    )
                }

                Section("Task") {
                    Picker("Math task", selection: $mode) {
                        ForEach(MathAssistanceMode.allCases, id: \.self) { value in
                            Label(value.title, systemImage: value.symbol).tag(value)
                        }
                    }
                    .accessibilityIdentifier("math-assistance.mode")

                    Label(mode.summary, systemImage: mode.symbol)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 88, maxHeight: 160)
                        .accessibilityLabel("Optional instructions")
                        .accessibilityIdentifier("math-assistance.instructions")
                    HStack {
                        Spacer()
                        Text("\(instructions.count) / \(maximumInstructionsLength)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Optional instructions")
                } footer: {
                    Text(
                        "Examples: solve using substitution, graph from −5 to 5, or check the second line only."
                    )
                }

                if prepared == nil, !submitted {
                    Section {
                        Button {
                            Task { await prepare() }
                        } label: {
                            HStack {
                                if isPreparing { ProgressView().padding(.trailing, 6) }
                                Text(isPreparing ? "Preparing…" : "Preview what leaves your Mac")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(isPreparing || instructions.count > maximumInstructionsLength)
                        .accessibilityIdentifier("math-assistance.prepare")
                    }
                }

                if let prepared, !submitted {
                    Section("What leaves your Mac") {
                        LabeledContent("Selected items", value: prepared.selectionCount.formatted())
                        LabeledContent(
                            "Nearby text items", value: prepared.contextCount.formatted())
                        LabeledContent("Visual crops", value: prepared.imageCount.formatted())
                        LabeledContent(
                            "Approximate tokens", value: prepared.approximateTokens.formatted())
                    }

                    Section {
                        Button {
                            Task { await submit(prepared) }
                        } label: {
                            HStack {
                                if isSubmitting { ProgressView().padding(.trailing, 6) }
                                Text(isSubmitting ? "Queuing…" : "Approve and queue")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(EpistoriaDesign.ink)
                        .disabled(isSubmitting)
                        .accessibilityIdentifier("math-assistance.submit")
                    } footer: {
                        Text(
                            "The selected crop and bounded nearby text go through your trusted Mac using the reviewed provider route. Your original Pencil strokes are not changed."
                        )
                    }
                }

                if submitted {
                    Section {
                        Label("Math request queued", systemImage: "checkmark.circle")
                            .font(.subheadline.weight(.medium))
                        Text(
                            "You can keep writing. Review the result from Math results in the notebook actions menu."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Button("Done") { onDismiss() }
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("math-assistance.done")
                    }
                }

                Section {
                    Label(
                        "Pencil validation pending",
                        systemImage: "pencil.tip.crop.circle.badge.exclamationmark"
                    )
                    .font(.subheadline.weight(.medium))
                    Text(
                        "Recognition can be uncertain. Check the transcription and every worked step before accepting or inserting it."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Handwritten math")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
            .onChange(of: mode) { _, _ in prepared = nil }
            .onChange(of: instructions) { _, _ in prepared = nil }
        }
    }

    private func prepare() async {
        guard let aiJobs = model.aiJobs else { return }
        isPreparing = true
        errorMessage = nil
        do {
            prepared = try await aiJobs.prepareMathAssistance(
                noteId: noteId,
                selectedBlockIds: selection.selectedBlockIds,
                selectionImagesByBlockId: selection.drawingImagesByBlockId,
                mode: mode,
                learnerInstructions: instructions
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isPreparing = false
    }

    private func submit(_ request: PreparedMathAssistanceRequest) async {
        guard let aiJobs = model.aiJobs else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            _ = try await aiJobs.submitMathAssistance(request)
            submitted = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isSubmitting = false
    }
}

// MARK: - Artifact list

struct MathAssistanceArtifactsView: View {
    @Bindable var model: AppModel
    let noteId: UUID
    let onInsertExpression: (String) -> Void
    let onInsertExplanation: (String) -> Void

    @State private var artifacts: [IdentifiedPayload<MathAssistanceArtifact>] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading math results…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if artifacts.isEmpty {
                    ContentUnavailableView {
                        Label("No math results yet", systemImage: "function")
                    } description: {
                        Text(
                            "Choose Math in the notebook tool rail, select handwriting, and queue a task."
                        )
                    }
                } else {
                    List(artifacts, id: \.id) { artifact in
                        NavigationLink {
                            MathAssistanceArtifactDetailView(
                                model: model,
                                artifact: artifact,
                                onInsertExpression: { expression in
                                    onInsertExpression(expression)
                                    dismiss()
                                },
                                onInsertExplanation: { explanation in
                                    onInsertExplanation(explanation)
                                    dismiss()
                                },
                                onReviewChanged: replace
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Label(
                                        artifact.payload.mode.title,
                                        systemImage: artifact.payload.mode.symbol
                                    )
                                    .font(.subheadline.weight(.medium))
                                    Spacer()
                                    if let state = artifact.payload.reviewState {
                                        Text(state.label)
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(artifact.payload.activeResponse.recognizedExpression)
                                    .font(.system(.body, design: .rounded))
                                    .lineLimit(2)
                                Text(artifact.payload.generatedAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Math results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let aiJobs = model.aiJobs else {
            isLoading = false
            return
        }
        artifacts = (try? await aiJobs.latestMathAssistanceArtifacts(noteId: noteId)) ?? []
        isLoading = false
    }

    private func replace(_ updated: IdentifiedPayload<MathAssistanceArtifact>) {
        guard let index = artifacts.firstIndex(where: { $0.id == updated.id }) else { return }
        artifacts[index] = updated
    }
}

// MARK: - Artifact review

struct MathAssistanceArtifactDetailView: View {
    @Bindable var model: AppModel
    let onInsertExpression: (String) -> Void
    let onInsertExplanation: (String) -> Void
    let onReviewChanged: (IdentifiedPayload<MathAssistanceArtifact>) -> Void

    @State private var current: IdentifiedPayload<MathAssistanceArtifact>
    @State private var draft: MathAssistanceResponse
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        model: AppModel,
        artifact: IdentifiedPayload<MathAssistanceArtifact>,
        onInsertExpression: @escaping (String) -> Void,
        onInsertExplanation: @escaping (String) -> Void,
        onReviewChanged: @escaping (IdentifiedPayload<MathAssistanceArtifact>) -> Void
    ) {
        self.model = model
        self.onInsertExpression = onInsertExpression
        self.onInsertExplanation = onInsertExplanation
        self.onReviewChanged = onReviewChanged
        _current = State(initialValue: artifact)
        _draft = State(initialValue: artifact.payload.activeResponse)
    }

    private var response: MathAssistanceResponse { current.payload.activeResponse }
    private var canInsert: Bool {
        current.payload.reviewState == .accepted || current.payload.reviewState == .edited
    }

    var body: some View {
        Form {
            Section("Recognition") {
                if isEditing {
                    TextField(
                        "Recognized expression", text: $draft.recognizedExpression, axis: .vertical)
                    TextField("LaTeX", text: $draft.latex, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                    TextField("Interpretation", text: $draft.interpretation, axis: .vertical)
                } else {
                    Text(response.recognizedExpression)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .textSelection(.enabled)
                    if !response.latex.isEmpty {
                        Text(response.latex)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Text(response.interpretation)
                        .font(.subheadline)
                }

                LabeledContent(
                    "Recognition confidence",
                    value: response.confidence.formatted(.percent.precision(.fractionLength(0)))
                )
            }

            if isEditing || !response.steps.isEmpty || response.finalAnswer != nil {
                Section("Worked solution") {
                    if isEditing {
                        TextField(
                            "Final answer", text: optionalBinding(\.finalAnswer), axis: .vertical)
                    } else {
                        ForEach(Array(response.steps.enumerated()), id: \.element.id) {
                            index, step in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Step \(index + 1)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(step.expression)
                                    .font(.system(.body, design: .rounded).weight(.medium))
                                    .textSelection(.enabled)
                                Text(step.explanation)
                                    .font(.subheadline)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if let answer = response.finalAnswer, !answer.isEmpty {
                            LabeledContent("Final answer", value: answer)
                                .fontWeight(.semibold)
                        }
                    }
                }
            }

            if !response.diagnoses.isEmpty {
                Section("Error diagnosis") {
                    ForEach(response.diagnoses) { diagnosis in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(diagnosis.kind.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(diagnosis.observed)
                                .font(.subheadline.weight(.medium))
                            Text(diagnosis.explanation)
                                .font(.subheadline)
                            Label(diagnosis.correction, systemImage: "arrow.right")
                                .font(.subheadline)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if isEditing || response.graphExpression != nil {
                Section("Graph") {
                    if isEditing {
                        TextField("Function of x", text: optionalBinding(\.graphExpression))
                            .font(.system(.body, design: .monospaced))
                        HStack {
                            TextField(
                                "Minimum x", value: graphDomainBinding(\.minimumX), format: .number)
                            TextField(
                                "Maximum x", value: graphDomainBinding(\.maximumX), format: .number)
                        }
                        .keyboardType(.numbersAndPunctuation)
                    } else if let expression = response.graphExpression {
                        MathGraphView(
                            expression: expression,
                            domain: response.graphDomain ?? MathGraphDomain()
                        )
                    }
                }
            }

            if !response.uncertainties.isEmpty {
                Section("Check before accepting") {
                    ForEach(response.uncertainties, id: \.self) { uncertainty in
                        Label(uncertainty, systemImage: "exclamationmark.circle")
                            .font(.subheadline)
                    }
                }
            }

            Section("Review") {
                if isEditing {
                    Button {
                        Task { await saveEdit() }
                    } label: {
                        progressLabel(isSaving ? "Saving…" : "Save reviewed edit")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(EpistoriaDesign.ink)
                    .disabled(isSaving)

                    Button("Cancel edit", role: .cancel) {
                        draft = response
                        isEditing = false
                    }
                } else if current.payload.reviewState == nil {
                    Button {
                        Task { await review(.accepted) }
                    } label: {
                        Label("Accept", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(EpistoriaDesign.ink)

                    Button {
                        draft = response
                        isEditing = true
                    } label: {
                        Label("Edit before accepting", systemImage: "pencil").frame(
                            maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        Task { await review(.rejected) }
                    } label: {
                        Label("Reject", systemImage: "xmark").frame(maxWidth: .infinity)
                    }
                } else {
                    Label(
                        "Review state: \(current.payload.reviewState!.label)",
                        systemImage: current.payload.reviewState!.symbol
                    )
                    .foregroundStyle(.secondary)
                }

                if canInsert, !response.recognizedExpression.isEmpty {
                    Button {
                        onInsertExpression(response.recognizedExpression)
                    } label: {
                        Label("Insert expression", systemImage: "function").frame(
                            maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if canInsert, !response.noteExplanation.isEmpty {
                    Button {
                        onInsertExplanation(response.noteExplanation)
                    } label: {
                        Label("Insert worked explanation", systemImage: "text.badge.plus").frame(
                            maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Section {
                Text(
                    "This result is derived and reviewable. Inserting it creates a new notebook object and does not replace the selected handwriting."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.subheadline)
                }
            }
        }
        .navigationTitle(current.payload.mode.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func progressLabel(_ title: String) -> some View {
        HStack {
            if isSaving { ProgressView().padding(.trailing, 6) }
            Text(title).fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity)
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<MathAssistanceResponse, String?>)
        -> Binding<String>
    {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func graphDomainBinding(_ keyPath: WritableKeyPath<MathGraphDomain, Double>) -> Binding<
        Double
    > {
        Binding(
            get: { (draft.graphDomain ?? MathGraphDomain())[keyPath: keyPath] },
            set: { value in
                var domain = draft.graphDomain ?? MathGraphDomain()
                domain[keyPath: keyPath] = value
                draft.graphDomain = domain
            }
        )
    }

    private func review(_ state: AIArtifactReviewState) async {
        var updated = current
        updated.payload.reviewState = state
        updated.payload.reviewedAt = .now
        await save(updated)
    }

    private func saveEdit() async {
        let recognized = draft.recognizedExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recognized.isEmpty else {
            errorMessage = "The recognized expression cannot be empty."
            return
        }
        if let graph = draft.graphExpression?.trimmingCharacters(in: .whitespacesAndNewlines),
            !graph.isEmpty
        {
            do {
                _ = try MathExpressionEvaluator.samples(
                    expression: graph,
                    domain: draft.graphDomain ?? MathGraphDomain(),
                    count: 61
                )
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            draft.graphExpression = graph
        }
        draft.recognizedExpression = recognized
        draft.confidence = min(max(draft.confidence, 0), 1)
        var updated = current
        updated.payload.reviewState = .edited
        updated.payload.reviewedAt = .now
        updated.payload.editedResponse = draft
        await save(updated)
        if errorMessage == nil { isEditing = false }
    }

    private func save(_ updated: IdentifiedPayload<MathAssistanceArtifact>) async {
        guard let store = model.store else { return }
        isSaving = true
        errorMessage = nil
        do {
            _ = try await store.save(
                id: updated.id,
                payload: updated.payload,
                parentId: updated.payload.noteId,
                relationIds: updated.payload.sourceIds
            )
            current = updated
            draft = updated.payload.activeResponse
            onReviewChanged(updated)
            model.noteLocalMutation()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - Local graph

struct MathGraphView: View {
    let expression: String
    let domain: MathGraphDomain

    private var plot: MathGraphPlot? {
        guard
            let samples = try? MathExpressionEvaluator.samples(
                expression: expression,
                domain: domain
            )
        else { return nil }
        return MathGraphPlot(samples: samples, domain: domain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("y = \(expression)")
                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                    .textSelection(.enabled)
                Spacer()
                Text("Plotted locally")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let plot {
                Canvas { context, size in
                    plot.draw(in: &context, size: size)
                }
                .frame(height: 250)
                .background(EpistoriaDesign.page)
                .clipShape(RoundedRectangle(cornerRadius: EpistoriaDesign.cardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: EpistoriaDesign.cardRadius)
                        .stroke(EpistoriaDesign.border, lineWidth: 1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Graph of y equals \(expression)")
                .accessibilityValue(
                    "From x \(domain.minimumX.formatted()) to \(domain.maximumX.formatted())")
            } else {
                ContentUnavailableView(
                    "Graph unavailable",
                    systemImage: "chart.xyaxis.line",
                    description: Text(
                        "Edit the result and use an explicit function of x such as sin(x) + 2*x.")
                )
                .frame(minHeight: 180)
            }
        }
    }
}

private struct MathGraphPlot {
    let samples: [MathGraphSample]
    let domain: MathGraphDomain
    let minimumY: Double
    let maximumY: Double

    init(samples: [MathGraphSample], domain: MathGraphDomain) {
        self.samples = samples
        self.domain = domain
        let finite = samples.compactMap(\.y).filter { $0.isFinite }.sorted()
        let trim = finite.count >= 20 ? finite.count / 20 : 0
        let lower = finite[min(trim, finite.count - 1)]
        let upper = finite[max(0, finite.count - trim - 1)]
        if upper - lower < 0.000_001 {
            minimumY = lower - 1
            maximumY = upper + 1
        } else {
            let padding = (upper - lower) * 0.08
            minimumY = lower - padding
            maximumY = upper + padding
        }
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let frame = CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 12)
        guard frame.width > 0, frame.height > 0 else { return }

        var grid = Path()
        for index in 0...8 {
            let x = frame.minX + frame.width * CGFloat(index) / 8
            grid.move(to: CGPoint(x: x, y: frame.minY))
            grid.addLine(to: CGPoint(x: x, y: frame.maxY))
        }
        for index in 0...6 {
            let y = frame.minY + frame.height * CGFloat(index) / 6
            grid.move(to: CGPoint(x: frame.minX, y: y))
            grid.addLine(to: CGPoint(x: frame.maxX, y: y))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.14)), lineWidth: 0.5)

        var axes = Path()
        if domain.minimumX <= 0, domain.maximumX >= 0 {
            let x = mapX(0, frame: frame)
            axes.move(to: CGPoint(x: x, y: frame.minY))
            axes.addLine(to: CGPoint(x: x, y: frame.maxY))
        }
        if minimumY <= 0, maximumY >= 0 {
            let y = mapY(0, frame: frame)
            axes.move(to: CGPoint(x: frame.minX, y: y))
            axes.addLine(to: CGPoint(x: frame.maxX, y: y))
        }
        context.stroke(axes, with: .color(.secondary.opacity(0.65)), lineWidth: 1)

        var curve = Path()
        var previous: CGPoint?
        for sample in samples {
            guard let y = sample.y, y >= minimumY, y <= maximumY else {
                previous = nil
                continue
            }
            let point = CGPoint(x: mapX(sample.x, frame: frame), y: mapY(y, frame: frame))
            if let previous, abs(point.y - previous.y) < frame.height * 0.72 {
                curve.addLine(to: point)
            } else {
                curve.move(to: point)
            }
            previous = point
        }
        context.stroke(
            curve, with: .color(.primary),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    private func mapX(_ value: Double, frame: CGRect) -> CGFloat {
        frame.minX + frame.width
            * CGFloat((value - domain.minimumX) / (domain.maximumX - domain.minimumX))
    }

    private func mapY(_ value: Double, frame: CGRect) -> CGFloat {
        frame.maxY - frame.height * CGFloat((value - minimumY) / (maximumY - minimumY))
    }
}

extension MathAssistanceMode {
    fileprivate var title: String {
        switch self {
        case .recognize: "Recognize equation"
        case .workedSteps: "Worked steps"
        case .graph: "Graph"
        case .diagnose: "Diagnose error"
        }
    }

    fileprivate var summary: String {
        switch self {
        case .recognize: "Transcribe the selected handwriting and explain how it was interpreted."
        case .workedSteps: "Solve or continue the selected problem with a reason for every step."
        case .graph:
            "Recognize a function and return a bounded expression that Epistoria plots locally."
        case .diagnose: "Find the first meaningful error, explain it, and show a correction."
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .recognize: "text.viewfinder"
        case .workedSteps: "list.number"
        case .graph: "chart.xyaxis.line"
        case .diagnose: "exclamationmark.magnifyingglass"
        }
    }
}

extension MathErrorKind {
    fileprivate var title: String {
        switch self {
        case .recognition: "Recognition"
        case .notation: "Notation"
        case .conceptual: "Concept"
        case .method: "Method choice"
        case .algebra: "Algebra"
        case .arithmetic: "Arithmetic"
        case .verification: "Verification"
        }
    }
}

extension AIArtifactReviewState {
    fileprivate var label: String {
        switch self {
        case .accepted: "Accepted"
        case .edited: "Edited"
        case .rejected: "Rejected"
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .accepted: "checkmark.circle"
        case .edited: "pencil.circle"
        case .rejected: "xmark.circle"
        }
    }
}

extension MathAssistanceArtifact {
    fileprivate var activeResponse: MathAssistanceResponse { editedResponse ?? response }
}

extension MathAssistanceResponse {
    fileprivate var noteExplanation: String {
        var sections = [interpretation]
        sections.append(
            contentsOf: steps.enumerated().map { index, step in
                "\(index + 1). \(step.expression) — \(step.explanation)"
            })
        if let finalAnswer, !finalAnswer.isEmpty {
            sections.append("Final answer: \(finalAnswer)")
        }
        if !diagnoses.isEmpty {
            sections.append(
                contentsOf: diagnoses.map {
                    "\($0.kind.title): \($0.explanation) Correction: \($0.correction)"
                })
        }
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
