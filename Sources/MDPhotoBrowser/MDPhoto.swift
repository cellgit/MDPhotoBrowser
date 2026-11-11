import UIKit

/// 一张照片：从哪里取（`source`），取到之前先拿什么垫着（`placeholder`），下面写什么（`caption`）。
///
/// `id` 在一组照片里唯一。缩略图上挂 `.mdPhotoSource(id)` 用的就是它：打开、关上时照片从那个缩略图里放大出来、
/// 缩回去。
///
/// `placeholder` 和原图要是**同一个宽高比**（比如服务端给的小一档的图），转场和翻页时先用它画，原图到了再换；
/// 裁成方块的缩略图不行，换的那一下会跳。
public struct MDPhoto: Identifiable, Sendable {
    public var id: String
    public var source: MDImageSource
    public var placeholder: MDImageSource?
    public var caption: String?
    /// 读屏念的；没给就念说明，说明也没有就念「第 3 张，共 9 张」。
    public var accessibilityLabel: String?

    public init(
        id: String,
        source: MDImageSource,
        placeholder: MDImageSource? = nil,
        caption: String? = nil,
        accessibilityLabel: String? = nil
    ) {
        self.id = id
        self.source = source
        self.placeholder = placeholder
        self.caption = caption
        self.accessibilityLabel = accessibilityLabel
    }
}

public extension MDPhoto {
    /// 手上已经有的图。
    static func image(_ image: UIImage, id: String = UUID().uuidString, caption: String? = nil) -> MDPhoto {
        MDPhoto(id: id, source: .image(image), caption: caption)
    }

    /// 网上的图（经 `MDImageLoader` 的 `URLSession` 取，进内存缓存）。`id` 不给就是地址本身。
    static func url(_ url: URL, id: String? = nil, placeholder: MDImageSource? = nil, caption: String? = nil) -> MDPhoto {
        MDPhoto(id: id ?? url.absoluteString, source: .url(url), placeholder: placeholder, caption: caption)
    }

    /// 本地文件里的图（在后台读、解码、按需缩小）。
    static func file(_ url: URL, id: String? = nil, caption: String? = nil) -> MDPhoto {
        MDPhoto(id: id ?? url.absoluteString, source: .file(url), caption: caption)
    }
}

/// 一张图从哪里来。
public enum MDImageSource: Sendable {
    /// 手上的图，不用等。
    case image(UIImage)
    /// 还没解码的字节（JPEG、PNG、HEIC、GIF…），在后台解。
    case data(Data)
    /// `http(s)` 地址；`file://` 地址等于 `.file`。
    case url(URL)
    /// 本地文件。
    case file(URL)
    /// App 自己取：带令牌的接口、自己的缓存。`MDImageLoader` 不替它缓存（App 一般有自己的一层）。
    case custom(MDCustomImageSource)

    /// App 自己取的图：`key` 认这张图（转场、翻页时判断是不是同一张），`cached` 不用等就能给的那一张
    /// （打开的那一下要用它做转场），`load` 真正去取。
    public static func custom(
        key: String,
        cached: (@Sendable () -> UIImage?)? = nil,
        load: @escaping @Sendable () async throws -> UIImage
    ) -> MDImageSource {
        .custom(MDCustomImageSource(key: key, cached: cached, load: load))
    }

    /// 缓存用的键。`.image` 和 `.custom` 不进 `MDImageLoader` 的缓存，没有键。
    var cacheKey: String? {
        switch self {
        case .image, .custom: nil
        case .data(let data): "data:\(data.count):\(data.hashValue)"
        case .url(let url), .file(let url): url.absoluteString
        }
    }
}

/// `MDImageSource.custom` 的内容。
public struct MDCustomImageSource: Sendable {
    public var key: String
    public var cached: (@Sendable () -> UIImage?)?
    public var load: @Sendable () async throws -> UIImage

    public init(key: String, cached: (@Sendable () -> UIImage?)? = nil, load: @escaping @Sendable () async throws -> UIImage) {
        self.key = key
        self.cached = cached
        self.load = load
    }
}
