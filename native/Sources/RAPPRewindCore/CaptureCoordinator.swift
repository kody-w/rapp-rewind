import Combine
import Foundation

@MainActor
public protocol ScreenCapturing: AnyObject {
    func authorizationStatus() -> ScreenPermission
    func requestAuthorization() async -> ScreenPermission
    func capture(settings: CaptureSettings) async throws -> CapturedFrame
    func cancel()
}

@MainActor
public protocol CaptureClock {
    var now: Date { get }
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemCaptureClock: CaptureClock {
    public nonisolated init() {}
    public var now: Date { Date() }
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0.001, seconds) * 1_000_000_000))
    }
}

@MainActor
public final class CaptureCoordinator: ObservableObject {
    @Published public private(set) var state: CaptureState = .stopped
    @Published public private(set) var permission: ScreenPermission
    @Published public private(set) var diagnostics: [DiagnosticEvent] = []
    @Published public private(set) var lastOutcome = "Capture starts only when you press Start."
    @Published public private(set) var lastMomentID: Int64?
    @Published public private(set) var completedSamples = 0
    public private(set) var settings: CaptureSettings

    private let source: ScreenCapturing
    private let recognizer: TextRecognizing
    private let index: RewindIndex
    private let clock: CaptureClock
    private let schedulesAutomatically: Bool
    private let lease: CaptureLease?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var activeSample: UUID?
    private var previousID: Int64?
    private var errors = 0
    private var lastPrune: Date?

    public init(
        source: ScreenCapturing, recognizer: TextRecognizing, index: RewindIndex,
        settings: CaptureSettings, clock: CaptureClock = SystemCaptureClock(),
        schedulesAutomatically: Bool = true, lease: CaptureLease? = nil
    ) throws {
        self.source = source
        self.recognizer = recognizer
        self.index = index
        self.settings = try settings.validated()
        self.clock = clock
        self.schedulesAutomatically = schedulesAutomatically
        self.lease = lease
        self.permission = source.authorizationStatus()
    }

    public func updateSettings(_ newValue: CaptureSettings) throws {
        let value = try newValue.validated()
        if state == .capturing || state == .requestingPermission { pause() }
        settings = value
        previousID = nil
        lastPrune = nil
        record("Settings updated. Resume explicitly to use the new capture policy.")
    }

    public func refreshPermission() {
        permission = source.authorizationStatus()
        if permission != .granted, state == .capturing {
            fail(RewindError.permissionDenied)
        }
    }

    public func start() async {
        guard state != .capturing, state != .requestingPermission else { return }
        invalidateWork()
        let token = generation
        do { try lease?.acquire() }
        catch { fail(error); return }
        state = .requestingPermission
        permission = source.authorizationStatus()
        if permission != .granted {
            let result = await source.requestAuthorization()
            guard generation == token, state == .requestingPermission else { return }
            permission = result
        }
        guard generation == token, state == .requestingPermission else { return }
        guard permission == .granted else { fail(RewindError.permissionDenied); return }
        errors = 0
        state = .capturing
        lastOutcome = "Capture is active. Pause or Stop at any time."
        record("Screen capture started by an explicit user action.")
        if schedulesAutomatically {
            task = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled, self.generation == token, self.state == .capturing {
                    let began = self.clock.now
                    await self.captureNext()
                    guard !Task.isCancelled, self.generation == token, self.state == .capturing else { break }
                    do {
                        try await self.clock.sleep(seconds: max(0.5, self.settings.interval - self.clock.now.timeIntervalSince(began)))
                    } catch is CancellationError {
                        break
                    } catch {
                        self.fail(error)
                        break
                    }
                }
            }
        }
    }

    public func pause() {
        guard state == .capturing || state == .requestingPermission else { return }
        invalidateWork()
        state = .paused
        lastOutcome = "Paused. No screen, OCR, or indexing work is scheduled."
        record("Capture paused; pending frames discarded.")
    }

    public func stop() {
        invalidateWork()
        state = .stopped
        lastOutcome = "Stopped. Press Start to opt in again."
        record("Capture stopped; pending frames discarded.")
    }

    public func captureNext() async {
        guard state == .capturing, activeSample == nil else { return }
        let token = generation
        let sample = UUID()
        activeSample = sample
        defer { if activeSample == sample { activeSample = nil } }
        do {
            guard source.authorizationStatus() == .granted else { throw RewindError.permissionDenied }
            let frame = try await source.capture(settings: settings)
            guard isCurrent(token) else { return }
            guard !settings.privacy.excludes(frame.context) else { throw RewindError.excluded }
            let timestamp = clock.now
            if let previousID, try await index.extendIfUnchanged(
                previousID: previousID, fingerprint: frame.fingerprint, at: timestamp,
                sameMean: settings.sameMean, sameMaximum: settings.sameMaximum
            ) {
                guard isCurrent(token) else { return }
                lastOutcome = "Unchanged screen — previous moment extended; OCR skipped."
                errors = 0
                completedSamples += 1
                try await pruneIfEnabled(token: token)
                return
            }
            let text = try await recognizer.recognize(frame.jpeg)
            guard isCurrent(token) else { return }
            let id = try await index.append(frame, text: text, at: timestamp)
            guard isCurrent(token) else { return }
            previousID = id
            lastMomentID = id
            errors = 0
            completedSamples += 1
            lastOutcome = "Stored moment #\(id) locally (\(text.lines) OCR lines)."
            try await pruneIfEnabled(token: token)
        } catch is CancellationError {
            if isCurrent(token) { pause() }
        } catch RewindError.excluded {
            guard isCurrent(token) else { return }
            previousID = nil
            errors = 0
            lastOutcome = "Privacy exclusion visible — this entire sample was skipped."
        } catch {
            guard isCurrent(token) else { return }
            previousID = nil
            errors += 1
            lastOutcome = error.localizedDescription
            record("Capture failure \(errors)/\(settings.maximumConsecutiveErrors): \(error.localizedDescription)")
            if error as? RewindError == .permissionDenied || errors >= settings.maximumConsecutiveErrors {
                fail(error)
            }
        }
    }

    private func pruneIfEnabled(token: Int) async throws {
        guard isCurrent(token), let days = settings.automaticImageRetentionDays,
              lastPrune.map({ clock.now.timeIntervalSince($0) >= 3600 }) ?? true else { return }
        let now = clock.now
        let result = try await index.pruneImages(before: now.addingTimeInterval(-Double(days) * 86400))
        guard isCurrent(token) else { return }
        lastPrune = now
        if result.images > 0 { record("Opt-in retention removed \(result.images) old images; all indexed text was kept.") }
    }

    private func isCurrent(_ token: Int) -> Bool {
        generation == token && state == .capturing && !Task.isCancelled
    }

    private func invalidateWork() {
        generation += 1
        task?.cancel()
        task = nil
        source.cancel()
        previousID = nil
        activeSample = nil
        lease?.release()
    }

    private func fail(_ error: Error) {
        invalidateWork()
        state = .failed(error.localizedDescription)
        permission = source.authorizationStatus()
        lastOutcome = error.localizedDescription
        record("Stopped: \(error.localizedDescription)")
    }

    private func record(_ message: String) {
        diagnostics.append(DiagnosticEvent(date: clock.now, message: message))
        if diagnostics.count > 100 { diagnostics.removeFirst(diagnostics.count - 100) }
    }
}
