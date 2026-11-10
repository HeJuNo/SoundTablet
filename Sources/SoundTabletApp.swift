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
                .task {
                    await model.load(); await DemoScreen.seedIfRequested(model)
                    #if DEBUG  // `-importStudio <folder>`: runs the Soundboard Studio import without the file picker
                    if let p = UserDefaults.standard.string(forKey: "importStudio") { print("IMPORT:", await model.importSoundboardStudio(URL(fileURLWithPath: p))) }
                    #endif
                    #if DEBUG  // `-demoBoard Julia`: opens that board
                    if let n = UserDefaults.standard.string(forKey: "demoBoard"), let b = model.boards.first(where: { $0.name == n }) { model.activeBoardID = b.id }
                    #endif
                    await model.syncNow()
                    if let d = DemoScreen.current {  // screenshot script only
                        model.editingTrackID = model.activeBoard?.tracks.first { $0.name == "Loop Demo" }?.id
                        model.showingDefaults = d == "defaults"
                        if d == "defaults" || d == "boardedit" { model.editingTrackID = nil }
                        if d == "boardedit" { model.editingBoardID = model.activeBoardID }
                    }
                    #if DEBUG  // screenshot script only: `-demoPlay "Loop Demo,Applause"` starts those tracks
                    try? await Task.sleep(for: .seconds(1))  // let the engine finish loading
                    for name in (UserDefaults.standard.string(forKey: "demoPlay") ?? "").split(separator: ",") {
                        if let t = model.activeBoard?.tracks.first(where: { $0.name == name }) { model.tap(t.id) }
                    }
                    try? await Task.sleep(for: .seconds(0.7))  // `-demoPause "440 Hz"`: tap again = pause
                    for name in (UserDefaults.standard.string(forKey: "demoPause") ?? "").split(separator: ",") {
                        if let t = model.activeBoard?.tracks.first(where: { $0.name == name }) { model.tap(t.id) }
                    }
                    #endif
                }
                // "periodic" sync: whenever the app leaves or re-enters the foreground (iOS has no reliable timers)
                .onChange(of: phase) { if phase == .background || phase == .active { Task { await model.syncNow() } } }
        }
    }
}
