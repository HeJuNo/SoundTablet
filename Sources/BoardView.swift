import SwiftUI
import UniformTypeIdentifiers

struct BoardView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var addingBoard = false
    @State private var newBoardName = ""

    var body: some View {
        @Bindable var m = model
        return NavigationStack {
            VStack(spacing: 0) {
                boardPicker
                if let board = model.activeBoard {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                            ForEach(board.tracks) { TileView(track: $0) }
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView("No board", systemImage: "square.grid.2x2", description: Text("Create a board with +."))
                }
                NowPlayingStrip()
                GlobalBar()
            }
            .navigationTitle("SoundTablet")
            .toolbar {
                Button("Defaults", systemImage: "gearshape") { model.showingDefaults = true }
                Button("Import", systemImage: "square.and.arrow.down") { importing = true }
                    .disabled(model.activeBoard == nil)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { Task { await model.importTracks(urls) } }
            }
            .sheet(isPresented: Binding(get: { model.editingTrackID != nil }, set: { if !$0 { model.editingTrackID = nil } })) {
                if let id = model.editingTrackID { TrackSettingsView(trackID: id) }
            }
            .sheet(isPresented: $m.showingDefaults) { DefaultsView() }
            .alert("New board", isPresented: $addingBoard) {
                TextField("Name", text: $newBoardName)
                Button("Create") { Task { await model.addBoard(name: newBoardName) }; newBoardName = "" }
                Button("Cancel", role: .cancel) { newBoardName = "" }
            }
            .alert("Error", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.lastError ?? "") }
        }
    }

    private var boardPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(model.boards) { b in
                    Button(b.name) { model.activeBoardID = b.id }
                        .buttonStyle(.borderedProminent)
                        .tint(b.id == model.activeBoardID ? Color(hex: b.colorHex) : .gray)
                        .draggable(b.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard let s = items.first, let id = UUID(uuidString: s) else { return false }
                            Task { await model.moveBoard(id, before: b.id) }
                            return true
                        }
                }
                Button("New board", systemImage: "plus") { addingBoard = true }
                    .labelStyle(.iconOnly).buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}
