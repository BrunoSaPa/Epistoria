import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Notebook") {
                    NavigationLink {
                        DataHealthView(model: model)
                    } label: {
                        SettingsRow(
                            title: "Data Health",
                            detail: "Sync, recovery, exports, conflicts, and connected devices",
                            symbol: "lock.shield"
                        )
                    }
                }

                Section("Learning") {
                    NavigationLink {
                        AIProviderSettingsView(model: model)
                    } label: {
                        SettingsRow(
                            title: "AI providers",
                            detail: "Connect hosted or local AI directly from this iPad",
                            symbol: "cpu"
                        )
                    }
                    SettingsRow(
                        title: "Study Next",
                        detail: "Local suggestions are enabled and work offline",
                        symbol: "arrow.forward.circle"
                    )
                }

                Section("Local processing") {
                    NavigationLink {
                        LocalProcessingSettingsView(model: model)
                    } label: {
                        SettingsRow(
                            title: "OCR and formula recognition",
                            detail: "Offline recognition, languages, and on-device models",
                            symbol: "text.viewfinder"
                        )
                    }
                    NavigationLink {
                        ComputeNodeSettingsView(model: model)
                    } label: {
                        SettingsRow(
                            title: "Compute Nodes",
                            detail: "Optional acceleration for large local work",
                            symbol: "desktopcomputer"
                        )
                    }
                }

                Section("About") {
                    LabeledContent("Product", value: "Epistoria")
                    LabeledContent("Storage", value: "One encrypted notebook")
                }
            }
            .navigationTitle("Settings")
            .epistoriaPageBackground()
        }
    }
}

private struct SettingsRow: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(EpistoriaDesign.ink)
        }
        .accessibilityElement(children: .combine)
    }
}
