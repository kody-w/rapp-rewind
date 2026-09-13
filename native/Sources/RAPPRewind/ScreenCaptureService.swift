import AppKit
import CoreGraphics
import Foundation
import RAPPRewindCore
import ScreenCaptureKit

private final class CaptureReply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(with: result)
    }
}

@MainActor
final class ScreenCaptureService: ScreenCapturing {
    private var hasRequested = false
    private var cancelPending: (() -> Void)?
    private var generation = 0

    func authorizationStatus() -> ScreenPermission {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier == "io.rapp.rewind" else {
            return .denied
        }
        if CGPreflightScreenCaptureAccess() { return .granted }
        return hasRequested ? .denied : .notDetermined
    }

    func requestAuthorization() async -> ScreenPermission {
        hasRequested = true
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier == "io.rapp.rewind" else {
            return .denied
        }
        _ = CGRequestScreenCaptureAccess()
        return authorizationStatus()
    }

    func cancel() {
        generation += 1
        cancelPending?()
        cancelPending = nil
    }

    func capture(settings: CaptureSettings) async throws -> CapturedFrame {
        guard authorizationStatus() == .granted else { throw RewindError.permissionDenied }
        let token = generation
        let frontBefore = try frontmost()
        guard !settings.privacy.excludes(frontBefore.context) else { throw RewindError.excluded }
        let content = try await shareableContent()
        try check(token)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
            throw RewindError.captureUnavailable("the main display is unavailable or the session is locked")
        }
        let screenContext = context(for: frontBefore, in: content)
        try enforcePrivacy(content, display: display, front: screenContext, policy: settings.privacy)
        let excludedApps = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
                || settings.privacy.excludes(ScreenContext(app: $0.applicationName, bundle: $0.bundleIdentifier))
        }
        let excludedPIDs = Set(excludedApps.map(\.processID))
        let titleExceptions = content.windows.filter { window in
            guard let app = window.owningApplication, !excludedPIDs.contains(app.processID) else { return false }
            return settings.privacy.excludes(ScreenContext(app: app.applicationName, bundle: app.bundleIdentifier, title: window.title ?? ""))
        }
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: titleExceptions)
        let configuration = SCStreamConfiguration()
        let scale = min(1, Double(settings.maximumDimension) / Double(max(display.width, display.height)))
        configuration.width = max(1, Int(Double(display.width) * scale))
        configuration.height = max(1, Int(Double(display.height) * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.preservesAspectRatio = true
        let image = try await screenshot(filter: filter, configuration: configuration)
        try check(token)
        let frontAfter = try frontmost()
        let after = try await shareableContent()
        try check(token)
        guard let currentDisplay = after.displays.first(where: { $0.displayID == display.displayID }),
              currentDisplay.frame == display.frame, currentDisplay.displayID == CGMainDisplayID() else {
            throw RewindError.captureUnavailable("the main display changed during capture; the image was discarded")
        }
        try enforcePrivacy(after, display: currentDisplay, front: context(for: frontAfter, in: after), policy: settings.privacy)
        guard frontBefore.pid == frontAfter.pid,
              screenContext.title == context(for: frontAfter, in: after).title else {
            throw RewindError.captureUnavailable("the active window changed during the sample; the image was discarded")
        }
        return try ImagePipeline.prepare(image, settings: settings, context: screenContext)
    }

    private func check(_ token: Int) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        guard authorizationStatus() == .granted else { throw RewindError.permissionDenied }
    }

    private func frontmost() throws -> (pid: pid_t, context: ScreenContext) {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw RewindError.captureUnavailable("no active application")
        }
        guard app.bundleIdentifier != "com.apple.loginwindow",
              app.bundleIdentifier != "com.apple.ScreenSaver.Engine" else {
            throw RewindError.captureUnavailable("the session is locked")
        }
        var context = ScreenContext(app: app.localizedName ?? "", bundle: app.bundleIdentifier ?? "")
        if let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            context.title = windows.first {
                ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier
                    && !(($0[kCGWindowName as String] as? String) ?? "").isEmpty
            }?[kCGWindowName as String] as? String ?? ""
        }
        return (app.processIdentifier, context)
    }

    private func context(for front: (pid: pid_t, context: ScreenContext), in content: SCShareableContent) -> ScreenContext {
        var context = front.context
        if context.title.isEmpty {
            context.title = content.windows.first {
                $0.owningApplication?.processID == front.pid && $0.isOnScreen && !($0.title ?? "").isEmpty
            }?.title ?? ""
        }
        return context
    }

    private func enforcePrivacy(
        _ content: SCShareableContent, display: SCDisplay, front: ScreenContext, policy: PrivacyPolicy
    ) throws {
        let windows = content.windows.filter { $0.isOnScreen && $0.frame.intersects(display.frame) }.map {
            ScreenContext(app: $0.owningApplication?.applicationName ?? "",
                          bundle: $0.owningApplication?.bundleIdentifier ?? "", title: $0.title ?? "")
        }
        guard !policy.skipsSample(frontmost: front, visibleWindows: windows) else { throw RewindError.excluded }
    }

    private func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            let reply = CaptureReply<SCShareableContent>(continuation)
            cancelPending = { reply.finish(.failure(CancellationError())) }
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let error { reply.finish(.failure(error)) }
                else if let content { reply.finish(.success(content)) }
                else { reply.finish(.failure(RewindError.captureUnavailable("ScreenCaptureKit returned no content"))) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
                reply.finish(.failure(RewindError.captureUnavailable("display discovery timed out")))
            }
        }
    }

    private func screenshot(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let reply = CaptureReply<CGImage>(continuation)
            cancelPending = { reply.finish(.failure(CancellationError())) }
            // SCScreenshotManager is macOS 14+. No macOS 15 microphone/recording APIs are used.
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error { reply.finish(.failure(error)) }
                else if let image { reply.finish(.success(image)) }
                else { reply.finish(.failure(RewindError.captureUnavailable("ScreenCaptureKit returned no image"))) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
                reply.finish(.failure(RewindError.captureUnavailable("screen sample timed out")))
            }
        }
    }
}
