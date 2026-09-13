import Darwin
import Foundation

public final class CaptureLease {
    private var descriptor: Int32 = -1
    private let paths: RewindPaths

    public init(paths: RewindPaths) { self.paths = paths }

    public func acquire() throws {
        guard descriptor == -1 else { return }
        let legacyPID = paths.root.appendingPathComponent("capture.pid")
        if FileManager.default.fileExists(atPath: legacyPID.path) {
            let value = try String(contentsOf: legacyPID, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            if let pid = Int32(value), pid > 1, kill(pid, 0) == 0 || errno == EPERM {
                throw RewindError.alreadyCapturing
            }
        }
        try RewindPaths.createPrivateDirectory(paths.root)
        let file = paths.root.appendingPathComponent("native-capture.lock")
        let fd = Darwin.open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RewindError.captureUnavailable("cannot create the native capture lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw RewindError.alreadyCapturing
        }
        descriptor = fd
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
