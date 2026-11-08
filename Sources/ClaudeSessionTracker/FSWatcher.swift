import Foundation
import CoreServices

/// Thin FSEvents wrapper: calls `onChange` (coalesced by `latency`) when files under `paths` change.
final class FSWatcher {
    private var stream: FSEventStreamRef?
    private let callback: () -> Void

    init(paths: [String], latency: TimeInterval = 0.5, onChange: @escaping () -> Void) {
        callback = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue().callback()
        }, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
