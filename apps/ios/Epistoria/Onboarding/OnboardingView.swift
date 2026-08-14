import SwiftUI

struct OnboardingView: View {
    private enum RecoveryStage {
        case display
        case verify
    }

    @Bindable var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var material: NewAccountMaterial?
    @State private var recoveryStage = RecoveryStage.display
    @State private var verificationIndices: [Int] = []
    @State private var verificationAnswers: [Int: String] = [:]
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showRestore = false
    @State private var showLegacyNotebookChoice = false
    #if DEBUG
    @State private var showDevelopmentReset = false
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    HStack(spacing: 10) {
                        EpistoriaBrandMark(size: 34)
                        Text("Epistoria")
                            .font(.headline.weight(.semibold))
                    }
                    if let material {
                        recoveryStep(material)
                    } else {
                        introduction
                    }
                }
                .frame(maxWidth: EpistoriaDesign.Layout.readingWidth, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.vertical, 44)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .epistoriaPageBackground()
            .tint(EpistoriaDesign.accent)
            .sheet(isPresented: $showRestore) {
                RestoreAccountView(model: model)
            }
            #if DEBUG
            .sheet(isPresented: $showDevelopmentReset) {
                DeveloperNotebookResetView {
                    try await model.deleteLocalDevelopmentNotebook()
                }
            }
            #endif
            .alert("An older notebook is on this iPad", isPresented: $showLegacyNotebookChoice) {
                Button("Recover older notebook") {
                    showRestore = true
                }
                #if DEBUG
                Button("Delete local development notebook", role: .destructive) {
                    showDevelopmentReset = true
                }
                #endif
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Epistoria uses one notebook for everything you know. Recover this notebook with its account ID and 24 words. Debug builds can deliberately erase the local development copy.")
            }
            .alert("Setup problem", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onDisappear {
                material = nil
                verificationAnswers = [:]
                errorMessage = nil
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text("PRIVATE KNOWLEDGE, ON YOUR DEVICE")
                    .font(.caption.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.primary)
                Text(model.hasConfiguredNotebook ? "Your notebook is already here." : "A quiet place for what you learn.")
                    .font(.largeTitle.bold())
                Text(
                    model.hasConfiguredNotebook
                        ? "Open the notebook already configured on this iPad, or recover it with its account ID and 24 words."
                        : "Capture notes, study with focus, and keep everything you know connected in one place."
                )
                    .font(.title3)
                    .foregroundStyle(EpistoriaDesign.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 0) {
                onboardingFeature(
                    title: "Available offline",
                    detail: "Start writing before you configure any server.",
                    symbol: "wifi.slash"
                )
                Divider().padding(.leading, 42)
                onboardingFeature(
                    title: "Encrypted before sync",
                    detail: "The server stores opaque records and files.",
                    symbol: "lock.fill"
                )
                Divider().padding(.leading, 42)
                onboardingFeature(
                    title: "AI is optional",
                    detail: "Derived answers remain cited, reviewable, and disposable.",
                    symbol: "sparkles"
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Recovery is your responsibility")
                    .font(.subheadline.weight(.semibold))
                Text("Your 24 recovery words are the only universal way back into your data. Epistoria cannot recover them for you.")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            adaptiveActionLayout {
                if model.hasConfiguredNotebook {
                    openNotebookButton
                } else {
                    createNotebookButton
                }
                restoreNotebookButton
            }

            #if DEBUG
            if model.hasLocalDevelopmentNotebookData {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    Text("DEVELOPMENT ONLY")
                        .font(.caption.weight(.semibold))
                        .tracking(0.5)
                        .foregroundStyle(EpistoriaDesign.mutedInk)
                    Button {
                        showDevelopmentReset = true
                    } label: {
                        Label("Delete local development notebook…", systemImage: "trash")
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("onboarding.development.reset")
                    Text("This control is excluded from release builds. It does not delete a connected server copy.")
                        .font(.caption)
                        .foregroundStyle(EpistoriaDesign.mutedInk)
                }
            }
            #endif
        }
    }

    private var createNotebookButton: some View {
        Button {
            if model.hasUnconfiguredLegacyNotebook {
                showLegacyNotebookChoice = true
            } else {
                prepareNewAccount()
            }
        } label: {
            Text("Create my private notebook")
                .font(.body)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(EpistoriaPrimaryButtonStyle())
        .accessibilityIdentifier("onboarding.create")
    }

    private var openNotebookButton: some View {
        Button {
            isWorking = true
            Task {
                defer { isWorking = false }
                do { try await model.openConfiguredNotebook() }
                catch { errorMessage = error.localizedDescription }
            }
        } label: {
            Text("Open this notebook")
                .font(.body)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(EpistoriaPrimaryButtonStyle())
        .disabled(isWorking)
        .accessibilityIdentifier("onboarding.open")
    }

    private func prepareNewAccount() {
        do {
            material = try model.prepareNewAccount()
            recoveryStage = .display
            verificationAnswers = [:]
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var restoreNotebookButton: some View {
        Button {
            showRestore = true
        } label: {
            Text("Restore with 24 words")
                .font(.body)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(EpistoriaSecondaryButtonStyle())
        .accessibilityIdentifier("onboarding.restore")
    }

    private func onboardingFeature(title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(EpistoriaDesign.mutedInk)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(EpistoriaDesign.mutedInk)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func recoveryStep(_ material: NewAccountMaterial) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if recoveryStage == .display {
                recoveryDisplay(material)
            } else {
                recoveryVerification(material)
            }
        }
    }

    private func recoveryDisplay(_ material: NewAccountMaterial) -> some View {
        let words = material.recoveryWords.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("RECOVERY KIT · STEP 1 OF 2")
                    .font(.caption.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.primary)
                Text("Save your recovery kit")
                    .font(.largeTitle.bold())
                Text("Write down every word in order and the account ID. Keep the copy offline and private.")
                    .font(.body)
                    .foregroundStyle(EpistoriaDesign.mutedInk)
            }

            Label(
                "Anyone with this kit can open your notebook. Without it, a lost device can mean lost data.",
                systemImage: "exclamationmark.shield"
            )
            .font(.subheadline)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                EpistoriaDesign.subtleFill,
                in: RoundedRectangle(cornerRadius: EpistoriaDesign.compactRadius, style: .continuous)
            )

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                spacing: 12
            ) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(EpistoriaDesign.mutedInk)
                            .frame(width: 24, alignment: .trailing)
                        Text(word)
                            .font(.body.monospaced().weight(.semibold))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Word \(index + 1), \(word)")
                }
            }
            .padding(18)
            .overlay {
                RoundedRectangle(cornerRadius: EpistoriaDesign.cardRadius, style: .continuous)
                    .stroke(EpistoriaDesign.border.opacity(0.65), lineWidth: 0.5)
            }
            .privacySensitive()

            VStack(alignment: .leading, spacing: 5) {
                Text("ACCOUNT ID")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(material.accountId.uuidString.lowercased())
                    .font(.footnote.monospaced())
                    .privacySensitive()
            }

            Button {
                verificationIndices = Array((0 ..< words.count).shuffled().prefix(3)).sorted()
                verificationAnswers = [:]
                recoveryStage = .verify
            } label: {
                Text("Continue to verification")
                    .font(.body)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(EpistoriaPrimaryButtonStyle())
            .accessibilityIdentifier("onboarding.recovery.recorded")
        }
    }

    private func recoveryVerification(_ material: NewAccountMaterial) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("RECOVERY KIT · STEP 2 OF 2")
                    .font(.caption.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.primary)
                Text("Verify your copy")
                    .font(.largeTitle.bold())
                Text("Enter the requested words from the copy you just made. This check happens only on this iPad.")
                    .foregroundStyle(EpistoriaDesign.mutedInk)
            }

            ForEach(verificationIndices, id: \.self) { index in
                TextField(
                    "Word \(index + 1)",
                    text: Binding(
                        get: { verificationAnswers[index, default: ""] },
                        set: { verificationAnswers[index] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("onboarding.recovery.word.\(index + 1)")
            }

            adaptiveActionLayout {
                showWordsButton
                openEpistoriaButton(material)
            }
        }
    }

    private var adaptiveActionLayout: AnyLayout {
        if horizontalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize {
            AnyLayout(VStackLayout(spacing: 10))
        } else {
            AnyLayout(HStackLayout(spacing: 10))
        }
    }

    private var showWordsButton: some View {
        Button {
            verificationAnswers = [:]
            recoveryStage = .display
        } label: {
            Text("Show words again")
                .font(.body)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(EpistoriaSecondaryButtonStyle())
    }

    private func openEpistoriaButton(_ material: NewAccountMaterial) -> some View {
        Button {
            isWorking = true
            Task {
                defer { isWorking = false }
                do { try await model.confirmNewAccount(material) }
                catch { errorMessage = error.localizedDescription }
            }
        } label: {
            Group {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Open Epistoria")
                        .font(.body)
                        .fontWeight(.medium)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(EpistoriaPrimaryButtonStyle())
        .disabled(!verificationIsCorrect(material) || isWorking)
        .accessibilityIdentifier("onboarding.recovery.confirm")
    }

    private func verificationIsCorrect(_ material: NewAccountMaterial) -> Bool {
        let words = material.recoveryWords.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard verificationIndices.count == 3 else { return false }
        return verificationIndices.allSatisfy { index in
            guard words.indices.contains(index) else { return false }
            return verificationAnswers[index, default: ""]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == words[index].lowercased()
        }
    }
}

private struct RestoreAccountView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var accountId = ""
    @State private var words = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var normalizedWords: [Substring] {
        words.lowercased().split(whereSeparator: { $0.isWhitespace })
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Account ID", text: $accountId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextEditor(text: $words)
                    .frame(minHeight: 180)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Twenty-four recovery words")
                LabeledContent("Words entered", value: "\(normalizedWords.count) of 24")
                    .foregroundStyle(
                        normalizedWords.count == 24 ? EpistoriaDesign.mutedInk : EpistoriaDesign.attention
                    )
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Restore Epistoria")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore") {
                        guard let id = UUID(uuidString: accountId) else {
                            errorMessage = "Enter the account UUID from your recovery kit."
                            return
                        }
                        Task {
                            isWorking = true
                            defer { isWorking = false }
                            do {
                                try await model.restoreLocalAccount(
                                    accountId: id,
                                    words: normalizedWords.joined(separator: " ")
                                )
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .disabled(
                        UUID(uuidString: accountId) == nil
                            || normalizedWords.count != 24
                            || isWorking
                    )
                    .accessibilityIdentifier("restore.confirm")
                }
            }
        }
        .onDisappear {
            accountId = ""
            words = ""
        }
    }
}
