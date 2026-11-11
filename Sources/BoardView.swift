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
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: model.tileMinWidth), spacing: 12)], spacing: 12) {
                            ForEach(board.tracks) { TileView(track: $0) }
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView("No board", systemImage: "square.grid.2x2", description: Text("Create a board with +."))
                }
                GlobalBar()
            }
            .navigationTitle("SoundTablet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { if model.transportStyle == .toolbar { TransportToolbar(model: model) } }
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
            .sheet(isPresented: Binding(get: { model.editingBoardID != nil }, set: { if !$0 { model.editingBoardID = nil } })) {
                if let id = model.editingBoardID { BoardEditView(boardID: id) }
            }
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
        ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: model.boardBarStyle == .tabs ? 6 : 8) {
                ForEach(model.boards) { b in
                    boardButton(b)
                        .id(b.id)
                        .accessibilityAddTraits(b.id == model.activeBoardID ? .isSelected : [])
                        .contextMenu { Button("Edit board…", systemImage: "pencil") { model.editingBoardID = b.id } }
                        .draggable(b.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard let s = items.first, let id = UUID(uuidString: s) else { return false }
                            Task { if model.boardID(of: id) != nil { await model.moveTrack(id, toBoard: b.id) } else { await model.moveBoard(id, before: b.id) } }
                            return true
                        }
                }
                Button("New board", systemImage: "plus") { addingBoard = true }
                    .labelStyle(.iconOnly).buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .onChange(of: model.activeBoardID) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }  // keep the selected board in view
        .task(id: model.boards.count) { if let id = model.activeBoardID { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    @ViewBuilder private func boardButton(_ b: Board) -> some View {
        let selected = b.id == model.activeBoardID, color = Color(hex: b.colorHex)
        switch model.boardBarStyle {
        case .chips:  // filled pill: board colour when selected, grey otherwise
            Button { model.activeBoardID = b.id } label: { Text(b.name).lineLimit(1).fixedSize() }
                .buttonStyle(.borderedProminent)
                .tint(selected ? color.mix(with: .black, by: 0.3) : .gray.mix(with: .black, by: 0.45))  // white title stays readable on both
        case .tabs:  // plain titles with a colour dot; the selected one is bold with a coloured underline
            Button { model.activeBoardID = b.id } label: {
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 10, height: 10)
                        Text(b.name).font(.headline).fontWeight(selected ? .bold : .regular).lineLimit(1).fixedSize()
                    }
                    Capsule().fill(selected ? color : .clear).frame(height: 3)
                }
                .padding(.horizontal, 10).frame(minHeight: 44)
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .colors:  // every board in its own colour; the selected one is brighter and ringed
            Button { model.activeBoardID = b.id } label: {
                Text(b.name).font(.headline).fontWeight(selected ? .bold : .regular).lineLimit(1).fixedSize()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(minHeight: 44)
                    .background(color.mix(with: .black, by: selected ? 0.25 : 0.5), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary, lineWidth: selected ? 3 : 0))
            }
            .buttonStyle(.plain)
        }
    }
}

/// Look of the board buttons above the grid (Defaults > Display).
enum BoardBarStyle: String, CaseIterable, Identifiable {
    case chips, tabs, colors
    var id: String { rawValue }
    var title: String { switch self { case .chips: "Pills"; case .tabs: "Tabs"; case .colors: "Colours" } }
}
