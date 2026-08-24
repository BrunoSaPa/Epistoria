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
                            detail: "Choose the AI service used by your trusted Mac",
                            symbol: "cpu"
                        )
                    }
                    SettingsRow(
                        title: "Study Next",
                        detail: "Local suggestions are enabled and work offline",
                        symbol: "arrow.forward.circle"
                    )
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
