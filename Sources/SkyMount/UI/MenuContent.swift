import SwiftUI
import SkyMountCore

struct MenuContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.connections.isEmpty {
            Text("No connections yet")
            Button("Add Connection…") { openConnections() }
        } else {
            ForEach(model.connections) { c in
                connectionMenu(c)
            }
        }

        Divider()
        Button("Connections…") { openConnections() }
            .keyboardShortcut(",")
        Toggle("Open at Login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
        if let error = model.loginItemError {
            Text(error)
        }
        Button("Quit SkyMount") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private func connectionMenu(_ c: ConnectionConfig) -> some View {
        let status = model.status(of: c.id)
        Menu {
            Text(status.label)
            if case .failed(let message) = status {
                Text(message)
            }
            Divider()
            switch status {
            case .mounted:
                activitySection(c.id)
                Button("Show in Finder") { model.showInFinder(c.id) }
                Button("Refresh Folders") { model.refreshFolders(c.id) }
                    .help("Show changes made on the server right away instead of after the refresh interval.")
                Button("Unmount") { model.unmount(c.id) }
            case .working:
                EmptyView()
            case .idle, .failed:
                Button("Mount") { model.mount(c.id) }
            }
            Divider()
            Button("Edit Connection…") {
                model.selection = c.id
                openConnections()
            }
        } label: {
            Label("\(c.displayName)  (\(status.label))", systemImage: status.symbol)
        }
    }

    @ViewBuilder
    private func activitySection(_ id: UUID) -> some View {
        if let a = model.activity[id] {
            if a.offline {
                Text("Server unreachable: showing offline copies")
            }
            let failed = a.uploads.values.filter { if case .failed = $0 { return true } else { return false } }.count
            if !a.uploads.isEmpty {
                Text(failed > 0
                     ? "\(a.uploads.count) file\(a.uploads.count == 1 ? "" : "s") not uploaded yet, \(failed) failed (retrying)"
                     : "Uploading \(a.uploads.count) file\(a.uploads.count == 1 ? "" : "s")")
            }
            if !a.downloads.isEmpty {
                Text("Downloading \(a.downloads.count) file\(a.downloads.count == 1 ? "" : "s")")
            }
            if !a.pinned.isEmpty {
                Menu("Kept Offline (\(a.pinned.count))") {
                    ForEach(a.pinned.keys.sorted(), id: \.self) { path in
                        Menu("\(path)  (\(Self.describe(a.pinned[path]!)))") {
                            Button("Stop Keeping Offline") { model.unpin(path, in: id) }
                        }
                    }
                    Divider()
                    Text("Right-click a file or folder in Finder and choose Keep Offline to add one.")
                }
            }
            Divider()
        }
    }

    private static func describe(_ state: PinState) -> String {
        switch state {
        case .syncing(let done, let total): return total > 0 ? "downloading \(done) of \(total)" : "checking"
        case .synced(let checked):
            return "up to date, checked \(checked.formatted(date: .omitted, time: .shortened))"
        case .failed(let message): return "stopped: \(message)"
        }
    }

    private func openConnections() {
        openWindow(id: "connections")
        NSApp.activate(ignoringOtherApps: true)
    }
}
