import EpistoriaCore
import SwiftUI

struct ConceptEvidenceMapView: View {
    @Bindable var model: AppModel
    let topicId: UUID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var topic: IdentifiedPayload<TopicPayload>?
    @State private var concepts: [IdentifiedPayload<ConceptPayload>] = []
    @State private var evidence: [IdentifiedPayload<EvidencePayload>] = []
    @State private var sources: [IdentifiedPayload<SourcePayload>] = []
    @State private var relations: [IdentifiedPayload<ConceptEvidenceRelationPayload>] = []
    @State private var links: [IdentifiedPayload<ConceptLinkPayload>] = []
    @State private var notes: [IdentifiedPayload<NotePayload>] = []
    @State private var placements: [UUID: KnowledgeMapNodePlacement] = [:]
    @State private var selectedNodeId: UUID?
    @State private var dragOrigins: [UUID: CGPoint] = [:]
    @State private var zoom = 0.72
    @State private var gestureMagnification = 1.0
    @State private var presentation = MapPresentation.map
    @State private var showEvidence = true
    @State private var showConnectionEditor = false
    @State private var tutorEvidenceId: UUID?
    @State private var sourceEvidenceId: UUID?
    @State private var noteEvidenceId: UUID?
    @State private var openedNoteId: UUID?
    @State private var pendingEdgeRemoval: KnowledgeMapEdge?
    @State private var errorMessage: String?

    private enum MapPresentation: String, CaseIterable, Identifiable {
        case map = "Map"
        case list = "List"
        var id: Self { self }
    }

    var body: some View {
        Group {
            if projection.nodes.isEmpty {
                emptyState
            } else if presentation == .map {
                mapSurface
            } else {
                accessibleList
            }
        }
        .navigationTitle(mapTitle)
        .navigationBarTitleDisplayMode(.inline)
        .epistoriaPageBackground()
        .toolbar { mapToolbar }
        .task { await load() }
        .refreshable { await load() }
        .navigationDestination(item: $openedNoteId) { noteId in
            NoteEditorView(model: model, noteId: noteId)
        }
        .sheet(isPresented: $showConnectionEditor) {
            KnowledgeMapConnectionEditor(
                model: model,
                topicId: topicId,
                concepts: scopedConcepts,
                evidence: topicEvidence
            ) {
                showConnectionEditor = false
                Task { await load() }
            }
        }
        .sheet(isPresented: sourceEvidencePresented) {
            if let item = selectedSourceEvidence {
                NavigationStack {
                    ResourceDetailView(
                        model: model,
                        resourceId: item.payload.sourceId,
                        initialSourceVersionId: item.payload.sourceVersionId,
                        initialPageNumber: item.payload.locator.page,
                        highlightText: item.payload.excerpt,
                        initialMediaTimeSeconds: item.payload.locator.startSeconds
                    )
                }
            }
        }
        .sheet(isPresented: tutorEvidencePresented) {
            if let tutorEvidenceId {
                AdaptiveTutorView(
                    model: model,
                    topicId: topicId,
                    initialMessage: "Help me study this Evidence and its connected Concepts.",
                    preferredEvidenceIds: [tutorEvidenceId]
                )
            }
        }
        .sheet(isPresented: noteEvidencePresented) {
            if let noteEvidenceId {
                EvidenceNotePicker(
                    model: model,
                    evidenceId: noteEvidenceId,
                    notes: topicNotes
                ) { noteId in
                    self.noteEvidenceId = nil
                    openedNoteId = noteId
                    Task { await load() }
                }
            }
        }
        .confirmationDialog(
            "Remove this connection?",
            isPresented: edgeRemovalPresented,
            titleVisibility: .visible
        ) {
            Button("Remove connection", role: .destructive) {
                guard let edge = pendingEdgeRemoval else { return }
                self.pendingEdgeRemoval = nil
                Task { await remove(edge) }
            }
            Button("Cancel", role: .cancel) { pendingEdgeRemoval = nil }
        } message: {
            Text("The Concepts and Evidence remain in the notebook. Only this typed relationship is removed.")
        }
        .alert("Knowledge Map error", isPresented: .constant(errorMessage != nil)) {
            Button("Dismiss", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var mapSurface: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                ScrollView([.horizontal, .vertical]) {
                    mapWorld
                        .scaleEffect(effectiveZoom, anchor: .topLeading)
                        .frame(
                            width: KnowledgeMapProjectionBuilder.worldWidth * effectiveZoom,
                            height: KnowledgeMapProjectionBuilder.worldHeight * effectiveZoom,
                            alignment: .topLeading
                        )
                }
                .scrollIndicators(.visible)
                .background(EpistoriaDesign.page)
                .simultaneousGesture(magnificationGesture)
                .accessibilityLabel("Concept and Evidence map")
                .accessibilityHint("Use the List view for a linear accessible representation.")

                if let selectedNode {
                    inspector(selectedNode)
                        .frame(width: min(370, max(300, geometry.size.width * 0.38)))
                        .frame(maxHeight: .infinity)
                        .background {
                            if reduceTransparency { EpistoriaDesign.page }
                            else { Rectangle().fill(.regularMaterial) }
                        }
                        .overlay(alignment: .leading) { Divider() }
                        .shadow(
                            color: reduceTransparency ? .clear : .black.opacity(0.1),
                            radius: 18,
                            x: -4
                        )
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    private var mapWorld: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                drawEdges(context: &context)
            }
            .allowsHitTesting(false)

            ForEach(visibleNodes) { node in
                mapNode(node)
                    .position(nodePosition(node))
                    .gesture(nodeDragGesture(node))
                    .onTapGesture { select(node.id) }
            }
        }
        .frame(
            width: KnowledgeMapProjectionBuilder.worldWidth,
            height: KnowledgeMapProjectionBuilder.worldHeight
        )
        .background {
            DotGrid()
                .foregroundStyle(EpistoriaDesign.border.opacity(0.42))
        }
        .coordinateSpace(name: "knowledge-map-world")
    }

    private func mapNode(_ node: KnowledgeMapNode) -> some View {
        let selected = selectedNodeId == node.id
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: node.kind == .concept
                      ? "point.3.connected.trianglepath.dotted"
                      : "quote.bubble")
                    .font(.caption.weight(.semibold))
                Text(node.kind == .concept ? "CONCEPT" : "EVIDENCE")
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                Spacer(minLength: 4)
                if node.relationCount > 0 {
                    Text("\(node.relationCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(node.title)
                .font(.headline)
                .lineLimit(2)
            if !node.detail.isEmpty {
                Text(node.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(node.kind == .concept ? 2 : 3)
            }
        }
        .padding(12)
        .frame(width: node.kind == .concept ? 210 : 190, alignment: .leading)
        .background(
            node.kind == .concept ? EpistoriaDesign.surface : EpistoriaDesign.page,
            in: RoundedRectangle(cornerRadius: node.kind == .concept ? 12 : 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: node.kind == .concept ? 12 : 8)
                .stroke(selected ? EpistoriaDesign.ink : EpistoriaDesign.border,
                        lineWidth: selected ? 2 : 0.8)
        }
        .shadow(color: selected ? .black.opacity(0.12) : .black.opacity(0.05), radius: selected ? 10 : 4, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: node.kind == .concept ? 12 : 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.kind == .concept ? "Concept" : "Evidence"), \(node.title)")
        .accessibilityValue("\(node.relationCount) connections")
        .accessibilityHint("Select for details. Drag to arrange.")
    }

    private var accessibleList: some View {
        List {
            Section("Concepts") {
                ForEach(projection.nodes.filter { $0.kind == .concept }) { node in
                    Button { select(node.id) } label: { listRow(node) }
                }
            }
            if showEvidence {
                Section("Evidence") {
                    ForEach(projection.nodes.filter { $0.kind == .evidence }) { node in
                        Button { select(node.id) } label: { listRow(node) }
                    }
                }
            }
            Section("Connections") {
                ForEach(visibleEdges) { edge in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(edgeTitle(edge)).foregroundStyle(.primary)
                            Text(edge.label).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu("Connection actions", systemImage: "ellipsis") {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                pendingEdgeRemoval = edge
                            }
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }
        }
        .safeAreaInset(edge: .trailing) {
            if let selectedNode { inspector(selectedNode).frame(width: 350) }
        }
    }

    private func listRow(_ node: KnowledgeMapNode) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(node.title).foregroundStyle(.primary)
                Text(node.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        } icon: {
            Image(systemName: node.kind == .concept
                  ? "point.3.connected.trianglepath.dotted"
                  : "quote.bubble")
                .foregroundStyle(EpistoriaDesign.ink)
        }
    }

    private func inspector(_ node: KnowledgeMapNode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label(node.kind == .concept ? "Concept" : "Evidence",
                          systemImage: node.kind == .concept
                          ? "point.3.connected.trianglepath.dotted"
                          : "quote.bubble")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Close", systemImage: "xmark") { select(nil) }
                        .labelStyle(.iconOnly)
                }
                Text(node.title).font(.title2.weight(.bold))
                if !node.detail.isEmpty {
                    Text(node.detail).font(.body).textSelection(.enabled)
                }

                if node.kind == .evidence, let item = evidenceById[node.id] {
                    evidenceActions(item)
                    evidenceLocation(item.payload)
                }

                Divider()
                Text("Connections").font(.headline)
                let edges = connectedEdges(node.id)
                if edges.isEmpty {
                    Text("No connections").foregroundStyle(.secondary)
                }
                ForEach(edges) { edge in connectionRow(edge, selectedId: node.id) }
            }
            .padding(18)
        }
        .accessibilityElement(children: .contain)
    }

    private func evidenceActions(_ item: IdentifiedPayload<EvidencePayload>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button("Open exact Source", systemImage: "doc.text.magnifyingglass") {
                sourceEvidenceId = item.id
            }
            .buttonStyle(.borderedProminent)
            .tint(EpistoriaDesign.ink)
            Button("Ask Tutor", systemImage: "graduationcap") { tutorEvidenceId = item.id }
                .buttonStyle(.bordered)
            Button("Add to note", systemImage: "note.text.badge.plus") { noteEvidenceId = item.id }
                .buttonStyle(.bordered)
                .disabled(topicNotes.isEmpty)
            let noteBacklinks = evidenceBacklinks(item.id).filter { $0.kind == .note }
            ForEach(noteBacklinks.prefix(3)) { backlink in
                Button("Open in \(backlink.title)", systemImage: "arrow.up.right.square") {
                    openedNoteId = backlink.ownerId
                }
                .buttonStyle(.plain)
                .foregroundStyle(EpistoriaDesign.ink)
            }
        }
    }

    private func evidenceLocation(_ payload: EvidencePayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sourceById[payload.sourceId]?.payload.title ?? "Source")
                .font(.subheadline.weight(.semibold))
            Text(locatorLabel(payload.locator))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(EpistoriaDesign.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func connectionRow(_ edge: KnowledgeMapEdge, selectedId: UUID) -> some View {
        let otherId = edge.sourceId == selectedId ? edge.targetId : edge.sourceId
        return HStack(spacing: 10) {
            Button {
                select(otherId)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(nodeById[otherId]?.title ?? "Unavailable item")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(edge.label).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Menu("Connection actions", systemImage: "ellipsis") {
                Button("Remove", systemImage: "trash", role: .destructive) {
                    pendingEdgeRemoval = edge
                }
            }
            .labelStyle(.iconOnly)
        }
        .padding(.vertical, 5)
    }

    @ToolbarContentBuilder private var mapToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Presentation", selection: $presentation) {
                ForEach(MapPresentation.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            Toggle("Evidence", systemImage: "quote.bubble", isOn: $showEvidence)
                .toggleStyle(.button)
            Button("Add connection", systemImage: "link.badge.plus") {
                showConnectionEditor = true
            }
            Menu("Map options", systemImage: "ellipsis.circle") {
                Button("Zoom in", systemImage: "plus.magnifyingglass") { setZoom(zoom + 0.12) }
                Button("Zoom out", systemImage: "minus.magnifyingglass") { setZoom(zoom - 0.12) }
                Button("Reset arrangement", systemImage: "arrow.counterclockwise") {
                    Task { await resetLayout() }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Build the knowledge map", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text("Add at least one active Concept to this Topic. Connect Evidence to show where each idea is supported, contradicted, applied, or demonstrated.")
        } actions: {
            Button("Add connection", systemImage: "link.badge.plus") { showConnectionEditor = true }
                .buttonStyle(.borderedProminent)
                .tint(EpistoriaDesign.ink)
                .disabled(scopedConcepts.isEmpty)
        }
    }

    private var projection: KnowledgeMapProjection {
        KnowledgeMapProjectionBuilder.build(
            topicId: topicId,
            concepts: concepts,
            evidence: evidence,
            conceptEvidence: relations,
            conceptLinks: links,
            placements: Array(placements.values)
        )
    }

    private var mapTitle: String {
        guard let name = topic?.payload.name else { return "Knowledge Map" }
        return "\(name) Map"
    }

    private var sourceEvidencePresented: Binding<Bool> {
        Binding(
            get: { sourceEvidenceId != nil },
            set: { presented in if !presented { sourceEvidenceId = nil } }
        )
    }

    private var tutorEvidencePresented: Binding<Bool> {
        Binding(
            get: { tutorEvidenceId != nil },
            set: { presented in if !presented { tutorEvidenceId = nil } }
        )
    }

    private var noteEvidencePresented: Binding<Bool> {
        Binding(
            get: { noteEvidenceId != nil },
            set: { presented in if !presented { noteEvidenceId = nil } }
        )
    }

    private var edgeRemovalPresented: Binding<Bool> {
        Binding(
            get: { pendingEdgeRemoval != nil },
            set: { presented in if !presented { pendingEdgeRemoval = nil } }
        )
    }

    private var scopedConcepts: [IdentifiedPayload<ConceptPayload>] {
        concepts.filter { $0.payload.state == .active && $0.payload.topicIds.contains(topicId) }
    }

    private var topicNotes: [IdentifiedPayload<NotePayload>] {
        notes.filter { $0.payload.courseId == topicId && $0.payload.archivedAt == nil }
    }

    private var topicEvidence: [IdentifiedPayload<EvidencePayload>] {
        let sourceIds = Set(sources.filter {
            $0.payload.primaryTopicId == topicId || $0.payload.relatedTopicIds.contains(topicId)
        }.map(\.id))
        return evidence.filter { sourceIds.contains($0.payload.sourceId) }
    }

    private var evidenceById: [UUID: IdentifiedPayload<EvidencePayload>] {
        Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })
    }

    private var sourceById: [UUID: IdentifiedPayload<SourcePayload>] {
        Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
    }

    private var nodeById: [UUID: KnowledgeMapNode] {
        Dictionary(uniqueKeysWithValues: projection.nodes.map { ($0.id, $0) })
    }

    private var selectedNode: KnowledgeMapNode? {
        selectedNodeId.flatMap { nodeById[$0] }
    }

    private var selectedSourceEvidence: IdentifiedPayload<EvidencePayload>? {
        sourceEvidenceId.flatMap { evidenceById[$0] }
    }

    private var visibleNodes: [KnowledgeMapNode] {
        projection.nodes.filter { showEvidence || $0.kind == .concept }
    }

    private var visibleNodeIds: Set<UUID> { Set(visibleNodes.map(\.id)) }

    private var visibleEdges: [KnowledgeMapEdge] {
        projection.edges.filter {
            visibleNodeIds.contains($0.sourceId) && visibleNodeIds.contains($0.targetId)
        }
    }

    private var effectiveZoom: Double {
        min(max(zoom * gestureMagnification, 0.42), 1.45)
    }

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in gestureMagnification = Double(value.magnification) }
            .onEnded { value in
                zoom = min(max(zoom * Double(value.magnification), 0.42), 1.45)
                gestureMagnification = 1
            }
    }

    private func nodePosition(_ node: KnowledgeMapNode) -> CGPoint {
        if let placement = placements[node.id] { return CGPoint(x: placement.x, y: placement.y) }
        return CGPoint(x: node.x, y: node.y)
    }

    private func nodeDragGesture(_ node: KnowledgeMapNode) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("knowledge-map-world"))
            .onChanged { value in
                if dragOrigins[node.id] == nil {
                    dragOrigins[node.id] = nodePosition(node)
                    selectedNodeId = node.id
                }
                guard let origin = dragOrigins[node.id] else { return }
                let x = origin.x + value.translation.width / effectiveZoom
                let y = origin.y + value.translation.height / effectiveZoom
                placements[node.id] = KnowledgeMapNodePlacement(
                    nodeId: node.id,
                    kind: node.kind,
                    x: min(max(x, 90), KnowledgeMapProjectionBuilder.worldWidth - 90),
                    y: min(max(y, 70), KnowledgeMapProjectionBuilder.worldHeight - 70)
                )
            }
            .onEnded { _ in
                dragOrigins[node.id] = nil
                guard let placement = placements[node.id] else { return }
                Task { await persist(placement) }
            }
    }

    private func drawEdges(context: inout GraphicsContext) {
        for edge in visibleEdges {
            guard let source = nodeById[edge.sourceId], let target = nodeById[edge.targetId] else { continue }
            let start = nodePosition(source)
            let end = nodePosition(target)
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            let selected = selectedNodeId == edge.sourceId || selectedNodeId == edge.targetId
            let style = StrokeStyle(
                lineWidth: selected ? 2.2 : 1.1,
                lineCap: .round,
                dash: edge.kind == .evidence ? [7, 5] : []
            )
            context.stroke(path, with: .color(EpistoriaDesign.ink.opacity(selected ? 0.72 : 0.28)), style: style)
            if edge.directed { drawArrow(context: &context, from: start, to: end, selected: selected) }
            if effectiveZoom > 0.58 {
                let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                context.draw(
                    Text(edge.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(EpistoriaDesign.mutedInk),
                    at: midpoint
                )
            }
        }
    }

    private func drawArrow(
        context: inout GraphicsContext,
        from start: CGPoint,
        to end: CGPoint,
        selected: Bool
    ) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = 10.0
        let point = CGPoint(
            x: end.x - cos(angle) * 102,
            y: end.y - sin(angle) * 102
        )
        var arrow = Path()
        arrow.move(to: CGPoint(
            x: point.x - cos(angle - .pi / 5) * length,
            y: point.y - sin(angle - .pi / 5) * length
        ))
        arrow.addLine(to: point)
        arrow.addLine(to: CGPoint(
            x: point.x - cos(angle + .pi / 5) * length,
            y: point.y - sin(angle + .pi / 5) * length
        ))
        context.stroke(
            arrow,
            with: .color(EpistoriaDesign.ink.opacity(selected ? 0.72 : 0.28)),
            style: StrokeStyle(lineWidth: selected ? 2.2 : 1.1, lineCap: .round, lineJoin: .round)
        )
    }

    private func connectedEdges(_ nodeId: UUID) -> [KnowledgeMapEdge] {
        visibleEdges.filter { $0.sourceId == nodeId || $0.targetId == nodeId }
    }

    private func edgeTitle(_ edge: KnowledgeMapEdge) -> String {
        let source = nodeById[edge.sourceId]?.title ?? "Unavailable"
        let target = nodeById[edge.targetId]?.title ?? "Unavailable"
        return "\(source) → \(target)"
    }

    private func select(_ id: UUID?) {
        let animation = reduceMotion ? Animation.easeOut(duration: 0.12) : .snappy(duration: 0.28, extraBounce: 0)
        withAnimation(animation) { selectedNodeId = id }
    }

    private func setZoom(_ value: Double) {
        let bounded = min(max(value, 0.42), 1.45)
        if reduceMotion { zoom = bounded }
        else { withAnimation(.snappy(duration: 0.25, extraBounce: 0)) { zoom = bounded } }
    }

    private func locatorLabel(_ locator: SourceLocator) -> String {
        switch locator.kind {
        case .pdf: locator.page.map { "Page \($0)" } ?? "PDF location"
        case .epub: locator.chapter ?? "EPUB location"
        case .web: locator.heading ?? "Web excerpt"
        case .media: locator.startSeconds.map { "Time \(durationLabel($0))" } ?? "Media excerpt"
        case .document: locator.heading ?? locator.page.map { "Page \($0)" } ?? "Document excerpt"
        case .image: "Image region"
        case .plainText: "Text excerpt"
        case .slide: locator.slide.map { "Slide \($0)" } ?? "Slide excerpt"
        case .sheet: [locator.sheet, locator.cellRange].compactMap(\.self).joined(separator: " · ")
        }
    }

    private func durationLabel(_ seconds: Double) -> String {
        let value = max(Int(seconds.rounded(.down)), 0)
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func evidenceBacklinks(_ evidenceId: UUID) -> [EvidenceBacklink] {
        cachedBacklinks[evidenceId, default: []]
    }

    @State private var cachedBacklinks: [UUID: [EvidenceBacklink]] = [:]

    private func load() async {
        guard let store = model.store else { return }
        do {
            async let loadedTopic = store.topic(id: topicId)
            async let loadedConcepts = store.list(ConceptPayload.self)
            async let loadedEvidence = store.list(EvidencePayload.self)
            async let loadedSources = store.list(SourcePayload.self)
            async let loadedRelations = store.list(ConceptEvidenceRelationPayload.self)
            async let loadedLinks = store.list(ConceptLinkPayload.self)
            async let loadedNotes = store.list(NotePayload.self)
            async let loadedMap = store.knowledgeMap(topicId: topicId)
            let values = try await (
                loadedTopic, loadedConcepts, loadedEvidence, loadedSources,
                loadedRelations, loadedLinks, loadedNotes, loadedMap
            )
            topic = values.0
            concepts = values.1
            evidence = values.2
            sources = values.3
            relations = values.4
            links = values.5
            notes = values.6
            placements = Dictionary(
                uniqueKeysWithValues: (values.7?.payload.placements ?? []).map { ($0.nodeId, $0) }
            )
            let visibleEvidenceIds = Set(relations
                .filter { scopedConcepts.map(\.id).contains($0.payload.conceptId) }
                .map(\.payload.evidenceId))
            var backlinks: [UUID: [EvidenceBacklink]] = [:]
            for id in visibleEvidenceIds {
                backlinks[id] = try await store.evidenceBacklinks(evidenceId: id)
            }
            cachedBacklinks = backlinks
            if let selectedNodeId, !projection.nodes.contains(where: { $0.id == selectedNodeId }) {
                self.selectedNodeId = nil
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func persist(_ placement: KnowledgeMapNodePlacement) async {
        guard let store = model.store else { return }
        do {
            try await store.saveKnowledgeMapPlacement(
                topicId: topicId,
                nodeId: placement.nodeId,
                kind: placement.kind,
                x: placement.x,
                y: placement.y
            )
            model.noteLocalMutation()
        } catch {
            errorMessage = error.localizedDescription
            await load()
        }
    }

    private func resetLayout() async {
        guard let store = model.store else { return }
        do {
            try await store.resetKnowledgeMapLayout(topicId: topicId)
            model.noteLocalMutation()
            if reduceMotion { placements = [:] }
            else { withAnimation(.snappy(duration: 0.32, extraBounce: 0)) { placements = [:] } }
        } catch { errorMessage = error.localizedDescription }
    }

    private func remove(_ edge: KnowledgeMapEdge) async {
        guard let store = model.store else { return }
        do {
            switch edge.kind {
            case .concept: try await store.removeConceptLink(id: edge.id)
            case .evidence: try await store.removeConceptEvidenceRelation(id: edge.id)
            }
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let spacing = 28.0
            var x = 0.0
            while x <= size.width {
                var y = 0.0
                while y <= size.height {
                    path.addEllipse(in: CGRect(x: x, y: y, width: 1.4, height: 1.4))
                    y += spacing
                }
                x += spacing
            }
            context.fill(path, with: .foreground)
        }
        .allowsHitTesting(false)
    }
}

private struct KnowledgeMapConnectionEditor: View {
    @Bindable var model: AppModel
    let topicId: UUID
    let concepts: [IdentifiedPayload<ConceptPayload>]
    let evidence: [IdentifiedPayload<EvidencePayload>]
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode = ConnectionMode.conceptEvidence
    @State private var sourceConceptId: UUID?
    @State private var targetConceptId: UUID?
    @State private var evidenceId: UUID?
    @State private var conceptRelation = ConceptLinkKind.related
    @State private var evidenceRelation = ConceptEvidenceKind.supporting
    @State private var rationale = ""
    @State private var errorMessage: String?

    private enum ConnectionMode: String, CaseIterable, Identifiable {
        case conceptEvidence = "Concept and Evidence"
        case concepts = "Two Concepts"
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Connection type", selection: $mode) {
                    ForEach(ConnectionMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Section("From") {
                    Picker("Concept", selection: $sourceConceptId) {
                        Text("Select a Concept").tag(UUID?.none)
                        ForEach(concepts, id: \.id) { Text($0.payload.name).tag(UUID?.some($0.id)) }
                    }
                }
                if mode == .conceptEvidence {
                    Section("Evidence") {
                        if evidence.isEmpty {
                            Text("This Topic has no Evidence yet.").foregroundStyle(.secondary)
                        }
                        Picker("Evidence", selection: $evidenceId) {
                            Text("Select Evidence").tag(UUID?.none)
                            ForEach(evidence, id: \.id) {
                                Text(evidenceTitle($0.payload)).tag(UUID?.some($0.id))
                            }
                        }
                        Picker("Relationship", selection: $evidenceRelation) {
                            ForEach([
                                ConceptEvidenceKind.supporting, .contradicting, .example,
                                .prerequisite, .application,
                            ], id: \.rawValue) { Text($0.displayName).tag($0) }
                        }
                    }
                } else {
                    Section("To") {
                        Picker("Concept", selection: $targetConceptId) {
                            Text("Select a Concept").tag(UUID?.none)
                            ForEach(concepts.filter { $0.id != sourceConceptId }, id: \.id) {
                                Text($0.payload.name).tag(UUID?.some($0.id))
                            }
                        }
                        Picker("Relationship", selection: $conceptRelation) {
                            ForEach(ConceptLinkKind.allCases, id: \.self) {
                                Text($0.displayName).tag($0)
                            }
                        }
                        TextField("Reason (optional)", text: $rationale, axis: .vertical)
                    }
                }
                Text("Connections are owner records. AI suggestions remain separate drafts until reviewed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Add Connection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }.disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        guard sourceConceptId != nil else { return false }
        switch mode {
        case .conceptEvidence: return evidenceId != nil
        case .concepts: return targetConceptId != nil && targetConceptId != sourceConceptId
        }
    }

    private func evidenceTitle(_ payload: EvidencePayload) -> String {
        let excerpt = payload.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((excerpt.isEmpty ? payload.note ?? "Evidence" : excerpt).prefix(80))
    }

    private func save() async {
        guard let store = model.store, let sourceConceptId else { return }
        do {
            switch mode {
            case .conceptEvidence:
                guard let evidenceId else { return }
                _ = try await store.linkConcept(
                    sourceConceptId,
                    toEvidence: evidenceId,
                    relation: evidenceRelation
                )
            case .concepts:
                guard let targetConceptId else { return }
                _ = try await store.createConceptLink(
                    sourceConceptId: sourceConceptId,
                    targetConceptId: targetConceptId,
                    relation: conceptRelation,
                    rationale: rationale
                )
            }
            model.noteLocalMutation()
            onSaved()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct EvidenceNotePicker: View {
    @Bindable var model: AppModel
    let evidenceId: UUID
    let notes: [IdentifiedPayload<NotePayload>]
    let onInserted: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List(notes, id: \.id) { note in
                Button {
                    Task { await insert(in: note) }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(note.payload.title).foregroundStyle(.primary)
                            Text(note.payload.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "note.text").foregroundStyle(EpistoriaDesign.ink) }
                }
            }
            .navigationTitle("Add Evidence to Note")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .overlay {
                if notes.isEmpty {
                    ContentUnavailableView("No Topic notes", systemImage: "note.text")
                }
            }
            .alert("Could not add Evidence", isPresented: .constant(errorMessage != nil)) {
                Button("Dismiss", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func insert(in note: IdentifiedPayload<NotePayload>) async {
        guard let store = model.store else { return }
        do {
            let blocks = try await store.list(NoteBlockPayload.self, parentId: note.id)
            let visible = blocks.filter { !$0.payload.tombstone }
            let x = 48.0 + Double((visible.count / 6) % 2) * 400
            let y = 56.0 + Double(visible.count % 6) * 184
            let z = visible.compactMap(\.payload.canvasPlacement?.zIndex).max().map { $0 + 1 } ?? 1
            _ = try await store.appendCanvasEvidence(
                noteId: note.id,
                evidenceId: evidenceId,
                placement: NoteCanvasPlacement(x: x, y: y, width: 360, height: 168, zIndex: z),
                pageIndex: 0
            )
            model.noteLocalMutation()
            onInserted(note.id)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
