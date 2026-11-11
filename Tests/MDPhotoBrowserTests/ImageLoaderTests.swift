import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import MDPhotoBrowser

@Suite("取图、解码")
struct ImageLoaderTests {
    /// 一张纯色 JPEG，`width` × `height` 像素。
    static func jpeg(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }

    /// 一张 `frames` 帧、每帧 `delay` 秒的 GIF。
    static func gif(frames: Int, delay: Double) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil)!
        let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for index in 0..<frames {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let frame = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: format).image { context in
                UIColor(hue: CGFloat(index) / CGFloat(frames), saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            }
            CGImageDestinationAddImage(destination, frame.cgImage!, properties)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test("太大的图按长边缩小")
    func downsamples() async throws {
        let image = try await MDImageLoader.decode(Self.jpeg(width: 3000, height: 2000), maximumPixelSize: 1000, animated: true)
        #expect(image.cgImage?.width == 1000)
        #expect(image.cgImage?.height == 667)
    }

    @Test("不大的图原样")
    func keepsSmallImages() async throws {
        let image = try await MDImageLoader.decode(Self.jpeg(width: 800, height: 600), maximumPixelSize: 4096, animated: true)
        #expect(image.cgImage?.width == 800)
    }

    @Test("GIF 解成动图，时长是每帧之和；不要动图时只取第一帧")
    func animatedGIF() async throws {
        let data = Self.gif(frames: 3, delay: 0.2)
        let animated = try await MDImageLoader.decode(data, maximumPixelSize: 4096, animated: true)
        #expect(animated.images?.count == 3)
        #expect(abs(animated.duration - 0.6) < 0.01)

        let still = try await MDImageLoader.decode(data, maximumPixelSize: 4096, animated: false)
        #expect(still.images == nil)
    }

    @Test("太快的帧按 100 毫秒放")
    func clampsFastFrames() async throws {
        let image = try await MDImageLoader.decode(Self.gif(frames: 2, delay: 0.01), maximumPixelSize: 4096, animated: true)
        #expect(abs(image.duration - 0.2) < 0.01)
    }

    @Test("不是图就报错")
    func undecodable() async {
        await #expect(throws: MDImageError.self) {
            _ = try await MDImageLoader.decode(Data("not an image".utf8), maximumPixelSize: 4096, animated: true)
        }
    }

    @Test("解好的图进缓存，下次不用等")
    func caches() async throws {
        let loader = MDImageLoader(cache: MDMemoryImageCache())
        let source = MDImageSource.data(Self.jpeg(width: 300, height: 200))
        #expect(loader.cachedImage(for: source) == nil)
        let image = try await loader.image(for: source)
        #expect(loader.cachedImage(for: source) === image)
    }

    @Test("本地文件")
    func file() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Self.jpeg(width: 500, height: 400).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try await MDImageLoader(cache: nil).image(for: .file(url))
        #expect(image.cgImage?.width == 500)
    }

    @Test("App 自己取的：先给 cached，取用 load，不进加载器的缓存")
    func custom() async throws {
        let ready = UIImage(systemName: "photo")!
        let loaded = UIImage(systemName: "star")!
        let cache = MDMemoryImageCache()
        let loader = MDImageLoader(cache: cache)
        let source = MDImageSource.custom(key: "a", cached: { ready }) { loaded }
        #expect(loader.cachedImage(for: source) === ready)

        let lazy = MDImageSource.custom(key: "b") { loaded }
        #expect(loader.cachedImage(for: lazy) == nil)
        #expect(try await loader.image(for: lazy) === loaded)
        #expect(lazy.cacheKey == nil)
    }
}
