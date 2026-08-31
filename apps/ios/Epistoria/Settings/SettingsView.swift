import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Interface") {
                    NavigationLink {
                        InterfaceControlsSettingsView(model: model)
                    } label: {
                        SettingsRow(
                            title: "Interface and Controls",
                            detail: "Sidebar order, visibility, and notebook rail tools",
                            symbol: "sidebar.left"
                        )
                    }
                    NavigationLink {
                        NotebookDefaultsView(model: model)
                    } label: {
                        SettingsRow(
                            title: "Notebook Defaults",
                            detail: "Page size, orientation, paper, and color for new notes",
                            symbol: "book.pages"
                        )
                    }
                }

                Section("Data") {
                    NavigationLink {
                        DataHealthView(model: model)
                    } label: {
                        SettingsRow(
                            title: "Data Health",
                            detail: "Sync, recovery, exports, conflicts, and connected devices",
                            symbol: "lock.shield"
                        )
                    }
                    NavigationLink {
                        TrashView(model: model)
                    } label: {
                        SettingsRow(
                            title: "Trash",
                            detail: "Restore deleted items or remove them permanently",
                            symbol: "trash"
                        )
                    }
                    .accessibilityIdentifier("settings.trash")
                }

                Section("AI and Learning") {
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

                Section("Search and Recognition") {
                    NavigationLink {
                        LocalProcessingSettingsView(model: model)
                    } label: {
                        SettingsRow(
                            title: "OCR and formula recognition",
                            detail: "Offline recognition, languages, and on-device models",
                            symbol: "text.viewfinder"
                        )
                    }
                    NavigationLink { ProcessingActivityView(model: model) } label: {
                        SettingsRow(
                            title: "Processing Activity",
                            detail: "Local, direct-provider, and optional accelerated work",
                            symbol: "list.bullet.rectangle"
                        )
                    }
                }

                Section("Acceleration") {
                    NavigationLink { ComputeNodeSettingsView(model: model) } label: {
                        SettingsRow(
                            title: "Compute Nodes",
                            detail: "Optional acceleration for approved heavy local work",
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
