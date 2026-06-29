import SwiftUI

struct MemoryThumbnailPresentation: Equatable, Sendable {
    enum RemoteKind: Equatable, Hashable, Sendable {
        case video
        case icon
    }

    enum Source: Equatable, Sendable {
        case remoteImage(URL, kind: RemoteKind)
        case filePreview(URL)
        case fallback
    }

    enum Fallback: Equatable, Sendable {
        case file(extensionLabel: String)
        case youtube(YouTubeThumbnailFallback)
        case webInitial(String)
        case systemSettings
    }

    let source: Source
    let fallback: Fallback

    init(source: Source, fallback: Fallback) {
        self.source = source
        self.fallback = fallback
    }

    init(result: MemoryResult) {
        let fallback = Self.fallback(for: result)
        switch result.thumbnail {
        case .remoteImage(let thumbnailURL):
            self.init(
                source: .remoteImage(thumbnailURL, kind: thumbnailURL.memoryThumbnailRemoteKind),
                fallback: fallback
            )
        case .filePreview(let fileURL):
            self.init(source: .filePreview(fileURL), fallback: fallback)
        case nil:
            self.init(source: .fallback, fallback: fallback)
        }
    }

    private static func fallback(for result: MemoryResult) -> Fallback {
        switch result.kind {
        case .file:
            return .file(extensionLabel: fileExtensionLabel(result.url.pathExtension))
        case .systemSettings:
            return .systemSettings
        case .externalApp:
            return .webInitial(result.title)
        case .youtubeSearch(let query):
            return .youtube(.search(query: query))
        case .youtubeChannel(let label):
            return .youtube(.channel(label: label))
        case .youtubePlaylist:
            return .youtube(.playlist)
        case .youtubeHome:
            return .youtube(.home)
        case .youtubeVideo, .youtubeShort:
            return .youtube(.video)
        case .web:
            return .webInitial(result.url.memoryThumbnailInitial)
        }
    }

    private static func fileExtensionLabel(_ fileExtension: String) -> String {
        let value = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "FILE" : value.uppercased()
    }
}

enum YouTubeThumbnailFallback: Equatable, Sendable {
    case search(query: String)
    case channel(label: String)
    case playlist
    case home
    case video

    var label: String {
        switch self {
        case .search:
            return "Search"
        case .channel:
            return "Channel"
        case .playlist:
            return "Playlist"
        case .home:
            return "YouTube"
        case .video:
            return "Video"
        }
    }

    var detail: String? {
        switch self {
        case .search(let query):
            return query
        case .channel(let label):
            return label
        case .playlist, .home, .video:
            return nil
        }
    }

    var iconName: String {
        switch self {
        case .search:
            return "magnifyingglass"
        case .playlist:
            return "list.bullet"
        case .channel:
            return "person.fill"
        case .home, .video:
            return "play.fill"
        }
    }
}

struct ResultThumbnail: View {
    let result: MemoryResult

    private var presentation: MemoryThumbnailPresentation {
        MemoryThumbnailPresentation(result: result)
    }

    var body: some View {
        Group {
            switch presentation.source {
            case .remoteImage(let thumbnailURL, let kind):
                RemoteMemoryThumbnail(
                    context: RemoteThumbnailDiagnosticContext(url: thumbnailURL, kind: kind, sourceURL: result.url)
                ) { image in
                    switch kind {
                    case .video:
                        image.resizable().scaledToFill()
                    case .icon:
                        iconImage(image)
                    }
                } placeholder: {
                    fallbackView
                }
            case .filePreview(let fileURL):
                QuickLookFileThumbnail(fileURL: fileURL) {
                    fallbackView
                }
            case .fallback:
                fallbackView
            }
        }
        .frame(width: 64, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.micro, style: .continuous))
        .accessibilityHidden(true)
    }

    private func iconImage(_ image: Image) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.micro, style: .continuous)
                .fill(Tokens.field)
            image
                .resizable()
                .scaledToFit()
                .padding(8)
        }
    }

    private var fallbackView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.micro, style: .continuous)
                .fill(Tokens.field)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.micro, style: .continuous)
                        .stroke(Tokens.line.opacity(0.9), lineWidth: 1)
                )

            switch presentation.fallback {
            case .file(let extensionLabel):
                FileTile(extensionLabel: extensionLabel)
            case .youtube(let fallback):
                YouTubeTile(fallback: fallback)
            case .webInitial(let initial):
                Text(initial)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            case .systemSettings:
                SystemSettingsTile()
            }
        }
    }
}

private struct FileTile: View {
    let extensionLabel: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tokens.text)

            Text(extensionLabel)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Tokens.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 7)
    }
}

private struct YouTubeTile: View {
    let fallback: YouTubeThumbnailFallback

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(red: 1, green: 0, blue: 0.08))
                    .frame(width: 18, height: 12)

                Image(systemName: iconName)
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(fallback.label)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)

                if let detail = fallback.detail {
                    Text(detail)
                        .font(.system(size: 6, weight: .medium))
                        .foregroundStyle(Tokens.quiet)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 7)
    }

    private var iconName: String {
        fallback.iconName
    }
}

private struct SystemSettingsTile: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tokens.text)

            Text("Access")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Tokens.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 7)
    }
}

private extension URL {
    var memoryThumbnailRemoteKind: MemoryThumbnailPresentation.RemoteKind {
        normalizedHost == "img.youtube.com" || normalizedHost == "i.ytimg.com" ? .video : .icon
    }

    var memoryThumbnailInitial: String {
        guard let first = normalizedHost.first(where: { $0.isLetter || $0.isNumber }) else {
            return "#"
        }
        return String(first).uppercased()
    }
}
