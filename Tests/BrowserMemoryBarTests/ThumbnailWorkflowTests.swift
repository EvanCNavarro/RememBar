@testable import BrowserMemoryBar
import Foundation
import Testing

// Thumbnail fixture setup (building several MemoryResult / diagnostic-context inputs and asserting
// each phase) is legitimately verbose; splitting it would obscure the workflow under test.
// swiftlint:disable function_body_length

@Suite("Thumbnail presentation")
struct ThumbnailPresentationTests {
    @Test("thumbnail presentation distinguishes remote video icon file and fallback tiles")
    func thumbnailPresentationDistinguishesRemoteVideoIconFileAndFallbackTiles() {
        let videoThumbnailURL = URL(string: "https://img.youtube.com/vi/abc123/hqdefault.jpg")!
        let video = MemoryResult(
            id: "video",
            title: "Video",
            detail: "Zen · Jun 27 · youtube.com",
            refinedDetail: nil,
            url: URL(string: "https://www.youtube.com/watch?v=abc123")!,
            thumbnailURL: videoThumbnailURL,
            browser: .zen,
            rank: 80
        )
        let faviconURL = URL(string: "https://www.google.com/s2/favicons?domain=dash.cloudflare.com&sz=128")!
        let web = MemoryResult(
            id: "web",
            title: "Dashboard",
            detail: "Chrome · Jun 27 · dash.cloudflare.com",
            refinedDetail: nil,
            url: URL(string: "https://dash.cloudflare.com/")!,
            thumbnailURL: faviconURL,
            browser: .chrome,
            rank: 70
        )
        let fileURL = URL(fileURLWithPath: "/Users/example/Documents/alpha.psd")
        let file = MemoryResult(
            fileURL: fileURL,
            displayPath: "Documents/alpha.psd",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            rank: 220
        )
        let youtubeSearch = MemoryResult(
            id: "youtube-search",
            title: "cold ones",
            detail: "Zen · Jun 27 · youtube.com",
            refinedDetail: nil,
            url: URL(string: "https://www.youtube.com/results?search_query=cold+ones")!,
            thumbnailURL: nil,
            browser: .zen,
            rank: 60
        )

        #expect(MemoryThumbnailPresentation(result: video) == MemoryThumbnailPresentation(
            source: .remoteImage(videoThumbnailURL, kind: .video),
            fallback: .youtube(.video)
        ))
        #expect(MemoryThumbnailPresentation(result: web) == MemoryThumbnailPresentation(
            source: .remoteImage(faviconURL, kind: .icon),
            fallback: .webInitial("D")
        ))
        #expect(MemoryThumbnailPresentation(result: file) == MemoryThumbnailPresentation(
            source: .filePreview(fileURL),
            fallback: .file(extensionLabel: "PSD")
        ))
        #expect(MemoryThumbnailPresentation(result: youtubeSearch) == MemoryThumbnailPresentation(
            source: .fallback,
            fallback: .youtube(.search(query: "cold ones"))
        ))
    }

    @Test("thumbnail presentation covers youtube container fallback variants")
    func thumbnailPresentationCoversYouTubeContainerFallbackVariants() {
        let cases: [(URL, MemoryThumbnailPresentation.Fallback)] = [
            (
                URL(string: "https://www.youtube.com/@coldones/videos")!,
                .youtube(.channel(label: "@coldones"))
            ),
            (
                URL(string: "https://www.youtube.com/playlist?list=PL123")!,
                .youtube(.playlist)
            ),
            (
                URL(string: "https://www.youtube.com/")!,
                .youtube(.home)
            )
        ]

        for (url, fallback) in cases {
            let result = MemoryResult(
                id: url.absoluteString,
                title: "Container",
                detail: "Zen · Jun 27 · youtube.com",
                refinedDetail: nil,
                url: url,
                thumbnailURL: nil,
                browser: .zen,
                rank: 50
            )

            #expect(MemoryThumbnailPresentation(result: result) == MemoryThumbnailPresentation(
                source: .fallback,
                fallback: fallback
            ))
        }
    }
}

@Suite("Remote thumbnail diagnostics")
struct RemoteThumbnailDiagnosticsTests {
    @Test("remote thumbnail diagnostic event names are cataloged")
    func remoteThumbnailDiagnosticEventNamesAreCataloged() {
        #expect(RememBarDiagnosticEvent.thumbnailRemoteStarted == "thumbnail.remote.started")
        #expect(RememBarDiagnosticEvent.thumbnailRemoteFinished == "thumbnail.remote.finished")
        #expect(RememBarDiagnosticEvent.thumbnailRemoteFailed == "thumbnail.remote.failed")
        #expect(RememBarDiagnosticEvent.thumbnailRemoteCancelled == "thumbnail.remote.cancelled")
    }

    @Test("remote thumbnail diagnostic context exposes stable URL fields")
    func remoteThumbnailDiagnosticContextExposesStableURLFields() {
        let url = URL(string: "https://img.youtube.com/vi/abc123/hqdefault.jpg")!
        let sourceURL = URL(string: "https://www.youtube.com/watch?v=abc123")!
        let context = RemoteThumbnailDiagnosticContext(url: url, kind: .video, sourceURL: sourceURL)

        #expect(context.fields["url"] == url.absoluteString)
        #expect(context.fields["sourceURL"] == sourceURL.absoluteString)
        #expect(context.fields["host"] == "youtube.com")
        #expect(context.fields["thumbnailHost"] == "img.youtube.com")
        #expect(context.fields["kind"] == "video")
    }

    @Test("remote thumbnail diagnostic context keeps favicon source host visible")
    func remoteThumbnailDiagnosticContextKeepsFaviconSourceHostVisible() {
        let url = URL(string: "https://www.google.com/s2/favicons?domain=dash.cloudflare.com&sz=128")!
        let sourceURL = URL(string: "https://dash.cloudflare.com/audit-logs")!
        let context = RemoteThumbnailDiagnosticContext(url: url, kind: .icon, sourceURL: sourceURL)

        #expect(context.fields["url"] == url.absoluteString)
        #expect(context.fields["sourceURL"] == sourceURL.absoluteString)
        #expect(context.fields["host"] == "dash.cloudflare.com")
        #expect(context.fields["thumbnailHost"] == "google.com")
        #expect(context.fields["kind"] == "icon")
    }

    @MainActor
    @Test("remote thumbnail diagnostic recorder records each phase once per URL")
    func remoteThumbnailDiagnosticRecorderRecordsEachPhaseOncePerURL() async throws {
        let root = try temporaryDirectory()
        let diagnostics = RememBarDiagnostics(
            directory: root.appendingPathComponent("Diagnostics", isDirectory: true),
            sessionID: "remote-thumbnail-test",
            now: IncrementingClock(start: Date(timeIntervalSince1970: 1_800_001_000)).nextDate,
            processID: 4321,
            maxLogBytes: 200_000
        )
        _ = diagnostics.startSession()
        let recorder = RemoteThumbnailDiagnosticRecorder(diagnostics: diagnostics)
        let first = RemoteThumbnailDiagnosticContext(
            url: URL(string: "https://img.youtube.com/vi/abc123/hqdefault.jpg")!,
            kind: .video
        )
        let second = RemoteThumbnailDiagnosticContext(
            url: URL(string: "https://www.google.com/s2/favicons?domain=example.com&sz=128")!,
            kind: .icon
        )

        recorder.recordStarted(first)
        recorder.recordStarted(first)
        recorder.recordFinished(first)
        recorder.recordFinished(first)
        recorder.recordFailed(first, errorDescription: "late duplicate")
        recorder.recordCancelled(first)
        recorder.recordStarted(second)
        recorder.recordFailed(second, errorDescription: "network offline")
        recorder.recordCancelled(second)
        let third = RemoteThumbnailDiagnosticContext(
            url: URL(string: "https://www.google.com/s2/favicons?domain=cancelled.example&sz=128")!,
            kind: .icon,
            sourceURL: URL(string: "https://cancelled.example/page")!
        )
        recorder.recordStarted(third)
        recorder.recordCancelled(third)
        recorder.recordFailed(third, errorDescription: "late duplicate")
        let fourth = RemoteThumbnailDiagnosticContext(
            url: URL(string: "https://www.google.com/s2/favicons?domain=instant.example&sz=128")!,
            kind: .icon,
            sourceURL: URL(string: "https://instant.example/page")!
        )
        recorder.recordCancelled(fourth)
        recorder.recordStarted(fourth)

        let events = await eventuallyDiagnosticEvents(
            at: diagnostics.logURL,
            prefix: "thumbnail.remote.",
            count: 7
        )
        try? await Task.sleep(for: .milliseconds(50))
        let finalEvents = try diagnosticEvents(at: diagnostics.logURL)
            .filter { $0.name.hasPrefix("thumbnail.remote.") }
        try #require(finalEvents.count == 7)
        try #require(events.count == 7)
        #expect(finalEvents.map(\.name) == [
            RememBarDiagnosticEvent.thumbnailRemoteStarted,
            RememBarDiagnosticEvent.thumbnailRemoteFinished,
            RememBarDiagnosticEvent.thumbnailRemoteStarted,
            RememBarDiagnosticEvent.thumbnailRemoteFailed,
            RememBarDiagnosticEvent.thumbnailRemoteStarted,
            RememBarDiagnosticEvent.thumbnailRemoteCancelled,
            RememBarDiagnosticEvent.thumbnailRemoteCancelled
        ])
        #expect(finalEvents[0].fields["url"] == first.url.absoluteString)
        #expect(finalEvents[0].fields["kind"] == "video")
        #expect(finalEvents[2].fields["url"] == second.url.absoluteString)
        #expect(finalEvents[2].fields["kind"] == "icon")
        #expect(finalEvents[3].fields["error"] == "network offline")
        #expect(finalEvents[4].fields["url"] == third.url.absoluteString)
        #expect(finalEvents[4].fields["host"] == "cancelled.example")
        #expect(finalEvents[5].fields["reason"] == "view disappeared before remote image resolved")
        #expect(finalEvents[6].fields["host"] == "instant.example")
    }
}

// swiftlint:enable function_body_length

#if canImport(AppKit) && canImport(QuickLookThumbnailing)
@Suite("Thumbnail workflows")
struct ThumbnailWorkflowTests {
    @Test("Quick Look thumbnail state completes once and resumes waiting work")
    func quickLookThumbnailStateCompletesOnceAndResumesWaitingWork() async throws {
        let state = QuickLookThumbnailState()
        let installed = OneShotSignal()
        let waiting = Task {
            let response: QuickLookThumbnailResponse? = await withCheckedContinuation { continuation in
                #expect(state.install(continuation))
                installed.signal()
            }
            return response?.errorDescription
        }

        try await installed.wait(timeout: .milliseconds(500))

        #expect(state.startRequest {})
        #expect(state.complete(with: QuickLookThumbnailResponse(image: nil, errorDescription: "done")))
        #expect(try await value(of: waiting, timeout: .milliseconds(500)) == "done")
        #expect(!state.complete(with: QuickLookThumbnailResponse(image: nil, errorDescription: "duplicate")))
    }

    @Test("Quick Look thumbnail state cancellation wins before completion")
    func quickLookThumbnailStateCancellationWinsBeforeCompletion() async throws {
        let state = QuickLookThumbnailState()
        let installed = OneShotSignal()
        let waiting = Task {
            let response: QuickLookThumbnailResponse? = await withCheckedContinuation { continuation in
                #expect(state.install(continuation))
                installed.signal()
            }
            return response == nil && state.isCancelled
        }

        try await installed.wait(timeout: .milliseconds(500))

        state.cancel()
        #expect(try await value(of: waiting, timeout: .milliseconds(500)))
        #expect(state.isCancelled)
        #expect(!state.complete(with: QuickLookThumbnailResponse(image: nil, errorDescription: "late")))
    }

    @Test("Quick Look thumbnail state rejects duplicate installs")
    func quickLookThumbnailStateRejectsDuplicateInstalls() async throws {
        let state = QuickLookThumbnailState()
        let firstInstalled = OneShotSignal()
        let first = Task {
            await withCheckedContinuation { continuation in
                #expect(state.install(continuation))
                firstInstalled.signal()
            } as QuickLookThumbnailResponse?
        }

        try await firstInstalled.wait(timeout: .milliseconds(500))

        let second = Task {
            await withCheckedContinuation { continuation in
                #expect(!state.install(continuation))
            } as QuickLookThumbnailResponse?
        }

        #expect(try await value(of: second, timeout: .milliseconds(500)) == nil)
        #expect(state.startRequest {})
        #expect(state.complete(with: QuickLookThumbnailResponse(image: nil, errorDescription: "first")))
        #expect(try await value(of: first, timeout: .milliseconds(500))?.errorDescription == "first")
    }

    @Test("Quick Look thumbnail state prevents request start after cancellation")
    func quickLookThumbnailStatePreventsRequestStartAfterCancellation() async throws {
        let state = QuickLookThumbnailState()
        let installed = OneShotSignal()
        let waiting = Task {
            await withCheckedContinuation { continuation in
                #expect(state.install(continuation))
                installed.signal()
            } as QuickLookThumbnailResponse?
        }

        try await installed.wait(timeout: .milliseconds(500))
        state.cancel()

        var didStart = false
        #expect(!state.startRequest {
            didStart = true
        })
        #expect(!didStart)
        #expect(try await value(of: waiting, timeout: .milliseconds(500)) == nil)
        #expect(!state.complete(with: QuickLookThumbnailResponse(image: nil, errorDescription: "late")))
    }
}

private enum ThumbnailTestTimeout: Error {
    case timedOut
}

private final class OneShotSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var didSignal = false

    func wait(timeout: Duration) async throws {
        let waiter = Task {
            await withCheckedContinuation { continuation in
                let shouldResumeImmediately = lock.withLock {
                    guard !didSignal else { return true }
                    self.continuation = continuation
                    return false
                }
                if shouldResumeImmediately {
                    continuation.resume()
                }
            }
        }

        _ = try await value(of: waiter, timeout: timeout)
    }

    func signal() {
        let continuation = lock.withLock {
            didSignal = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private func value<T>(of task: Task<T, Never>, timeout: Duration) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            await task.value
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ThumbnailTestTimeout.timedOut
        }

        let value = try #require(await group.next())
        group.cancelAll()
        return value
    }
}
#endif
