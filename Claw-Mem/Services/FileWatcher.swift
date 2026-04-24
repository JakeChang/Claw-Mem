import Foundation

final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let watchPath: String
    private var debounceTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "me.jk.ClawMem.watcher")
    /// Prevents deallocation while FSEventStream is active (avoids dangling pointer in callback).
    private var selfRetain: FileWatcher?
    var onChangeDetected: (@Sendable () -> Void)?

    init(watchPath: String = NSHomeDirectory() + "/.claude/projects") {
        self.watchPath = watchPath
    }

    func start() {
        queue.async { [self] in
            guard stream == nil else { return }
            let pathsToWatch = [watchPath] as CFArray

            var context = FSEventStreamContext()
            context.info = Unmanaged.passUnretained(self).toOpaque()

            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info = info else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.handleEvents()
            }

            guard let newStream = FSEventStreamCreate(
                nil,
                callback,
                &context,
                pathsToWatch,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.5,
                UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
            ) else { return }

            stream = newStream
            selfRetain = self
            FSEventStreamSetDispatchQueue(newStream, queue)
            FSEventStreamStart(newStream)
        }
    }

    func stop() {
        queue.async { [self] in
            guard let s = stream else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
            selfRetain = nil
            debounceTask?.cancel()
            debounceTask = nil
        }
    }

    /// Called on `queue` by FSEventStream callback — no further synchronization needed.
    private func handleEvents() {
        debounceTask?.cancel()
        debounceTask = Task { @Sendable [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.onChangeDetected?()
        }
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        debounceTask?.cancel()
    }
}
