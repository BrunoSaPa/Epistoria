import EpistoriaCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private enum NoteImageEditorError: LocalizedError {
    case imageUnavailable

    var errorDescription: String? {
        "The selected image could not be read. Choose another image and try again."
    }
}

struct NoteImageEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let image: UIImage
    let filename: String
    let hasOriginalReference: Bool
    let onSave: (NoteCanvasImageConfiguration) async throws -> Void
    let onReplaceFile: (URL, NoteCanvasImageConfiguration) async throws -> Void
    let onReplaceData: (Data, String, NoteCanvasImageConfiguration) async throws -> Void
    let onRestoreOriginal: (NoteCanvasImageConfiguration) async throws -> Void

    @State private var configuration: NoteCanvasImageConfiguration
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isImportingFile = false
    @State private var operationLabel: String?
    @State private var errorMessage: String?

    init(
        image: UIImage,
        filename: String,
        configuration: NoteCanvasImageConfiguration?,
        hasOriginalReference: Bool,
        onSave: @escaping (NoteCanvasImageConfiguration) async throws -> Void,
        onReplaceFile: @escaping (URL, NoteCanvasImageConfiguration) async throws -> Void,
        onReplaceData: @escaping (Data, String, NoteCanvasImageConfiguration) async throws -> Void,
        onRestoreOriginal: @escaping (NoteCanvasImageConfiguration) async throws -> Void
    ) {
        self.image = image
        self.filename = filename
        self.hasOriginalReference = hasOriginalReference
        self.onSave = onSave
        self.onReplaceFile = onReplaceFile
        self.onReplaceData = onReplaceData
        self.onRestoreOriginal = onRestoreOriginal
        _configuration = State(initialValue: (
            configuration ?? NoteCanvasImageConfiguration()
        ).sanitized)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    cropPreview
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    resultPreview
                } header: {
                    Text("Preview")
                } footer: {
                    Text("\(filename). Edits change only encrypted presentation metadata. The image file is not rewritten.")
                }

                cropPresets
                rotationControls
                maskControls
                replacementControls
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(operationLabel != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { performSave() }
                        .fontWeight(.semibold)
                        .disabled(operationLabel != nil)
                }
            }
            .fileImporter(
                isPresented: $isImportingFile,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                guard case let .success(urls) = result, let url = urls.first else {
                    if case let .failure(error) = result { errorMessage = error.localizedDescription }
                    return
                }
                perform("Replacing image…") {
                    try await onReplaceFile(url, replacementConfiguration)
                }
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task {
                    defer { selectedPhoto = nil }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw NoteImageEditorError.imageUnavailable
                        }
                        operationLabel = "Replacing image…"
                        try await onReplaceData(data, "Photo", replacementConfiguration)
                        dismiss()
                    } catch {
                        operationLabel = nil
                        errorMessage = error.localizedDescription
                    }
                }
            }
            .overlay {
                if let operationLabel {
                    ProgressView(operationLabel)
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                }
            }
            .alert("Image edit problem", isPresented: .constant(errorMessage != nil)) {
                Button("Dismiss", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .interactiveDismissDisabled(operationLabel != nil)
    }

    private var cropPreview: some View {
        let uncropped = NoteCanvasImageRenderer.transformedImage(
            image,
            configuration: NoteCanvasImageConfiguration(
                crop: .full,
                mask: .none,
                rotationQuarterTurns: configuration.rotationQuarterTurns
            ),
            maximumDimension: 1_600
        )
        return ImageCropCanvas(image: uncropped, crop: $configuration.crop)
            .frame(minHeight: 300, idealHeight: 380, maxHeight: 460)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
    }

    private var cropPresets: some View {
        Section("Crop") {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    cropPresetButton("Full", systemImage: "rectangle") { .full }
                    cropPresetButton("Square", systemImage: "square") { centeredCrop(aspect: 1) }
                    cropPresetButton("4:3", systemImage: "rectangle.ratio.4.to.3") {
                        centeredCrop(aspect: 4 / 3)
                    }
                    cropPresetButton("16:9", systemImage: "rectangle.ratio.16.to.9") {
                        centeredCrop(aspect: 16 / 9)
                    }
                    cropPresetButton("Inset", systemImage: "arrow.down.right.and.arrow.up.left") {
                        NoteCanvasImageCrop(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            Text("Drag the frame or any corner. Crop coordinates stay attached to this image when the canvas item is resized.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var resultPreview: some View {
        let result = NoteCanvasImageRenderer.transformedImage(
            image,
            configuration: configuration,
            maximumDimension: 1_600
        )
        return VStack(alignment: .leading, spacing: 10) {
            Text("Result")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Image(uiImage: result)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 180)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Edited image result")
        }
        .padding(.vertical, 4)
    }

    private var rotationControls: some View {
        Section("Rotation") {
            HStack {
                rotationButton("Left", systemImage: "rotate.left", delta: -1)
                Spacer()
                Text("\(configuration.rotationQuarterTurns * 90)°")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Rotation \(configuration.rotationQuarterTurns * 90) degrees")
                Spacer()
                rotationButton("Right", systemImage: "rotate.right", delta: 1)
            }
            Button("Reset rotation", systemImage: "arrow.counterclockwise") {
                rotate(to: 0)
            }
            .disabled(configuration.rotationQuarterTurns == 0)
        }
    }

    private var maskControls: some View {
        Section("Mask") {
            Picker("Mask", selection: $configuration.mask) {
                Text("None").tag(NoteCanvasImageMask.none)
                Text("Rounded").tag(NoteCanvasImageMask.roundedRectangle)
                Text("Oval").tag(NoteCanvasImageMask.ellipse)
            }
            .pickerStyle(.segmented)
            if configuration.mask == .roundedRectangle {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Corner size")
                    Slider(value: $configuration.roundedCornerFraction, in: 0.02 ... 0.5)
                }
            }
        }
    }

    private var replacementControls: some View {
        Section {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label("Replace from Photos", systemImage: "photo.on.rectangle")
            }
            Button("Replace from Files", systemImage: "folder") {
                isImportingFile = true
            }
            if hasOriginalReference {
                Button("Restore First Image", systemImage: "arrow.uturn.backward") {
                    perform("Restoring first image…") {
                        try await onRestoreOriginal(replacementConfiguration)
                    }
                }
            }
        } header: {
            Text("Image file")
        } footer: {
            Text("Replacement keeps the canvas frame and mask. Crop and rotation reset for the new file. The first encrypted image remains available for restoration.")
        }
    }

    private var replacementConfiguration: NoteCanvasImageConfiguration {
        NoteCanvasImageConfiguration(
            crop: .full,
            mask: configuration.mask,
            roundedCornerFraction: configuration.roundedCornerFraction,
            rotationQuarterTurns: 0,
            originalAssetId: configuration.originalAssetId
        )
    }

    private func cropPresetButton(
        _ title: String,
        systemImage: String,
        crop: @escaping () -> NoteCanvasImageCrop
    ) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0)) {
                configuration.crop = crop()
            }
        } label: {
            Label(title, systemImage: systemImage)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func rotationButton(_ title: String, systemImage: String, delta: Int) -> some View {
        Button {
            rotate(to: configuration.rotationQuarterTurns + delta)
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func centeredCrop(aspect: Double) -> NoteCanvasImageCrop {
        let uncropped = NoteCanvasImageRenderer.transformedImage(
            image,
            configuration: NoteCanvasImageConfiguration(
                crop: .full,
                rotationQuarterTurns: configuration.rotationQuarterTurns
            ),
            maximumDimension: 1_600
        )
        let imageAspect = Double(uncropped.size.width / max(uncropped.size.height, 1))
        if imageAspect > aspect {
            let width = aspect / imageAspect
            return NoteCanvasImageCrop(x: (1 - width) / 2, y: 0, width: width, height: 1)
        }
        let height = imageAspect / aspect
        return NoteCanvasImageCrop(x: 0, y: (1 - height) / 2, width: 1, height: height)
    }

    private func rotate(to proposed: Int) {
        let target = ((proposed % 4) + 4) % 4
        var crop = configuration.crop.sanitized
        var current = configuration.rotationQuarterTurns
        while current != target {
            let clockwise = (target - current + 4) % 4 <= 2
            if clockwise {
                crop = NoteCanvasImageCrop(
                    x: 1 - crop.y - crop.height,
                    y: crop.x,
                    width: crop.height,
                    height: crop.width
                )
                current = (current + 1) % 4
            } else {
                crop = NoteCanvasImageCrop(
                    x: crop.y,
                    y: 1 - crop.x - crop.width,
                    width: crop.height,
                    height: crop.width
                )
                current = (current + 3) % 4
            }
        }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0)) {
            configuration.crop = crop
            configuration.rotationQuarterTurns = target
        }
    }

    private func performSave() {
        perform("Saving image edit…") { try await onSave(configuration.sanitized) }
    }

    private func perform(
        _ label: String,
        action: @escaping () async throws -> Void
    ) {
        guard operationLabel == nil else { return }
        operationLabel = label
        Task {
            do {
                try await action()
                dismiss()
            } catch {
                operationLabel = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ImageCropCanvas: View {
    private enum Handle: CaseIterable {
        case topLeading
        case topTrailing
        case bottomLeading
        case bottomTrailing
    }

    let image: UIImage
    @Binding var crop: NoteCanvasImageCrop
    @State private var gestureStart: NoteCanvasImageCrop?

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let imageRect = NoteCanvasImageRenderer.aspectFitRect(
                imageSize: image.size,
                destination: bounds
            )
            let cropRect = rect(for: crop.sanitized, in: imageRect)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)

                dimmingPath(bounds: bounds, cropRect: cropRect)
                    .fill(.black.opacity(0.42), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                Rectangle()
                    .stroke(.white, lineWidth: 2)
                    .frame(width: cropRect.width, height: cropRect.height)
                    .position(x: cropRect.midX, y: cropRect.midY)
                    .contentShape(Rectangle())
                    .gesture(moveGesture(in: imageRect))
                    .accessibilityLabel("Crop frame")
                    .accessibilityHint("Drag to move the crop. Use a preset below for VoiceOver cropping.")

                ForEach(Array(Handle.allCases.enumerated()), id: \.offset) { _, handle in
                    cropHandle(handle, cropRect: cropRect, imageRect: imageRect)
                }
            }
            .clipped()
        }
        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private func dimmingPath(bounds: CGRect, cropRect: CGRect) -> Path {
        var path = Path()
        path.addRect(bounds)
        path.addRect(cropRect)
        return path
    }

    private func cropHandle(_ handle: Handle, cropRect: CGRect, imageRect: CGRect) -> some View {
        let point: CGPoint = switch handle {
        case .topLeading: CGPoint(x: cropRect.minX, y: cropRect.minY)
        case .topTrailing: CGPoint(x: cropRect.maxX, y: cropRect.minY)
        case .bottomLeading: CGPoint(x: cropRect.minX, y: cropRect.maxY)
        case .bottomTrailing: CGPoint(x: cropRect.maxX, y: cropRect.maxY)
        }
        return Circle()
            .fill(.white)
            .overlay(Circle().stroke(.black.opacity(0.45), lineWidth: 1))
            .frame(width: 16, height: 16)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .position(point)
            .gesture(resizeGesture(handle, in: imageRect))
            .accessibilityLabel("Crop corner")
    }

    private func moveGesture(in imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = gestureStart ?? crop.sanitized
                gestureStart = start
                let dx = Double(value.translation.width / max(imageRect.width, 1))
                let dy = Double(value.translation.height / max(imageRect.height, 1))
                crop = NoteCanvasImageCrop(
                    x: min(max(start.x + dx, 0), 1 - start.width),
                    y: min(max(start.y + dy, 0), 1 - start.height),
                    width: start.width,
                    height: start.height
                )
            }
            .onEnded { _ in gestureStart = nil }
    }

    private func resizeGesture(_ handle: Handle, in imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = gestureStart ?? crop.sanitized
                gestureStart = start
                let dx = Double(value.translation.width / max(imageRect.width, 1))
                let dy = Double(value.translation.height / max(imageRect.height, 1))
                let minimum = 0.05
                var minX = start.x
                var minY = start.y
                var maxX = start.x + start.width
                var maxY = start.y + start.height
                switch handle {
                case .topLeading:
                    minX = min(max(start.x + dx, 0), maxX - minimum)
                    minY = min(max(start.y + dy, 0), maxY - minimum)
                case .topTrailing:
                    maxX = max(min(start.x + start.width + dx, 1), minX + minimum)
                    minY = min(max(start.y + dy, 0), maxY - minimum)
                case .bottomLeading:
                    minX = min(max(start.x + dx, 0), maxX - minimum)
                    maxY = max(min(start.y + start.height + dy, 1), minY + minimum)
                case .bottomTrailing:
                    maxX = max(min(start.x + start.width + dx, 1), minX + minimum)
                    maxY = max(min(start.y + start.height + dy, 1), minY + minimum)
                }
                crop = NoteCanvasImageCrop(
                    x: minX,
                    y: minY,
                    width: maxX - minX,
                    height: maxY - minY
                )
            }
            .onEnded { _ in gestureStart = nil }
    }

    private func rect(for crop: NoteCanvasImageCrop, in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + CGFloat(crop.x) * imageRect.width,
            y: imageRect.minY + CGFloat(crop.y) * imageRect.height,
            width: CGFloat(crop.width) * imageRect.width,
            height: CGFloat(crop.height) * imageRect.height
        )
    }
}
