import Darwin
import Foundation

@main
struct FSEventProbe {
    private enum ProbeError: Error {
        case usage
        case timeout(source: String, destination: String)
    }

    static func main() async {
        do {
            guard CommandLine.arguments.count == 2,
                  CommandLine.arguments[1].hasPrefix("/") else {
                throw ProbeError.usage
            }
            let parent = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw ProbeError.usage
            }
            try await run(parent: parent)
        } catch {
            let message: String
            if case ProbeError.usage = error {
                message = "Usage: fsevents-probe /absolute/existing/writable/directory"
            } else {
                message = "FSEvents probe failed. \(error)"
            }
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }

    private static func run(parent: URL) async throws {
        let root = parent.appending(path: "radix-fsevents-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        let first = root.appending(path: "First", directoryHint: .isDirectory)
        let second = root.appending(path: "Second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        let original = first.appending(path: "payload.bin")
        let renamed = second.appending(path: "payload.bin")
        try Data([1, 2, 3]).write(to: original)
        let provider = DarwinFileSystemEventHistoryProvider()
        let volume = try DarwinFileSystemEventHistoryProvider.volumeContext(for: root)
        print("target=\(root.path) physical_volume_root=\(volume.rootPath) relative=\(volume.relativeTargetPath)")
        for trial in 1...3 {
            try await Task.sleep(for: .seconds(1))
            let since = try provider.currentCheckpoint(for: root)
            let source = trial.isMultiple(of: 2) ? renamed : original
            let destination = trial.isMultiple(of: 2) ? original : renamed
            try FileManager.default.moveItem(at: source, to: destination)
            let history = try await renamedHistory(
                provider: provider,
                root: root,
                since: since,
                source: source.path,
                destination: destination.path
            )
            print("trial=\(trial) since=\(since.eventID) through=\(history.through.eventID) history_done=true rename_endpoints=both")
            print(String(decoding: try JSONEncoder().encode(history.events), as: UTF8.self))
        }
    }

    private static func renamedHistory(
        provider: DarwinFileSystemEventHistoryProvider,
        root: URL,
        since: ScanIncrementalCheckpoint,
        source: String,
        destination: String
    ) async throws -> FileSystemEventHistory {
        try await withThrowingTaskGroup(of: FileSystemEventHistory.self) { group in
            group.addTask {
                while true {
                    try Task.checkCancellation()
                    let through = try provider.currentCheckpoint(for: root)
                    if through.eventID > since.eventID {
                        let history = try await provider.history(for: root, since: since, through: through)
                        let renamedPaths = Set(history.events.filter { $0.flags.contains(.itemRenamed) }.map(\.path))
                        if renamedPaths.contains(source), renamedPaths.contains(destination) {
                            return history
                        }
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw ProbeError.timeout(source: source, destination: destination)
            }
            defer { group.cancelAll() }
            guard let history = try await group.next() else { throw CancellationError() }
            return history
        }
    }
}
