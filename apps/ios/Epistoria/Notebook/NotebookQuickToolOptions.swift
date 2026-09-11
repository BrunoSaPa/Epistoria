import EpistoriaCore
import SwiftUI

/// Shares the editor's tool state with its detailed popovers; never creates a second set of defaults.
struct NotebookQuickToolOptions: View {
    let tool: NotebookToolID
    let compact: Bool
    @Binding var color: NoteCanvasColor
    @Binding var width: CGFloat
    @Binding var eraserMode: SpatialNotebookEraserMode
    @Binding var eraserWidth: CGFloat
    @Binding var shapeKind: NoteCanvasShapeKind
    @Binding var shapeColor: NoteCanvasColor
    @Binding var shapeWidth: Double
    @Binding var shapeFill: NoteCanvasColor?
    let showDetails: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Divider()
            if !compact {
                Text(tool.title).font(.caption.weight(.semibold))
                preview.frame(height: 38).clipped().accessibilityHidden(true)
                if tool == .eraser {
                    Picker("Eraser mode", selection: $eraserMode) {
                        Text("Area").tag(SpatialNotebookEraserMode.pixel)
                        Text("Stroke").tag(SpatialNotebookEraserMode.stroke)
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("note.quick.eraser-mode")
                    if eraserMode == .pixel {
                        widthMenu(values: [12, 24, 48], selection: $eraserWidth)
                    }
                } else if tool == .pen || tool == .marker || tool == .shape {
                    colorChoices
                    if tool == .shape {
                        Picker("Shape", selection: $shapeKind) {
                            ForEach(NoteCanvasShapeKind.allCases, id: \.self) { kind in
                                Label(kind.label, systemImage: kind.systemImage).tag(kind)
                            }
                        }.pickerStyle(.menu)
                        widthMenu(values: [1, 3, 6], selection: Binding(get: { CGFloat(shapeWidth) }, set: { shapeWidth = Double($0) }))
                    } else {
                        widthMenu(values: tool == .pen ? [2, 4, 8] : [12, 18, 28], selection: $width)
                    }
                }
            }
            Button(action: showDetails) {
                Label("Options", systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("\(tool.title) options")
            .accessibilityIdentifier("note.quick.options")
        }
        .frame(width: 88)
        .foregroundStyle(EpistoriaDesign.ink)
    }

    @ViewBuilder private var preview: some View {
        switch tool {
        case .eraser: NotebookEraserPreview(mode: eraserMode, width: eraserWidth)
        case .shape: NotebookShapePreview(shape: NoteCanvasShape(kind: shapeKind, strokeColor: shapeColor, fillColor: shapeFill, lineWidth: shapeWidth))
        case .pen, .marker: NotebookInkPreview(color: color, width: width, isMarker: tool == .marker)
        default: Image(systemName: tool.symbol)
        }
    }

    private var colorChoices: some View {
        LazyVGrid(columns: [GridItem(.fixed(44), spacing: 0), GridItem(.fixed(44), spacing: 0)], spacing: 0) {
            ForEach(NoteCanvasColor.allCases, id: \.self) { choice in
                let selected = (tool == .shape ? shapeColor : color) == choice
                Button {
                    if tool == .shape { shapeColor = choice } else { color = choice }
                } label: {
                    Circle().fill(Color(uiColor: choice.uiColor))
                        .overlay { Circle().stroke(EpistoriaDesign.ink.opacity(0.25), lineWidth: 0.5) }
                        .frame(width: 20, height: 20)
                        .padding(4)
                        .overlay { Circle().stroke(selected ? EpistoriaDesign.ink : .clear, lineWidth: 2) }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("note.quick.color.\(choice.rawValue)")
            }
        }
    }

    private func widthMenu(values: [CGFloat], selection: Binding<CGFloat>) -> some View {
        Menu {
            ForEach(values, id: \.self) { value in
                Button("\(Int(value)) pt", systemImage: selection.wrappedValue == value ? "checkmark" : "circle") {
                    selection.wrappedValue = value
                }
            }
        } label: {
            Text("\(Int(selection.wrappedValue)) pt").font(.caption.monospacedDigit())
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityLabel("Stroke width, \(Int(selection.wrappedValue)) points")
        .accessibilityIdentifier("note.quick.width")
    }
}
