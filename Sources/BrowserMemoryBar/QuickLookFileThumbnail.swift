import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(QuickLookThumbnailing)
@preconcurrency import QuickLookThumbnailing
#endif

#if canImport(AppKit) && canImport(QuickLookThumbnailing)
struct QuickLookFileThumbnail<Placeholder: View>: View {
    let fileURL: URL
    @ViewBuilder let placeholder: Placeholder
    @State private var image: NSImage?
    @State private var didLoad = isOffscreenRender

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if didLoad {
                placeholder // generation finished with no thumbnail → fallback tile
            } else {
                SkeletonBlock() // still generating
            }
        }
        .animation(.easeOut(duration: 0.25), value: image != nil)
        .task(id: fileURL) {
            guard !isOffscreenRender else { return }
            didLoad = false
            await loadThumbnail()
            didLoad = true
        }
    }

    @MainActor
    private func loadThumbnail() async {
        let requestedURL = fileURL
        image = nil
        guard !Task.isCancelled else { return }
        RememBarDiagnostics.shared.recordAsync(
            RememBarDiagnosticEvent.thumbnailQuickLookStarted,
            fields: ["path": requestedURL.path, "extension": requestedURL.pathExtension]
        )

        let request = QLThumbnailGenerator.Request(
            fileAt: requestedURL,
            size: CGSize(width: 128, height: 72),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )
        let thumbnailState = QuickLookThumbnailState()

        let response = await withTaskCancellationHandler {
            await QuickLookThumbnailLoader.generate(request: request, state: thumbnailState)
        } onCancel: {
            thumbnailState.cancel {
                QLThumbnailGenerator.shared.cancel(request)
            }
            RememBarDiagnostics.shared.recordAsync(
                RememBarDiagnosticEvent.thumbnailQuickLookCancelled,
                level: .warning,
                fields: ["path": requestedURL.path, "extension": requestedURL.pathExtension]
            )
        }

        guard !Task.isCancelled, !thumbnailState.isCancelled, let response else { return }
        var fields = ["path": requestedURL.path, "extension": requestedURL.pathExtension]
        if let errorDescription = response.errorDescription {
            fields["error"] = errorDescription
        }
        RememBarDiagnostics.shared.recordAsync(
            response.image == nil ? RememBarDiagnosticEvent.thumbnailQuickLookFailed : RememBarDiagnosticEvent.thumbnailQuickLookFinished,
            level: response.image == nil ? .warning : .info,
            fields: fields
        )
        image = response.image
    }
}

private enum QuickLookThumbnailLoader {
    static func generate(
        request: QLThumbnailGenerator.Request,
        state: QuickLookThumbnailState
    ) async -> QuickLookThumbnailResponse? {
        await withCheckedContinuation { continuation in
            guard state.install(continuation) else { return }
            state.startRequest {
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                    let response = QuickLookThumbnailResponse(
                        image: representation?.nsImage,
                        errorDescription: error.map { String(describing: $0) }
                    )
                    _ = state.complete(with: response)
                }
            }
        }
    }
}

struct QuickLookThumbnailResponse: @unchecked Sendable {
    let image: NSImage?
    let errorDescription: String?
}

final class QuickLookThumbnailState: @unchecked Sendable {
    private let lock = NSLock()
    private let startLock = NSLock()
    private var continuation: CheckedContinuation<QuickLookThumbnailResponse?, Never>?
    private var finished = false
    private var cancelled = false
    private var started = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func install(_ continuation: CheckedContinuation<QuickLookThumbnailResponse?, Never>) -> Bool {
        let shouldReject = lock.withLock {
            guard !finished, self.continuation == nil else { return true }
            self.continuation = continuation
            return false
        }

        if shouldReject {
            continuation.resume(returning: nil)
            return false
        }

        return true
    }

    @discardableResult
    func startRequest(_ start: () -> Void) -> Bool {
        startLock.lock()
        defer { startLock.unlock() }

        let shouldStart = lock.withLock {
            guard !finished, !cancelled, !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return false }
        start()
        return true
    }

    func complete(with response: QuickLookThumbnailResponse) -> Bool {
        let result = lock.withLock {
            let shouldApply = !cancelled && started
            guard !finished else {
                return (shouldApply: false, continuation: nil as CheckedContinuation<QuickLookThumbnailResponse?, Never>?)
            }

            finished = true
            let continuation = self.continuation
            self.continuation = nil
            return (shouldApply: shouldApply, continuation: continuation)
        }

        result.continuation?.resume(returning: result.shouldApply ? response : nil)
        return result.shouldApply
    }

    func cancel(_ cancelRequest: () -> Void = {}) {
        startLock.lock()
        let continuation = lock.withLock {
            cancelled = true
            guard !finished else { return nil as CheckedContinuation<QuickLookThumbnailResponse?, Never>? }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }

        cancelRequest()
        startLock.unlock()
        continuation?.resume(returning: nil)
    }
}
#else
struct QuickLookFileThumbnail<Placeholder: View>: View {
    let fileURL: URL
    @ViewBuilder let placeholder: Placeholder

    var body: some View {
        placeholder
    }
}
#endif
