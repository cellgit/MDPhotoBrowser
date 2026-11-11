import CoreGraphics
import Testing
@testable import MDPhotoBrowser

@Suite("大图的几何")
struct ZoomGeometryTests {
    let phone = CGSize(width: 390, height: 844)

    @Test("横图放进竖屏：按宽放下，上下居中")
    func landscapeFits() {
        let scales = ZoomGeometry.scales(image: CGSize(width: 4000, height: 3000), bounds: phone)
        #expect(scales.minimum == 390.0 / 4000)
        let frame = ZoomGeometry.fittedFrame(image: CGSize(width: 4000, height: 3000), in: CGRect(origin: .zero, size: phone))
        #expect(frame.width == 390)
        #expect(abs(frame.height - 292.5) < 0.001)
        #expect(abs(frame.midY - 422) < 0.001)
    }

    @Test("长图：开了铺满宽就按宽放、贴着顶；没开就整张放下")
    func longPhoto() {
        let image = CGSize(width: 1000, height: 8000)
        #expect(ZoomGeometry.isLongPhoto(image, in: phone))
        #expect(!ZoomGeometry.isLongPhoto(CGSize(width: 1000, height: 2000), in: phone))

        let wide = ZoomGeometry.scales(image: image, bounds: phone, fitsLongPhotosToWidth: true)
        #expect(wide.minimum == 0.39)
        let frame = ZoomGeometry.fittedFrame(image: image, in: CGRect(origin: .zero, size: phone), fitsLongPhotosToWidth: true)
        #expect(frame.minY == 0)
        #expect(frame.width == 390)

        let whole = ZoomGeometry.scales(image: image, bounds: phone)
        #expect(whole.minimum == 844.0 / 8000)
    }

    @Test("最大倍数：给了就按给的，没给至少 3 倍；双击不超过最大")
    func maximum() {
        let image = CGSize(width: 4000, height: 3000)
        let given = ZoomGeometry.scales(image: image, bounds: phone, maximum: 4)
        #expect(abs(given.maximum - given.minimum * 4) < 0.0001)
        #expect(given.doubleTap <= given.maximum)

        // 小图：100 点放进手机，整张放下是 3.9 倍；清晰度那条（2/3）比 3 倍小，取最小的 3 倍。
        let small = ZoomGeometry.scales(image: CGSize(width: 100, height: 100), imageScale: 1, bounds: phone, screenScale: 3)
        #expect(small.minimum == 3.9)
        #expect(abs(small.maximum - 11.7) < 0.0001)
        #expect(abs(small.doubleTap - 9.75) < 0.0001)

        // 大图：按清晰度能放到一个图像素对一个屏幕像素再大一倍。
        let large = ZoomGeometry.scales(image: CGSize(width: 12000, height: 9000), imageScale: 1, bounds: phone, screenScale: 3)
        #expect(abs(large.maximum - 2.0 / 3) < 0.0001)
    }

    @Test("整张放下的尺寸对齐像素，放满的那一边不少一像素、不多出来")
    func fittedSize() {
        let room = CGSize(width: 440, height: 956)
        let scale = ZoomGeometry.scales(image: CGSize(width: 1200, height: 1600), bounds: room).minimum
        let size = ZoomGeometry.fittedSize(image: CGSize(width: 1200, height: 1600), scale: scale, room: room, screenScale: 3)
        #expect(size.width == 440)
        #expect(abs(size.height - 586.6667) < 0.001)

        let long = ZoomGeometry.fittedSize(image: CGSize(width: 900, height: 4200), scale: 440.0 / 900, room: room, screenScale: 3)
        #expect(long.width == 440)
        #expect(long.height > room.height, "长图铺满宽时比屏幕高，不收")
    }

    @Test("留白：能放图的地方变小")
    func padding() {
        let padding = EdgeInsetsValue(top: 0, leading: 20, bottom: 0, trailing: 20)
        let frame = ZoomGeometry.fittedFrame(image: CGSize(width: 1000, height: 1000), in: CGRect(origin: .zero, size: phone), padding: padding)
        #expect(frame.minX == 20)
        #expect(frame.width == 350)
    }

    @Test("双击放大的区域以点的地方为中心")
    func zoomRect() {
        let rect = ZoomGeometry.zoomRect(scale: 2, center: CGPoint(x: 100, y: 200), bounds: phone)
        #expect(rect == CGRect(x: 2.5, y: -11, width: 195, height: 422))
    }

    @Test("翻页：四舍五入，收在范围里")
    func pageIndex() {
        #expect(ZoomGeometry.pageIndex(offset: 0, pageWidth: 410, count: 5) == 0)
        #expect(ZoomGeometry.pageIndex(offset: 204, pageWidth: 410, count: 5) == 0)
        #expect(ZoomGeometry.pageIndex(offset: 206, pageWidth: 410, count: 5) == 1)
        #expect(ZoomGeometry.pageIndex(offset: 9999, pageWidth: 410, count: 5) == 4)
        #expect(ZoomGeometry.pageIndex(offset: -300, pageWidth: 410, count: 5) == 0)
        #expect(ZoomGeometry.pageIndex(offset: 100, pageWidth: 0, count: 5) == 0)
    }

    @Test("往下拖：拖到一半算满；拖得够远或甩得够快才关")
    func dismissal() {
        #expect(ZoomGeometry.dismissProgress(translation: 211, height: 844) == 0.5)
        #expect(ZoomGeometry.dismissProgress(translation: -900, height: 844) == 1)
        #expect(ZoomGeometry.shouldDismiss(translation: 120, velocity: 0))
        #expect(ZoomGeometry.shouldDismiss(translation: -120, velocity: 0))
        #expect(ZoomGeometry.shouldDismiss(translation: 30, velocity: 1200))
        #expect(!ZoomGeometry.shouldDismiss(translation: 30, velocity: -1200), "往回甩是不关")
        #expect(!ZoomGeometry.shouldDismiss(translation: 60, velocity: 300))
    }

    @Test("缩略图露出四分之一以上才算在屏幕上")
    func visibility() {
        let screen = CGRect(origin: .zero, size: phone)
        #expect(ZoomGeometry.isVisible(CGRect(x: 10, y: 10, width: 100, height: 100), in: screen))
        #expect(ZoomGeometry.isVisible(CGRect(x: 10, y: -50, width: 100, height: 100), in: screen))
        #expect(!ZoomGeometry.isVisible(CGRect(x: 10, y: -80, width: 100, height: 100), in: screen))
        #expect(!ZoomGeometry.isVisible(CGRect(x: 10, y: 900, width: 100, height: 100), in: screen))
        #expect(!ZoomGeometry.isVisible(.zero, in: screen))
    }
}
