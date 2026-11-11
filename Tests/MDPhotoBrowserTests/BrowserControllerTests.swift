import Testing
import UIKit
@testable import MDPhotoBrowser

@MainActor
@Suite("一次浏览的状态")
struct BrowserControllerTests {
    static func photos(_ ids: String...) -> [MDPhoto] {
        ids.map { MDPhoto(id: $0, source: .image(UIImage())) }
    }

    @Test("打开的位置收在范围里")
    func clampsIndex() {
        #expect(BrowserController(photos: Self.photos("a", "b"), index: 5, configuration: .init()).index == 1)
        #expect(BrowserController(photos: Self.photos("a", "b"), index: -1, configuration: .init()).index == 0)
        #expect(BrowserController(photos: [], index: 3, configuration: .init()).currentPhoto == nil)
    }

    @Test("翻页报给外面")
    func pages() {
        let browser = BrowserController(photos: Self.photos("a", "b", "c"), index: 0, configuration: .init())
        var shown: [String] = []
        browser.handlers.onIndexChange = { shown.append($0.id) }
        browser.page(to: 2)
        browser.page(to: 9)
        #expect(browser.index == 2)
        #expect(shown == ["c"])
    }

    @Test("删掉：外面同意才拿掉，停在原来的位置")
    func deletes() async {
        let browser = BrowserController(photos: Self.photos("a", "b", "c"), index: 1, configuration: .init())
        var asked: [String] = []
        var approve = false
        browser.handlers.onDelete = { photo in
            asked.append(photo.id)
            return approve
        }
        await browser.delete(browser.photos[1])
        #expect(browser.photos.map(\.id) == ["a", "b", "c"], "不同意就不动")

        approve = true
        await browser.delete(browser.photos[1])
        #expect(asked == ["b", "b"])
        #expect(browser.photos.map(\.id) == ["a", "c"])
        #expect(browser.currentPhoto?.id == "c")
    }

    @Test("删最后一张退到前一张，删到一张不剩就关")
    func deletesToTheEnd() async {
        let browser = BrowserController(photos: Self.photos("a", "b"), index: 1, configuration: .init())
        var willDismiss = false
        browser.handlers.onWillDismiss = { _ in willDismiss = true }
        await browser.delete(browser.photos[1])
        #expect(browser.currentPhoto?.id == "a")
        await browser.delete(browser.photos[0])
        #expect(browser.photos.isEmpty)
        #expect(willDismiss)
        #expect(browser.phase == .closing || browser.phase == .closed)
    }

    @Test("换一组照片：停在原来那张上，它没了停在原来的位置")
    func replacesPhotos() {
        let browser = BrowserController(photos: Self.photos("a", "b", "c", "d"), index: 2, configuration: .init())
        var shown: [String] = []
        browser.handlers.onIndexChange = { shown.append($0.id) }

        browser.replacePhotos(Self.photos("x", "a", "b", "c", "d"))
        #expect(browser.currentPhoto?.id == "c")
        #expect(browser.index == 3)
        #expect(shown.isEmpty, "还是同一张，不报")

        browser.replacePhotos(Self.photos("x", "a", "b", "d"))
        #expect(browser.index == 3)
        #expect(browser.currentPhoto?.id == "d")
        #expect(shown == ["d"])
    }

    @Test("同一组照片只改了说明：位置不动")
    func updatesCaptions() {
        let browser = BrowserController(photos: Self.photos("a", "b"), index: 1, configuration: .init())
        var changed = Self.photos("a", "b")
        changed[1].caption = "海边"
        browser.replacePhotos(changed)
        #expect(browser.index == 1)
        #expect(browser.currentPhoto?.caption == "海边")
    }

    @Test("关只关一次")
    func closesOnce() {
        let browser = BrowserController(photos: Self.photos("a"), index: 0, configuration: .init())
        var willDismiss = 0
        var finished = 0
        browser.handlers.onWillDismiss = { _ in willDismiss += 1 }
        browser.handlers.onFinish = { _ in finished += 1 }
        browser.close()
        browser.close()
        #expect(browser.phase == .closing || browser.phase == .closed)
        #expect(willDismiss == 1)
        #expect(finished <= 1)
    }
}
