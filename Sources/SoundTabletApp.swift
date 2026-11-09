import SwiftUI

@main
struct SoundTabletApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var model: AppModel = {
        let root = URL.documentsDirectory.appending(path: "SoundTablet")
        return AppModel(store: LocalBoardStore(root: root), sync: SyncConfig(local: root, cloud: ICloudLocation.containerURL))
    }()

    var body: some Scene {
        WindowGroup {
            BoardView()
                .environment(model)
                .task { await model.load(); await model.syncNow() }
                // "periodic" sync: whenever the app leaves or re-enters the foreground (iOS has no reliable timers)
                .onChange(of: phase) { if phase == .background || phase == .active { Task { await model.syncNow() } } }
        }
    }
}
