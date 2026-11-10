import SwiftUI

/// Rename, recolour or delete a board.
struct BoardEditView: View {
    let boardID: Board.ID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colorHex = tilePalette[0]
    @State private var confirmingDelete = false
    @State private var loaded = false

    private var board: Board? { model.boards.first { $0.id == boardID } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Board name", text: $name).submitLabel(.done)
                }
                Section("Colour") {
                    ScrollView(.horizontal, showsIndicators: false) { ColorSwatches(selected: colorHex) { colorHex = $0 } }
                }
                Section {
                    Button("Delete board", role: .destructive) { confirmingDelete = true }
                        .foregroundStyle(Color.red.mix(with: .black, by: 0.3))  // system red is only ~3.5:1 on grouped grey
                } footer: {
                    Text("Deletes the board with its \(board?.tracks.count ?? 0) buttons and their audio files.")
                }
            }
            .navigationTitle("Edit board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await model.updateBoard(boardID, name: name, colorHex: colorHex); dismiss() }
                    }
                    .fontWeight(.semibold).foregroundStyle(.primary)  // the prominent blue Save pill is only ~3.6:1 (white on system blue)
                }
            }
            .confirmationDialog("Delete this board?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete board", role: .destructive) { Task { await model.deleteBoard(boardID); dismiss() } }
            } message: { Text("This cannot be undone.") }
            .onAppear {
                guard !loaded, let b = board else { return }
                name = b.name; colorHex = b.colorHex; loaded = true
            }
        }
        .presentationBackground(Color(.systemGroupedBackground))  // the default glass sheet lets the coloured tiles bleed through the text
    }
}
