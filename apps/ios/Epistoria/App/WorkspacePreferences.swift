import EpistoriaCore
import Foundation
import Observation
import SwiftUI

enum NotebookToolID: String, Codable, CaseIterable, Identifiable {
    case select
    case pen
    case marker
    case eraser
    case text
    case image
    case shape
    case pages
    case undo
    case redo
    case symbol
    case evidence
    case ocr
    case learn
    case ask
    case math

    var id: Self { self }

    static let defaultCore: [Self] = [
        .select, .pen, .marker, .eraser, .text, .image, .shape, .pages, .undo, .redo,
    ]

    static let optional: [Self] = [.symbol, .evidence, .ocr, .learn, .ask, .math]

    var title: String {
        switch self {
        case .select: "Select"
        case .pen: "Pen"
        case .marker: "Marker"
        case .eraser: "Eraser"
        case .text: "Text"
        case .image: "Image"
        case .shape: "Shape"
        case .pages: "Pages"
        case .undo: "Undo"
        case .redo: "Redo"
        case .symbol: "Symbol"
        case .evidence: "Evidence"
        case .ocr: "OCR"
        case .learn: "Learn"
        case .ask: "Ask"
        case .math: "Math"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "pencil.tip"
        case .marker: "highlighter"
        case .eraser: "eraser"
        case .text: "textformat"
        case .image: "photo.badge.plus"
        case .shape: "square.on.circle"
        case .pages: "rectangle.stack"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .symbol: "function"
        case .evidence: "quote.bubble"
        case .ocr: "text.viewfinder"
        case .learn: "graduationcap"
        case .ask: "sparkles"
        case .math: "x.squareroot"
        }
    }
}

@MainActor
@Observable
final class WorkspacePreferences {
    private struct Snapshot: Codable {
        var sidebarOrder: [String]
        var hiddenSidebarItems: Set<String>
        var learningPinned: Bool
        var notebookToolOrder: [NotebookToolID]
        var pinnedOptionalTools: Set<NotebookToolID>
        var processingRoutePreference: ProcessingRoutePreference
        var defaultPageFormat: NotePageFormat
        var defaultPageOrientation: NotePageOrientation
        var defaultPaperStyle: NotePaperStyle
        var defaultPaperColor: NotePaperColor
    }

    private static let storageKey = "epistoria.workspace-preferences.v1"
    private let defaults: UserDefaults

    var sidebarOrder: [AppSection] { didSet { persist() } }
    var hiddenSidebarItems: Set<AppSection> { didSet { persist() } }
    var learningPinned: Bool { didSet { persist() } }
    var notebookToolOrder: [NotebookToolID] { didSet { persist() } }
    var pinnedOptionalTools: Set<NotebookToolID> { didSet { persist() } }
    var processingRoutePreference: ProcessingRoutePreference { didSet { persist() } }
    var defaultPageFormat: NotePageFormat { didSet { persist() } }
    var defaultPageOrientation: NotePageOrientation { didSet { persist() } }
    var defaultPaperStyle: NotePaperStyle { didSet { persist() } }
    var defaultPaperColor: NotePaperColor { didSet { persist() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        {
            let decodedSections = snapshot.sidebarOrder.compactMap(AppSection.init(rawValue:))
            sidebarOrder = Self.sanitizedSidebarOrder(decodedSections)
            hiddenSidebarItems = Set(snapshot.hiddenSidebarItems.compactMap(AppSection.init(rawValue:)))
            learningPinned = snapshot.learningPinned
            notebookToolOrder = Self.sanitizedToolOrder(snapshot.notebookToolOrder)
            pinnedOptionalTools = snapshot.pinnedOptionalTools.intersection(Set(NotebookToolID.optional))
            processingRoutePreference = snapshot.processingRoutePreference
            defaultPageFormat = snapshot.defaultPageFormat
            defaultPageOrientation = snapshot.defaultPageOrientation
            defaultPaperStyle = snapshot.defaultPaperStyle
            defaultPaperColor = snapshot.defaultPaperColor
        } else {
            sidebarOrder = AppSection.defaultSidebarOrder
            hiddenSidebarItems = []
            learningPinned = false
            notebookToolOrder = NotebookToolID.defaultCore
            pinnedOptionalTools = []
            processingRoutePreference = ProcessingRoutePreference()
            defaultPageFormat = .a4
            defaultPageOrientation = .portrait
            defaultPaperStyle = .plain
            defaultPaperColor = .white
        }
    }

    var visibleSidebarSections: [AppSection] {
        var values = sidebarOrder.filter { !hiddenSidebarItems.contains($0) }
        if learningPinned, !values.contains(.learning) {
            let index = values.firstIndex(of: .search) ?? values.endIndex
            values.insert(.learning, at: index)
        }
        return values
    }

    var visibleNotebookTools: [NotebookToolID] {
        notebookToolOrder + NotebookToolID.optional.filter { pinnedOptionalTools.contains($0) }
    }

    func setSidebarVisible(_ section: AppSection, visible: Bool) {
        guard section != .today, section != .notebook else { return }
        if visible { hiddenSidebarItems.remove(section) }
        else { hiddenSidebarItems.insert(section) }
    }

    func moveSidebarItems(from source: IndexSet, to destination: Int) {
        sidebarOrder.move(fromOffsets: source, toOffset: destination)
    }

    func moveNotebookTools(from source: IndexSet, to destination: Int) {
        notebookToolOrder.move(fromOffsets: source, toOffset: destination)
    }

    func resetSidebar() {
        sidebarOrder = AppSection.defaultSidebarOrder
        hiddenSidebarItems = []
        learningPinned = false
    }

    func resetNotebookRail() {
        notebookToolOrder = NotebookToolID.defaultCore
        pinnedOptionalTools = []
    }

    private func persist() {
        let snapshot = Snapshot(
            sidebarOrder: sidebarOrder.map(\.rawValue),
            hiddenSidebarItems: Set(hiddenSidebarItems.map(\.rawValue)),
            learningPinned: learningPinned,
            notebookToolOrder: notebookToolOrder,
            pinnedOptionalTools: pinnedOptionalTools,
            processingRoutePreference: processingRoutePreference,
            defaultPageFormat: defaultPageFormat,
            defaultPageOrientation: defaultPageOrientation,
            defaultPaperStyle: defaultPaperStyle,
            defaultPaperColor: defaultPaperColor
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private static func sanitizedSidebarOrder(_ decoded: [AppSection]) -> [AppSection] {
        var result: [AppSection] = []
        for item in decoded + AppSection.defaultSidebarOrder
        where !result.contains(item) && item != .settings {
            result.append(item)
        }
        return result
    }

    private static func sanitizedToolOrder(_ decoded: [NotebookToolID]) -> [NotebookToolID] {
        var result: [NotebookToolID] = []
        for item in decoded + NotebookToolID.defaultCore
        where NotebookToolID.defaultCore.contains(item) && !result.contains(item) {
            result.append(item)
        }
        return result
    }
}
