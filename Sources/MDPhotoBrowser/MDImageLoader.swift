import ImageIO
import UIKit

/// 缓存解好的图。默认是内存里的 `MDMemoryImageCache`；要接 App 自己的缓存（或者别的图片库的），实现这四个方法，
/// 放进 `MDImageLoader(cache:)`。
public protocol MDImageCaching: AnyObject, Sendable {
    func image(forKey key: String) -> UIImage?
    func setImage(_ image: UIImage, forKey key: String)
    func removeImage(forKey key: String)
    func removeAllImages()
}

/// 内存缓存：按解码后的字节算成本，系统内存紧张时自己让出来（`NSCache`）。
public final class MDMemoryImageCache: MDImageCaching, @unchecked Sendable {
    /// 所有没另给缓存的 `MDImageLoader` 共用这一个。
    public static let shared = MDMemoryImageCache()

    private let cache = NSCache<NSString, UIImage>()

    /// `costLimit`：最多留多少字节解好的图，默认 128 MB（一张 4096 × 3072 的图约 48 MB）。
    public init(costLimit: Int = 128 * 1024 * 1024) {
        cache.totalCostLimit = costLimit
    }

    public func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    public func setImage(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString, cost: image.decodedByteCount)
    }

    public func removeImage(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    public func removeAllImages() {
        cache.removeAllObjects()
    }
}

/// 取不到的原因。
public enum MDImageError: Error, Sendable {
    /// 字节不是能解的图。
    case undecodable
    /// 服务端没给 2xx。
    case httpStatus(Int)
}

/// 取图：先问缓存，再按来源去取，在后台解码，太大的按 `maximumPixelSize` 缩小，动图（GIF、APNG、动的 WebP）
/// 解成会动的 `UIImage`。
///
/// 网上的图走 `session`：要带请求头（令牌、语言），给一个配好的 `URLSession`，或者用 `makeRequest` 改请求。
/// `URLSession` 自己的 `URLCache` 照样起作用，是磁盘那一层。
public struct MDImageLoader: Sendable {
    /// 没另给加载器的浏览器都用它。
    public static let shared = MDImageLoader()

    public var session: URLSession
    /// 解好的图放哪；nil 是不缓存。`.image`、`.custom` 两种来源不经过它。
    public var cache: (any MDImageCaching)?
    /// 解码时长边最多多少像素。看大图要能放大，默认 4096；再大的照片缩到这么大，免得一张图吃掉上百 MB 内存。
    public var maximumPixelSize: Int
    /// 多帧的图解成动图；false 时只取第一帧。
    public var decodesAnimatedImages: Bool
    /// 网上的图怎么发请求：加请求头、换地址都在这里。
    public var makeRequest: @Sendable (URL) -> URLRequest

    public init(
        session: URLSession = .shared,
        cache: (any MDImageCaching)? = MDMemoryImageCache.shared,
        maximumPixelSize: Int = 4096,
        decodesAnimatedImages: Bool = true,
        makeRequest: @escaping @Sendable (URL) -> URLRequest = { URLRequest(url: $0) }
    ) {
        self.session = session
        self.cache = cache
        self.maximumPixelSize = maximumPixelSize
        self.decodesAnimatedImages = decodesAnimatedImages
        self.makeRequest = makeRequest
    }

    /// 不用等就能给的那一张：手上的图、App 的 `cached`、缓存里的。打开、翻页的第一帧先用它，不闪。
    public func cachedImage(for source: MDImageSource) -> UIImage? {
        switch source {
        case .image(let image): image
        case .custom(let custom): custom.cached?()
        case .data, .url, .file: source.cacheKey.flatMap { cache?.image(forKey: $0) }
        }
    }

    /// 这张图。缓存里有就直接给，没有就去取、解码、放进缓存。
    public func image(for source: MDImageSource) async throws -> UIImage {
        if let hit = cachedImage(for: source) { return hit }
        let image: UIImage
        switch source {
        case .image(let given):
            return given
        case .custom(let custom):
            return try await custom.load()
        case .data(let data):
            image = try await Self.decode(data, maximumPixelSize: maximumPixelSize, animated: decodesAnimatedImages)
        case .file(let url):
            image = try await Self.decodeFile(url, maximumPixelSize: maximumPixelSize, animated: decodesAnimatedImages)
        case .url(let url) where url.isFileURL:
            image = try await Self.decodeFile(url, maximumPixelSize: maximumPixelSize, animated: decodesAnimatedImages)
        case .url(let url):
            let (data, response) = try await session.data(for: makeRequest(url))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw MDImageError.httpStatus(http.statusCode)
            }
            image = try await Self.decode(data, maximumPixelSize: maximumPixelSize, animated: decodesAnimatedImages)
        }
        if let key = source.cacheKey { cache?.setImage(image, forKey: key) }
        return image
    }

    /// 后台先取下来：快要翻到的那几张。取不到不报错。
    public func prefetch(_ sources: [MDImageSource]) {
        for source in sources where cachedImage(for: source) == nil {
            if case .custom = source { continue }
            Task(priority: .utility) { _ = try? await self.image(for: source) }
        }
    }

    /* ---------- 解码 ---------- */

    @concurrent
    private static func decodeFile(_ url: URL, maximumPixelSize: Int, animated: Bool) async throws -> UIImage {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try decodeNow(data, maximumPixelSize: maximumPixelSize, animated: animated)
    }

    /// 在后台解（`@concurrent`：不管从哪个 actor 调都不在它上面跑）：一张 12MP 的照片在主线程解要一百多毫秒，翻页会卡。
    @concurrent
    static func decode(_ data: Data, maximumPixelSize: Int, animated: Bool) async throws -> UIImage {
        try decodeNow(data, maximumPixelSize: maximumPixelSize, animated: animated)
    }

    static func decodeNow(_ data: Data, maximumPixelSize: Int, animated: Bool) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw MDImageError.undecodable
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw MDImageError.undecodable }
        if animated, count > 1, let image = animatedImage(source, count: count, maximumPixelSize: maximumPixelSize) {
            return image
        }
        guard let frame = frame(source, at: 0, maximumPixelSize: maximumPixelSize) else { throw MDImageError.undecodable }
        return UIImage(cgImage: frame)
    }

    /// 一帧：按 EXIF 方向转正，长边不超过 `maximumPixelSize`，立刻解好（交给界面时不再在主线程解）。
    private static func frame(_ source: CGImageSource, at index: Int, maximumPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// 动图：每一帧和它停多久（GIF、APNG、WebP 各在自己的字典里写），合成会动的 `UIImage`。
    private static func animatedImage(_ source: CGImageSource, count: Int, maximumPixelSize: Int) -> UIImage? {
        var frames: [UIImage] = []
        var duration: TimeInterval = 0
        // 动图本来就小：长边超过 1024 的动图每帧都缩一下，几十帧也占不了多少内存。
        let pixels = min(maximumPixelSize, 1024)
        for index in 0..<count {
            guard let frame = frame(source, at: index, maximumPixelSize: pixels) else { continue }
            frames.append(UIImage(cgImage: frame))
            duration += frameDelay(source, at: index)
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: duration)
    }

    private static func frameDelay(_ source: CGImageSource, at index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return 0.1 }
        let dictionaries: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dictionary, unclamped, clamped) in dictionaries {
            guard let values = properties[dictionary] as? [CFString: Any] else { continue }
            let delay = (values[unclamped] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? (values[clamped] as? Double) ?? 0.1
            // 浏览器的做法：小于 20 毫秒的按 100 毫秒放，不然有的 GIF 快得像快进。
            return delay < 0.02 ? 0.1 : delay
        }
        return 0.1
    }
}

extension UIImage {
    /// 解码后大约占多少字节（缓存的成本）。
    var decodedByteCount: Int {
        guard let cgImage else { return Int(size.width * scale * size.height * scale * 4) }
        let frames = max(images?.count ?? 1, 1)
        return cgImage.bytesPerRow * cgImage.height * frames
    }
}
