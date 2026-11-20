import SwiftUI

#if canImport(UIKit)
import ImageIO
import UIKit

/// Process-wide cache for channel avatars: decoded images in memory (so a row that is
/// recreated shows its picture immediately instead of fading in again) and a larger
/// on-disk URL cache (so revisits and relaunches do not hit the network).
final class AvatarImageCache: @unchecked Sendable {
    static let shared = AvatarImageCache()

    private let memory = NSCache<NSURL, UIImage>()
    private let session: URLSession
    private let lock = NSLock()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        memory.countLimit = 600
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 100 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
    }

    /// Decodes a small, ready-to-draw bitmap off the main thread so scrolling never decodes
    /// a full-size avatar.
    private static func downsampled(_ data: Data) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    /// The decoded image if it is already in memory.
    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    /// The image for `url`, from memory, the disk cache or the network. Concurrent requests for
    /// the same URL share one download.
    func image(for url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        let task: Task<UIImage?, Never> = lock.withLock {
            if let existing = inflight[url] { return existing }
            let session = self.session
            let created = Task<UIImage?, Never> {
                guard let (data, _) = try? await session.data(from: url) else { return nil }
                return Self.downsampled(data)
            }
            inflight[url] = created
            return created
        }
        let image = await task.value
        lock.withLock { inflight[url] = nil }
        if let image { memory.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// A channel avatar that shows a cached image immediately and only falls back to the
/// placeholder while a not-yet-cached picture loads.
struct CachedAvatarImage<Placeholder: View>: View {
    let url: URL
    let size: CGFloat
    private let placeholder: Placeholder
    @State private var image: UIImage?

    init(url: URL, size: CGFloat, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.size = size
        self.placeholder = placeholder()
        _image = State(initialValue: AvatarImageCache.shared.cached(url))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            // A new URL must not keep the previous channel's picture while it loads.
            image = AvatarImageCache.shared.cached(url)
            guard image == nil else { return }
            let loaded = await AvatarImageCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
#endif
