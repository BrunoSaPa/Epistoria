import SwiftUI

@main
struct EpistoriaApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            AppRootView(model: model)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, next in
                    switch next {
                    case .background:
                        Task { await model.lock() }
                    case .active:
                        Task { await model.start() }
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
