import ImageIO
import MDPhotoBrowser
import UIKit
import UniformTypeIdentifiers

/// 示例照片：画出来的安静风景，各种宽高比（横、竖、方、全景、长截图），外加一张 GIF、一个本地文件。
enum SamplePhotos {
    struct Scene {
        let name: String
        let size: CGSize
        let sky: (UIColor, UIColor)
        let ground: UIColor
    }

    static let scenes: [Scene] = [
        Scene(name: "Morning sea", size: CGSize(width: 1600, height: 1200),
              sky: (UIColor(red: 0.80, green: 0.86, blue: 0.90, alpha: 1), UIColor(red: 0.93, green: 0.90, blue: 0.86, alpha: 1)),
              ground: UIColor(red: 0.42, green: 0.55, blue: 0.62, alpha: 1)),
        Scene(name: "Pines", size: CGSize(width: 1200, height: 1600),
              sky: (UIColor(red: 0.84, green: 0.88, blue: 0.86, alpha: 1), UIColor(red: 0.94, green: 0.93, blue: 0.89, alpha: 1)),
              ground: UIColor(red: 0.36, green: 0.45, blue: 0.40, alpha: 1)),
        Scene(name: "Lake", size: CGSize(width: 1400, height: 1400),
              sky: (UIColor(red: 0.78, green: 0.83, blue: 0.89, alpha: 1), UIColor(red: 0.90, green: 0.89, blue: 0.90, alpha: 1)),
              ground: UIColor(red: 0.50, green: 0.58, blue: 0.66, alpha: 1)),
        Scene(name: "Ridge", size: CGSize(width: 3000, height: 1000),
              sky: (UIColor(red: 0.88, green: 0.85, blue: 0.82, alpha: 1), UIColor(red: 0.95, green: 0.92, blue: 0.87, alpha: 1)),
              ground: UIColor(red: 0.55, green: 0.52, blue: 0.50, alpha: 1)),
        Scene(name: "Long read", size: CGSize(width: 900, height: 4200),
              sky: (UIColor(red: 0.92, green: 0.91, blue: 0.88, alpha: 1), UIColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1)),
              ground: UIColor(red: 0.70, green: 0.68, blue: 0.64, alpha: 1)),
    ]

    /// 示例那一组：画出来的五张 + 一张 GIF + 一个本地文件。
    static let all: [MDPhoto] = {
        var photos = scenes.map { scene in
            MDPhoto(id: scene.name, source: .image(render(scene)), caption: scene.name)
        }
        photos.append(MDPhoto(id: "Tide", source: .data(tideGIF), caption: "Tide (GIF)"))
        photos.append(MDPhoto(id: "Dune", source: .file(dunesFile), caption: "Dune (file)"))
        return photos
    }()

    /// 一张风景：上面是天空的渐变，下面一条远山或水面，再一个淡淡的太阳。长图上画一行行“文字”。
    static func render(_ scene: Scene, scale: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: scene.size.width * scale, height: scene.size.height * scale)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let colors = [scene.sky.0.cgColor, scene.sky.1.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

            if scene.size.height > scene.size.width * 2 {
                // 长截图：一行一行的灰条。
                UIColor(white: 0.55, alpha: 0.35).setFill()
                var y = size.width * 0.12
                while y < size.height - size.width * 0.1 {
                    let width = size.width * (0.55 + 0.3 * CGFloat(Int(y) % 7) / 7)
                    UIBezierPath(roundedRect: CGRect(x: size.width * 0.1, y: y, width: width, height: size.width * 0.03),
                                 cornerRadius: size.width * 0.015).fill()
                    y += size.width * 0.075
                }
                return
            }

            let sun = min(size.width, size.height) * 0.12
            UIColor(white: 1, alpha: 0.55).setFill()
            cg.fillEllipse(in: CGRect(x: size.width * 0.68, y: size.height * 0.2, width: sun, height: sun))

            let horizon = size.height * 0.62
            let ridge = UIBezierPath()
            ridge.move(to: CGPoint(x: 0, y: horizon))
            let steps = 6
            for step in 1...steps {
                let x = size.width * CGFloat(step) / CGFloat(steps)
                let lift = (step % 2 == 0 ? 0.05 : -0.04) * size.height
                ridge.addQuadCurve(to: CGPoint(x: x, y: horizon + (step == steps ? 0 : lift / 2)),
                                   controlPoint: CGPoint(x: x - size.width / CGFloat(steps * 2), y: horizon + lift))
            }
            ridge.addLine(to: CGPoint(x: size.width, y: size.height))
            ridge.addLine(to: CGPoint(x: 0, y: size.height))
            ridge.close()
            scene.ground.setFill()
            ridge.fill()
        }
    }

    /// 一张八帧的 GIF：一道浅色的浪从左走到右。
    static let tideGIF: Data = {
        let data = NSMutableData()
        let frames = 8
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil) else { return Data() }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let size = CGSize(width: 800, height: 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        for frame in 0..<frames {
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor(red: 0.45, green: 0.57, blue: 0.64, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor(white: 1, alpha: 0.45).setFill()
                let x = size.width * CGFloat(frame) / CGFloat(frames)
                UIBezierPath(ovalIn: CGRect(x: x - 120, y: size.height * 0.55, width: 360, height: 60)).fill()
            }
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.12]] as CFDictionary
            if let cgImage = image.cgImage { CGImageDestinationAddImage(destination, cgImage, properties) }
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }()

    /// 写到临时目录里的一张 JPEG。
    static let dunesFile: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dunes.jpg")
        let scene = Scene(name: "Dune", size: CGSize(width: 2400, height: 1600),
                          sky: (UIColor(red: 0.90, green: 0.86, blue: 0.80, alpha: 1), UIColor(red: 0.96, green: 0.93, blue: 0.88, alpha: 1)),
                          ground: UIColor(red: 0.74, green: 0.64, blue: 0.52, alpha: 1))
        try? render(scene).jpegData(compressionQuality: 0.85)?.write(to: url)
        return url
    }()
}
