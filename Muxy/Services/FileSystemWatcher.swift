import CoreServices
import Foundation

final class FileSystemWatcher: @unchecked Sendable {
    static let keepNonGitInternalEvents: @Sendable (_ path: String, _ isDirectory: Bool) -> Bool = { path, isDirectory in
        let isGitInternal = path.contains("/.git/")
        let isLockFile = path.hasSuffix(".lock")
        if isGitInternal, isLockFile || isDirectory { return false }
        return true
    }

    private let queue = DispatchQueue(label: "app.muxy.fs-watcher", qos: .utility)
    private var stream: FSEventStreamRef?
    private var debounceWork: DispatchWorkItem?
    private var pendingPaths = Set<String>()
    private var handler: (@Sendable ([String]) -> Void)?
    private let eventFilter: @Sendable (_ path: String, _ isDirectory: Bool) -> Bool

    init?(
        directoryPath: String,
        eventFilter: @escaping @Sendable (_ path: String, _ isDirectory: Bool) -> Bool = FileSystemWatcher
            .keepNonGitInternalEvents,
        handler: @escaping @Sendable ([String]) -> Void
    ) {
        guard FileManager.default.fileExists(atPath: directoryPath) else { return nil }

        self.handler = handler
        self.eventFilter = eventFilter

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let paths = [directoryPath] as CFArray
        guard let stream = FSEventStreamCreate(
            nil,
            { _, clientInfo, numEvents, eventPaths, eventFlags, _ in
                guard let clientInfo, numEvents > 0 else { return }
                let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
                guard let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String]
                else { return }
                let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))

                let relevant = zip(paths, flags).compactMap { path, flag -> String? in
                    let isDirectory = flag & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
                    return watcher.eventFilter(path, isDirectory) ? path : nil
                }
                guard !relevant.isEmpty else { return }

                watcher.scheduleRefresh(paths: relevant)
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )
        else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        handler = nil
        debounceWork?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func scheduleRefresh(paths: [String]) {
        pendingPaths.formUnion(paths)
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let changed = Array(pendingPaths)
            pendingPaths.removeAll()
            handler?(changed)
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
