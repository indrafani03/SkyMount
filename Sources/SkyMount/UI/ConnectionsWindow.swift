import SwiftUI
import SkyMountCore

struct ConnectionsWindow: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmDelete = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.connections) { c in
                    ConnectionRow(config: c, status: model.status(of: c.id))
                        .tag(c.id)
                }
            }
            .overlay {
                if model.connections.isEmpty {
                    ContentUnavailableView {
                        Label("No Connections", systemImage: "externaldrive.connected.to.line.below")
                    } description: {
                        Text("Add an SFTP or FTP server, an S3 bucket, or a Google Drive with the + button below.")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 2) {
                    Button(action: add) { Image(systemName: "plus").frame(width: 24, height: 22) }
                        .help("Add a connection")
                        .accessibilityLabel("Add connection")
                    Button { confirmDelete = true } label: { Image(systemName: "minus").frame(width: 24, height: 22) }
                        .help("Delete the selected connection")
                        .accessibilityLabel("Delete connection")
                        .disabled(model.selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if let id = model.selection, let config = model.connections.first(where: { $0.id == id }) {
                ConnectionEditor(original: config)
                    .id(config.id)
            } else {
                ContentUnavailableView("Select a Connection", systemImage: "sidebar.left",
                                       description: Text("Choose a connection on the left to edit or mount it."))
            }
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete) {
            Button("Delete Connection", role: .destructive) {
                if let id = model.selection {
                    model.delete(id)
                    model.selection = model.connections.first?.id
                }
            }
        } message: {
            Text("The volume is unmounted and the saved passwords and tokens are removed from the keychain. Files on the server are not touched.")
        }
        .alert("Could Not Save", isPresented: Binding(get: { model.saveError != nil },
                                                      set: { if !$0 { model.saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.saveError ?? "")
        }
    }

    private var deleteTitle: String {
        let name = model.connections.first { $0.id == model.selection }?.displayName ?? "connection"
        return "Delete “\(name)”?"
    }

    private func add() {
        var c = ConnectionConfig()
        c.name = "New Connection"
        model.upsert(c)
        model.selection = c.id
    }
}

private struct ConnectionRow: View {
    let config: ConnectionConfig
    let status: MountStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.symbol)
                .foregroundStyle(isFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(config.displayName)
                    .lineLimit(1)
                Text("\(config.kind.title) · \(status.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }
}
