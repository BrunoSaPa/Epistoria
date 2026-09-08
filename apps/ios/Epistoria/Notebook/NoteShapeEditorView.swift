import EpistoriaCore
import SwiftUI

struct ShapeEditingSelection: Identifiable {
    let id: UUID
    let shape: NoteCanvasShape
}

struct NoteShapeEditorView: View {
    let selection: ShapeEditingSelection
    let onSave: (NoteCanvasShape) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var shape: NoteCanvasShape
    @State private var saving = false
    @State private var errorMessage: String?

    init(selection: ShapeEditingSelection, onSave: @escaping (NoteCanvasShape) async throws -> Void) {
        self.selection = selection
        self.onSave = onSave
        _shape = State(initialValue: selection.shape)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NotebookShapePreview(shape: shape).frame(height: 150)
                        .accessibilityLabel("Shape preview")
                }
                Section("Appearance") {
                    Picker("Shape", selection: $shape.kind) {
                        ForEach(NoteCanvasShapeKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Outline", selection: $shape.strokeColor) {
                        ForEach(NoteCanvasColor.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Line style", selection: Binding(
                        get: { shape.lineStyle ?? .solid }, set: { shape.lineStyle = $0 }
                    )) {
                        ForEach(NoteCanvasLineStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    LabeledContent("Thickness", value: "\(Int(shape.lineWidth)) pt")
                    Slider(value: $shape.lineWidth, in: 1...24, step: 1).accessibilityLabel("Thickness")
                    Toggle("Fill", isOn: Binding(
                        get: { shape.fillColor != nil }, set: { shape.fillColor = $0 ? .graphite : nil }
                    ))
                    if shape.fillColor != nil {
                        Picker("Fill color", selection: Binding(
                            get: { shape.fillColor ?? .graphite }, set: { shape.fillColor = $0 }
                        )) {
                            ForEach(NoteCanvasColor.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                    }
                    Button("Reset changes") { shape = selection.shape }
                }
                if let errorMessage { Text(errorMessage) }
            }
            .disabled(saving)
            .navigationTitle("Edit shape")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        saving = true
                        Task {
                            defer { saving = false }
                            do { try await onSave(shape); dismiss() }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }.disabled(saving)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}
