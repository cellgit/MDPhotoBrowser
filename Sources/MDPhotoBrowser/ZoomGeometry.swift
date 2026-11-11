import CoreGraphics

/// 大图的几何：放在哪、能放多大、双击放到多大、第几页。纯算术，不碰界面，单测守着。
enum ZoomGeometry {
    /// 一张图在页面上的缩放范围。`minimum` 是整张放下（或长图铺满宽），`doubleTap` 是双击放到多大。
    struct Scales: Equatable {
        var minimum: CGFloat
        var maximum: CGFloat
        var doubleTap: CGFloat
    }

    /// 长图：比页面还"瘦"的竖图（高宽比超过页面的两倍）。开了「长图铺满宽」时它按宽放、从顶上看起。
    static func isLongPhoto(_ image: CGSize, in bounds: CGSize) -> Bool {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return false }
        return image.height / image.width > 2 * (bounds.height / bounds.width)
    }

    /// 能放图的地方：页面减去四边留白。
    static func available(_ bounds: CGSize, padding: EdgeInsetsValue) -> CGSize {
        CGSize(width: max(1, bounds.width - padding.leading - padding.trailing),
               height: max(1, bounds.height - padding.top - padding.bottom))
    }

    /// 缩放范围。图的尺寸用点（`UIImage.size`），`imageScale` 是它的倍数（`UIImage.scale`），`screenScale` 是屏幕的。
    ///
    /// - 最小：整张放下；长图（开了 `fitsLongPhotosToWidth`）铺满宽。
    /// - 最大：给了 `maximum`（相对最小的倍数）就用它；没给按清晰度算——放到一个图像素对一个屏幕像素再大一倍，
    ///   但不少于最小的 3 倍（小图也要能放大看）。
    /// - 双击：铺满页面（照片和屏幕比例差得多时，铺满正好看清细节），至少最小的 2.5 倍，不超过最大。
    static func scales(
        image: CGSize,
        imageScale: CGFloat = 1,
        bounds: CGSize,
        padding: EdgeInsetsValue = .zero,
        fitsLongPhotosToWidth: Bool = false,
        maximum: CGFloat? = nil,
        screenScale: CGFloat = 3
    ) -> Scales {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else {
            return Scales(minimum: 1, maximum: 1, doubleTap: 1)
        }
        let room = available(bounds, padding: padding)
        let widthScale = room.width / image.width
        let heightScale = room.height / image.height
        let fit = min(widthScale, heightScale)
        let fill = max(widthScale, heightScale)
        let minimum = fitsLongPhotosToWidth && isLongPhoto(image, in: bounds) ? widthScale : fit

        let pixelPerfect = imageScale / max(screenScale, 1)
        var maxScale: CGFloat
        if let maximum {
            maxScale = minimum * max(maximum, 1)
        } else {
            maxScale = max(pixelPerfect * 2, minimum * 3)
        }
        maxScale = max(maxScale, minimum)

        let doubleTap = min(max(fill, minimum * 2.5), maxScale)
        return Scales(minimum: minimum, maximum: maxScale, doubleTap: doubleTap)
    }

    /// 整张放下时的尺寸，对齐到屏幕像素：四舍五入，放满的那一边不超过能放图的地方。往下取整的话，
    /// 1200 × (440 / 1200) 算出来是 439.999…，图左边会露出一条一像素的黑边；多出一点又会变得能滚。
    static func fittedSize(image: CGSize, scale: CGFloat, room: CGSize, screenScale: CGFloat) -> CGSize {
        func snap(_ value: CGFloat, _ limit: CGFloat) -> CGFloat {
            let snapped = (value * screenScale).rounded() / screenScale
            return value <= limit + 0.5 ? min(snapped, limit) : snapped
        }
        return CGSize(width: snap(image.width * scale, room.width), height: snap(image.height * scale, room.height))
    }

    /// 打开、关上的转场里，这张图最后停在哪：按最小缩放放在页面里，居中（长图铺满宽、贴着顶）。
    static func fittedFrame(
        image: CGSize,
        in container: CGRect,
        padding: EdgeInsetsValue = .zero,
        fitsLongPhotosToWidth: Bool = false
    ) -> CGRect {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else { return container }
        let scales = scales(image: image, bounds: container.size, padding: padding, fitsLongPhotosToWidth: fitsLongPhotosToWidth)
        let size = CGSize(width: image.width * scales.minimum, height: image.height * scales.minimum)
        let room = CGRect(x: container.minX + padding.leading, y: container.minY + padding.top,
                          width: container.width - padding.leading - padding.trailing,
                          height: container.height - padding.top - padding.bottom)
        let x = room.midX - size.width / 2
        // 比页面高的（长图）从顶上开始。
        let y = size.height > room.height ? room.minY : room.midY - size.height / 2
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 双击放大：以 `point`（图上的坐标，未缩放）为中心、放到 `scale` 时，要让页面露出图上的哪一块。
    static func zoomRect(scale: CGFloat, center point: CGPoint, bounds: CGSize) -> CGRect {
        let width = bounds.width / scale
        let height = bounds.height / scale
        return CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
    }

    /// 图比页面小时四周留多少（`contentInset`），让它居中。
    static func centeringInset(content: CGSize, bounds: CGSize) -> (horizontal: CGFloat, vertical: CGFloat) {
        (max(0, (bounds.width - content.width) / 2), max(0, (bounds.height - content.height) / 2))
    }

    /// 横向翻页时，`offset` 落在第几页（四舍五入，收在 0 到 count-1 之间）。
    static func pageIndex(offset: CGFloat, pageWidth: CGFloat, count: Int) -> Int {
        guard pageWidth > 0, count > 0 else { return 0 }
        return min(max(Int((offset / pageWidth).rounded()), 0), count - 1)
    }

    /// 关掉之前往下拖了多远：拖到页面高度的一半算拖满（背景全透、图缩到最小）。
    static func dismissProgress(translation: CGFloat, height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        return min(1, abs(translation) / (height / 2))
    }

    /// 松手时关不关：拖过 `distance`，或者甩得够快（每秒 `velocity` 点以上），往哪边都算。
    static func shouldDismiss(translation: CGFloat, velocity: CGFloat, distance: CGFloat = 110, speed: CGFloat = 900) -> Bool {
        abs(translation) > distance || (abs(velocity) > speed && translation * velocity >= 0)
    }

    /// 缩略图在不在屏幕上（露出至少四分之一）：不在的话关的时候不往它那里缩，原地淡出。
    static func isVisible(_ frame: CGRect, in screen: CGRect) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        let shown = frame.intersection(screen)
        guard !shown.isNull else { return false }
        return shown.width * shown.height >= frame.width * frame.height / 4
    }
}

/// 四边留白（不依赖 SwiftUI 的 `EdgeInsets`，几何这一层只用 CoreGraphics）。
struct EdgeInsetsValue: Equatable, Sendable {
    var top: CGFloat
    var leading: CGFloat
    var bottom: CGFloat
    var trailing: CGFloat

    static let zero = EdgeInsetsValue(top: 0, leading: 0, bottom: 0, trailing: 0)
}
