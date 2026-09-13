import Foundation
import RAPPRewindCore
import XCTest

@MainActor
final class CaptureTests: XCTestCase {
    private func coordinator(
        _ directory: FixtureDirectory, source: FakeScreen, recognizer: FakeRecognizer,
        clock: FakeClock, settings: CaptureSettings = CaptureSettings()
    ) throws -> (CaptureCoordinator, RewindIndex) {
        let index = try RewindIndex(paths: directory.paths)
        let controller = try CaptureCoordinator(
            source: source, recognizer: recognizer, index: index,
            settings: settings, clock: clock, schedulesAutomatically: false
        )
        return (controller, index)
    }

    func testLaunchIsIdleAndDeniedPermissionNeverCaptures() async throws {
        let directory = try fixture()
        let source = FakeScreen()
        source.permission = .notDetermined
        source.requestedPermission = .denied
        let recognizer = FakeRecognizer()
        let (controller, index) = try coordinator(directory, source: source, recognizer: recognizer, clock: FakeClock())
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertEqual(source.requestCount, 0)
        await controller.captureNext()
        XCTAssertEqual(source.captures, 0)
        await controller.start()
        XCTAssertEqual(source.requestCount, 1)
        XCTAssertEqual(source.captures, 0)
        if case .failed = controller.state {} else { XCTFail("denial must leave a failed/stopped state") }
        let calls = await recognizer.calls
        let stats = try await index.statistics()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(stats.frames, 0)
    }

    func testStartCaptureDedupPauseResumeAndStop() async throws {
        let directory = try fixture()
        let source = FakeScreen()
        let frame = try FixtureDirectory.frame()
        source.responses = [.success(frame), .success(frame), .success(frame)]
        let recognizer = FakeRecognizer()
        let clock = FakeClock()
        let (controller, index) = try coordinator(directory, source: source, recognizer: recognizer, clock: clock)
        await controller.start()
        XCTAssertEqual(controller.state, .capturing)
        XCTAssertEqual(source.requestCount, 0)
        await controller.captureNext()
        clock.advance(4)
        await controller.captureNext()
        let dedupCalls = await recognizer.calls
        XCTAssertEqual(dedupCalls, 1)
        let firstStats = try await index.statistics()
        XCTAssertEqual(firstStats.frames, 1)
        XCTAssertEqual(firstStats.sameShots, 1)
        controller.pause()
        XCTAssertEqual(controller.state, .paused)
        await controller.captureNext()
        XCTAssertEqual(source.captures, 2)
        clock.advance(3600)
        await controller.start()
        await controller.captureNext()
        let moments = try await index.timeline()
        XCTAssertEqual(moments.count, 2)
        XCTAssertEqual(moments.last?.until.timeIntervalSince(moments.last!.timestamp), 4)
        controller.stop()
        XCTAssertEqual(controller.state, .stopped)
        await controller.captureNext()
        XCTAssertEqual(source.captures, 3)
        XCTAssertGreaterThan(source.cancels, 0)
    }

    func testPauseDiscardsLateScreenCaptureCompletion() async throws {
        let directory = try fixture()
        let source = FakeScreen()
        source.holdCapture = true
        let began = expectation(description: "fake capture suspended")
        source.captureBegan = { began.fulfill() }
        let recognizer = FakeRecognizer()
        let (controller, index) = try coordinator(directory, source: source, recognizer: recognizer, clock: FakeClock())
        await controller.start()
        let pending = Task { await controller.captureNext() }
        await fulfillment(of: [began], timeout: 3)
        controller.pause()
        source.finishCapture(try FixtureDirectory.frame())
        await pending.value
        let stats = try await index.statistics()
        let calls = await recognizer.calls
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(stats.frames, 0)
        XCTAssertEqual(calls, 0)
    }

    func testStopDuringPermissionRequestCannotStartAfterLateGrant() async throws {
        let directory = try fixture()
        let source = FakeScreen()
        source.permission = .notDetermined
        source.holdPermission = true
        let began = expectation(description: "fake permission request suspended")
        source.permissionBegan = { began.fulfill() }
        let (controller, _) = try coordinator(directory, source: source, recognizer: FakeRecognizer(), clock: FakeClock())
        let pending = Task { await controller.start() }
        await fulfillment(of: [began], timeout: 3)
        XCTAssertEqual(controller.state, .requestingPermission)
        controller.stop()
        source.finishPermission(.granted)
        await pending.value
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertEqual(source.captures, 0)
    }

    func testStopDiscardsLateOCRCompletion() async throws {
        let directory = try fixture()
        let source = FakeScreen()
        source.responses = [.success(try FixtureDirectory.frame())]
        let began = expectation(description: "fake OCR suspended")
        let recognizer = SuspendedRecognizer { began.fulfill() }
        let index = try RewindIndex(paths: directory.paths)
        let controller = try CaptureCoordinator(
            source: source, recognizer: recognizer, index: index, settings: CaptureSettings(),
            clock: FakeClock(), schedulesAutomatically: false
        )
        await controller.start()
        let pending = Task { await controller.captureNext() }
        await fulfillment(of: [began], timeout: 3)
        controller.stop()
        await recognizer.complete()
        await pending.value
        let stats = try await index.statistics()
        XCTAssertEqual(stats.frames, 0)
        XCTAssertEqual(stats.shots, 0)
        XCTAssertEqual(controller.state, .stopped)
    }

    func testLateCancelledCaptureCannotClobberResumedSession() async throws {
        let directory = try fixture()
        let source = FakeScreen()
        source.holdCapture = true
        let began = expectation(description: "old fake capture suspended")
        source.captureBegan = { began.fulfill() }
        let clock = FakeClock()
        let (controller, index) = try coordinator(directory, source: source, recognizer: FakeRecognizer(), clock: clock)
        await controller.start()
        let pending = Task { await controller.captureNext() }
        await fulfillment(of: [began], timeout: 3)
        controller.pause()
        source.holdCapture = false
        source.responses = [.success(try FixtureDirectory.frame(byte: 90))]
        clock.advance(4)
        await controller.start()
        await controller.captureNext()
        source.finishCapture(try FixtureDirectory.frame())
        await pending.value
        let stats = try await index.statistics()
        XCTAssertEqual(stats.frames, 1)
        XCTAssertEqual(controller.completedSamples, 1)
        XCTAssertEqual(controller.state, .capturing)
    }

    func testExcludedFramesNeverReachOCRAndDoNotExtendAcrossPrivateGaps() async throws {
        let directory = try fixture()
        let source = FakeScreen()
        let ordinary = try FixtureDirectory.frame()
        let privateFrame = try FixtureDirectory.frame(context: ScreenContext(app: "Private", bundle: "fixture.private", title: "Sensitive"))
        source.responses = [.success(ordinary), .success(privateFrame), .success(ordinary)]
        let recognizer = FakeRecognizer()
        let clock = FakeClock()
        var settings = CaptureSettings()
        settings.privacy.excludedBundleIDs = ["fixture.private"]
        let (controller, index) = try coordinator(directory, source: source, recognizer: recognizer, clock: clock, settings: settings)
        await controller.start()
        await controller.captureNext()
        clock.advance(4)
        await controller.captureNext()
        XCTAssertTrue(controller.lastOutcome.contains("exclusion"))
        XCTAssertEqual(controller.state, .capturing)
        clock.advance(4)
        await controller.captureNext()
        let calls = await recognizer.calls
        let moments = try await index.timeline()
        let stats = try await index.statistics()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(moments.count, 2)
        XCTAssertEqual(moments.last?.until, moments.last?.timestamp)
        XCTAssertEqual(stats.shots, 2)
        XCTAssertFalse(moments.contains { $0.bundle == "fixture.private" })
    }

    func testRepeatedCaptureErrorsStopLoudlyAndSuccessResetsFailures() async throws {
        let directory = try fixture()
        let source = FakeScreen()
        source.responses = [
            .failure(RewindError.imageEncoding), .success(try FixtureDirectory.frame()),
            .failure(RewindError.imageEncoding), .failure(RewindError.imageEncoding)
        ]
        var settings = CaptureSettings()
        settings.maximumConsecutiveErrors = 2
        let (controller, index) = try coordinator(
            directory, source: source, recognizer: FakeRecognizer(), clock: FakeClock(), settings: settings
        )
        await controller.start()
        await controller.captureNext()
        XCTAssertEqual(controller.state, .capturing)
        await controller.captureNext()
        await controller.captureNext()
        XCTAssertEqual(controller.state, .capturing)
        await controller.captureNext()
        if case .failed(let detail) = controller.state { XCTAssertFalse(detail.isEmpty) }
        else { XCTFail("consecutive failure threshold was ignored") }
        XCTAssertTrue(controller.diagnostics.contains { $0.message.contains("2/2") })
        let stats = try await index.statistics()
        XCTAssertEqual(stats.frames, 1)
        await controller.captureNext()
        XCTAssertEqual(source.captures, 4)
    }

    func testOCRErrorNeverCreatesEmptySuccessShapedRecord() async throws {
        let directory = try fixture()
        let source = FakeScreen()
        source.responses = [.success(try FixtureDirectory.frame())]
        let recognizer = FakeRecognizer()
        await recognizer.setFailure(.captureUnavailable("fixture OCR failed"))
        var settings = CaptureSettings()
        settings.maximumConsecutiveErrors = 1
        let (controller, index) = try coordinator(directory, source: source, recognizer: recognizer, clock: FakeClock(), settings: settings)
        await controller.start()
        await controller.captureNext()
        let stats = try await index.statistics()
        XCTAssertEqual(stats.frames, 0)
        XCTAssertEqual(stats.shots, 0)
        XCTAssertTrue(controller.lastOutcome.contains("fixture OCR failed"))
        if case .failed = controller.state {} else { XCTFail("OCR failure was hidden") }
    }

    func testPermissionRevocationImmediatelyStopsBeforeCapture() async throws {
        let directory = try fixture()
        let source = FakeScreen()
        let (controller, _) = try coordinator(directory, source: source, recognizer: FakeRecognizer(), clock: FakeClock())
        await controller.start()
        source.permission = .denied
        await controller.captureNext()
        if case .failed = controller.state {} else { XCTFail("permission revocation was ignored") }
        XCTAssertEqual(source.captures, 0)
        XCTAssertEqual(source.requestCount, 0)
    }

    func testNewSettingsPauseCaptureAndRejectInvalidSettingsWithoutChangingThem() async throws {
        let directory = try fixture()
        let source = FakeScreen()
        let (controller, _) = try coordinator(directory, source: source, recognizer: FakeRecognizer(), clock: FakeClock())
        await controller.start()
        var invalid = CaptureSettings()
        invalid.interval = 0
        XCTAssertThrowsError(try controller.updateSettings(invalid))
        XCTAssertEqual(controller.state, .capturing)
        var updated = CaptureSettings()
        updated.privacy.excludedTitleFragments = ["private"]
        try controller.updateSettings(updated)
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(controller.settings.privacy, updated.privacy)
        XCTAssertEqual(source.captures, 0)
    }

    func testAutomaticImageRetentionIsOptInAndKeepsText() async throws {
        let directory = try fixture()
        let source = FakeScreen()
        let frame = try FixtureDirectory.frame()
        source.responses = [.success(frame), .success(frame)]
        let clock = FakeClock()
        let (controller, index) = try coordinator(directory, source: source, recognizer: FakeRecognizer(), clock: clock)
        let old = try await index.append(
            frame, text: RecognizedText(text: "Historical fixture", lines: 1, confidence: 1),
            at: clock.now.addingTimeInterval(-10 * 86400)
        )
        let url = try await index.imageURL(id: old)
        await controller.start()
        await controller.captureNext()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        var optedIn = CaptureSettings()
        optedIn.automaticImageRetentionDays = 1
        try controller.updateSettings(optedIn)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        clock.advance(4)
        await controller.start()
        await controller.captureNext()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let hits = try await index.search("Historical")
        XCTAssertEqual(hits.map(\.id), [old])
        XCTAssertNil(hits.first?.relativePath)
    }

    func testAutomaticSchedulerUsesInjectedClockAndStopsAfterPause() async throws {
        let directory = try fixture()
        let source = FakeScreen()
        source.responses = [.success(try FixtureDirectory.frame())]
        let clock = StepClock()
        let sleeping = expectation(description: "scheduler reached injected sleep")
        let resumed = expectation(description: "cancelled sleep returned")
        clock.sleeping = { sleeping.fulfill() }
        clock.resumed = { resumed.fulfill() }
        let index = try RewindIndex(paths: directory.paths)
        let controller = try CaptureCoordinator(
            source: source, recognizer: FakeRecognizer(), index: index,
            settings: CaptureSettings(), clock: clock
        )
        XCTAssertEqual(source.captures, 0)
        await controller.start()
        await fulfillment(of: [sleeping], timeout: 3)
        XCTAssertEqual(source.captures, 1)
        XCTAssertEqual(clock.requestedInterval, 4)
        controller.pause()
        clock.finishSleep()
        await fulfillment(of: [resumed], timeout: 3)
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(source.captures, 1)
        let statistics = try await index.statistics()
        XCTAssertEqual(statistics.frames, 1)
    }
}
