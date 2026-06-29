import SwiftUI

struct RemoteThumbnailDiagnosticContext: Equatable, Hashable, Sendable {
    let url: URL
    let kind: MemoryThumbnailPresentation.RemoteKind
    let sourceURL: URL?

    init(url: URL, kind: MemoryThumbnailPresentation.RemoteKind, sourceURL: URL? = nil) {
        self.url = url
        self.kind = kind
        self.sourceURL = sourceURL
    }

    var fields: [String: String] {
        var fields = [
            "url": url.absoluteString,
            "host": sourceURL?.normalizedHost ?? url.normalizedHost,
            "thumbnailHost": url.normalizedHost,
            "kind": kind.diagnosticValue
        ]
        if let sourceURL {
            fields["sourceURL"] = sourceURL.absoluteString
        }
        return fields
    }
}

@MainActor
final class RemoteThumbnailDiagnosticRecorder: ObservableObject {
    private enum Phase: Hashable {
        case started
        case finished
        case failed
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .started:
                return false
            case .finished, .failed, .cancelled:
                return true
            }
        }
    }

    private let diagnostics: RememBarDiagnostics
    private var currentContext: RemoteThumbnailDiagnosticContext?
    private var recordedPhases = Set<Phase>()

    init(diagnostics: RememBarDiagnostics = .shared) {
        self.diagnostics = diagnostics
    }

    func recordStarted(_ context: RemoteThumbnailDiagnosticContext) {
        record(.started, event: RememBarDiagnosticEvent.thumbnailRemoteStarted, context: context)
    }

    func recordFinished(_ context: RemoteThumbnailDiagnosticContext) {
        record(.finished, event: RememBarDiagnosticEvent.thumbnailRemoteFinished, context: context)
    }

    func recordFailed(_ context: RemoteThumbnailDiagnosticContext, errorDescription: String) {
        var fields = context.fields
        fields["error"] = errorDescription
        record(.failed, event: RememBarDiagnosticEvent.thumbnailRemoteFailed, context: context, fields: fields)
    }

    func recordCancelled(_ context: RemoteThumbnailDiagnosticContext) {
        var fields = context.fields
        fields["reason"] = "view disappeared before remote image resolved"
        record(.cancelled, event: RememBarDiagnosticEvent.thumbnailRemoteCancelled, context: context, fields: fields)
    }

    private func record(
        _ phase: Phase,
        event: String,
        context: RemoteThumbnailDiagnosticContext,
        fields: [String: String]? = nil
    ) {
        prepare(for: context)
        guard shouldRecord(phase) else { return }
        recordedPhases.insert(phase)
        diagnostics.recordAsync(
            event,
            level: phase == .failed ? .warning : .info,
            fields: fields ?? context.fields
        )
    }

    private func prepare(for context: RemoteThumbnailDiagnosticContext) {
        guard currentContext != context else { return }
        if let currentContext, recordedPhases.contains(.started), !hasRecordedTerminal {
            var fields = currentContext.fields
            fields["reason"] = "context changed before remote image resolved"
            diagnostics.recordAsync(
                RememBarDiagnosticEvent.thumbnailRemoteCancelled,
                level: .info,
                fields: fields
            )
        }
        currentContext = context
        recordedPhases = []
    }

    private func shouldRecord(_ phase: Phase) -> Bool {
        guard !recordedPhases.contains(phase) else { return false }
        guard !(phase == .started && hasRecordedTerminal) else { return false }
        guard !(phase.isTerminal && hasRecordedTerminal) else { return false }
        return true
    }

    private var hasRecordedTerminal: Bool {
        recordedPhases.contains { $0.isTerminal }
    }
}

struct RemoteMemoryThumbnail<Content: View, Placeholder: View>: View {
    let context: RemoteThumbnailDiagnosticContext
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: Placeholder
    @StateObject private var recorder: RemoteThumbnailDiagnosticRecorder

    init(
        context: RemoteThumbnailDiagnosticContext,
        diagnostics: RememBarDiagnostics = .shared,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.context = context
        self.content = content
        self.placeholder = placeholder()
        _recorder = StateObject(wrappedValue: RemoteThumbnailDiagnosticRecorder(diagnostics: diagnostics))
    }

    var body: some View {
        // The transaction animates the empty -> success swap, so the image softly fades in over the
        // shimmer skeleton instead of popping.
        AsyncImage(url: context.url, transaction: Transaction(animation: .easeOut(duration: 0.3))) { phase in
            switch phase {
            case .empty:
                SkeletonBlock()
            case .success(let image):
                content(image)
                    .transition(.opacity)
                    .onAppear {
                        recorder.recordFinished(context)
                    }
            case .failure(let error):
                placeholder
                    .onAppear {
                        recorder.recordFailed(context, errorDescription: String(describing: error))
                    }
            @unknown default:
                placeholder
            }
        }
        .task(id: context) {
            recorder.recordStarted(context)
        }
        .onDisappear {
            recorder.recordCancelled(context)
        }
    }
}

private extension MemoryThumbnailPresentation.RemoteKind {
    var diagnosticValue: String {
        switch self {
        case .video:
            return "video"
        case .icon:
            return "icon"
        }
    }
}
