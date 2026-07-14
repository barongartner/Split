// JSON persistence for the routing table and presets, in
// ~/Library/Application Support/Split/. Saves are debounced so slider drags
// don't hammer the disk.

import Foundation

@MainActor
final class RouteStore {

    private let directory: URL
    private var routesURL: URL { directory.appendingPathComponent("routes.json") }
    private var presetsURL: URL { directory.appendingPathComponent("presets.json") }
    private var saveWork: DispatchWorkItem?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = base.appendingPathComponent("Split", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func loadTable() -> RoutingTable {
        guard let data = try? Data(contentsOf: routesURL),
              let table = try? JSONDecoder().decode(RoutingTable.self, from: data) else {
            return RoutingTable()
        }
        return table
    }

    func save(table: RoutingTable) {
        saveWork?.cancel()
        let work = DispatchWorkItem { [routesURL] in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(table) {
                try? data.write(to: routesURL, options: .atomic)
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func loadPresets() -> [Preset] {
        guard let data = try? Data(contentsOf: presetsURL),
              let presets = try? JSONDecoder().decode([Preset].self, from: data) else {
            return []
        }
        return presets
    }

    func save(presets: [Preset]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(presets) {
            try? data.write(to: presetsURL, options: .atomic)
        }
    }
}
