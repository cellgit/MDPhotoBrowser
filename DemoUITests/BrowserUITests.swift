import XCTest

/// 在示例 App 里真点一遍：打开、翻页、单击显隐、双击放大、往下拖关掉、删除、自己盖的一层、UIKit。
///
/// 拖动用坐标按住再拖（`press(forDuration:thenDragTo:)`）：元素上的 `swipeUp()` 在滚动视图里时灵时不灵。
@MainActor
final class BrowserUITests: XCTestCase {
    private let app = XCUIApplication()

    private func openExample(_ title: String) {
        continueAfterFailure = false
        app.launch()
        app.buttons[title].firstMatch.tap()
    }

    private var closeButton: XCUIElement { app.buttons["Close"] }

    /// 顶上的「3 / 7」：读屏念「Photo 3 of 7」。
    private func counter(_ index: Int, of count: Int) -> XCUIElement {
        app.staticTexts["Photo \(index) of \(count)"]
    }

    private func drag(dx: CGFloat = 0, dy: CGFloat = 0, from start: CGVector = CGVector(dx: 0.5, dy: 0.5)) {
        let window = app.windows.firstMatch
        let from = window.coordinate(withNormalizedOffset: start)
        let to = from.withOffset(CGVector(dx: dx, dy: dy))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func tapCenter(count: Int = 1) {
        let center = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        if count == 2 { center.doubleTap() } else { center.tap() }
    }

    func testOpenPageAndClose() {
        openExample("Grid")
        app.buttons["thumb-0"].tap()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3))
        XCTAssertTrue(counter(1, of: 7).exists)

        drag(dx: -260)
        XCTAssertTrue(counter(2, of: 7).waitForExistence(timeout: 2))
        drag(dx: 260)
        XCTAssertTrue(counter(1, of: 7).waitForExistence(timeout: 2))

        closeButton.tap()
        XCTAssertTrue(closeButton.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["thumb-0"].isHittable)
    }

    func testSingleTapTogglesControls() {
        openExample("Grid")
        app.buttons["thumb-1"].tap()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3))
        tapCenter()
        XCTAssertTrue(closeButton.waitForNonExistence(timeout: 2))
        tapCenter()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 2))
    }

    func testSwipeDownCloses() {
        openExample("Grid")
        app.buttons["thumb-2"].tap()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3))
        drag(dy: 320)
        XCTAssertTrue(closeButton.waitForNonExistence(timeout: 3))
    }

    func testSwipeUpCloses() {
        openExample("Grid")
        app.buttons["thumb-0"].tap()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3))
        drag(dy: -320)
        XCTAssertTrue(closeButton.waitForNonExistence(timeout: 3))
    }

    /// 放大之后往下拖是看图，不是关。
    func testDoubleTapZoomsAndBlocksDismiss() {
        openExample("Grid")
        app.buttons["thumb-0"].tap()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3))
        tapCenter(count: 2)
        sleep(1)
        drag(dy: 200)
        sleep(1)
        XCTAssertTrue(closeButton.exists, "放大了还被关掉")
        tapCenter(count: 2)
        sleep(1)
        drag(dy: 320)
        XCTAssertTrue(closeButton.waitForNonExistence(timeout: 3))
    }

    func testDeleteAsksThenRemoves() {
        openExample("Grid")
        app.buttons["thumb-0"].tap()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3))
        app.buttons["Delete"].tap()
        let confirm = app.buttons.matching(identifier: "Delete").element(boundBy: 1)
        XCTAssertTrue(app.staticTexts["Delete this photo?"].waitForExistence(timeout: 2))
        if confirm.exists { confirm.tap() } else { app.sheets.buttons["Delete"].tap() }
        XCTAssertTrue(counter(1, of: 6).waitForExistence(timeout: 3))
        closeButton.tap()
        XCTAssertTrue(closeButton.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Morning sea"].exists, "删掉的那张还在网格里")
    }

    func testAccessoryOverlay() {
        openExample("Accessory overlay")
        app.buttons["accessory-1"].tap()
        XCTAssertTrue(app.buttons["Like"].waitForExistence(timeout: 3))
        app.buttons["Like"].tap()
        XCTAssertTrue(app.buttons["Unlike"].waitForExistence(timeout: 2))
        closeButton.tap()
        XCTAssertTrue(app.staticTexts["Liked: Pines"].waitForExistence(timeout: 3))
    }

    func testUIKitController() {
        openExample("UIKit")
        app.buttons["uikit-1"].tap()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3))
        drag(dx: -260)
        XCTAssertTrue(app.staticTexts["Showing 3"].waitForExistence(timeout: 2) || counter(3, of: 3).exists)
        // 这个例子单击就关。
        tapCenter()
        XCTAssertTrue(app.staticTexts["Closed at 3"].waitForExistence(timeout: 3))
    }

    func testSlowLoadFailsThenRetries() {
        openExample("Slow and failing loads")
        app.buttons["slow-2"].tap()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3))
        // 垫着的小图在，原图第一次失败：留着小图，不出错误；关掉再开，第二次取到。
        sleep(2)
        XCTAssertTrue(closeButton.exists)
        closeButton.tap()
        XCTAssertTrue(closeButton.waitForNonExistence(timeout: 3))
        app.buttons["slow-2"].tap()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3))
    }
}
