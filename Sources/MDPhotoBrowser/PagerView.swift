import SwiftUI
import UIKit

/// SwiftUI 里的翻页那一层：一个 UIKit 的 `PagerView`。传进来的配置、`ids`、`index` 变了就同步过去。
struct PagerRepresentable: UIViewRepresentable {
    let controller: BrowserController
    let configuration: MDPhotoBrowserConfiguration
    /// 照片的 id（变了就重新排页）和要停的那一页。由外面读出来传进来，SwiftUI 才知道它们变了要刷新。
    let ids: [MDPhoto.ID]
    let index: Int

    func makeUIView(context: Context) -> PagerView {
        let view = PagerView(controller: controller)
        controller.pager = view
        return view
    }

    func updateUIView(_ view: PagerView, context: Context) {
        view.sync(photos: controller.photos, index: index, configuration: configuration)
    }
}

/// 横着翻的那一层（UIKit）：一个分页的 `UIScrollView`，每页一个能缩放的 `ZoomPageView`。只留当前页和两边各一页，
/// 翻过去的页拿来复用。页和页之间留 `pageSpacing` 的空：滚动视图比屏幕宽出这么多，每页在里面居中。
@MainActor
final class PagerView: UIView, UIScrollViewDelegate {
    private let scrollView = PagingScrollView()
    private var pages: [Int: ZoomPageView] = [:]
    private var reusable: [ZoomPageView] = []
    private var photos: [MDPhoto] = []
    private(set) var index = 0
    private var configuration = MDPhotoBrowserConfiguration()
    private var spacing: CGFloat = 20
    /// 正在按新尺寸排版：这时的滚动不算翻页。
    private var relayingOut = false
    private var laidOutSize: CGSize = .zero
    /// 强引用：拆界面时这一层可能比 `BrowserRoot` 晚走，滚动回调里还会用到它（它对这一层是弱引用，不成环）。
    private let controller: BrowserController
    /// 截屏保护时装着滚动视图的那一层（安全输入框的画布）；不保护时就是自己。
    private var host: UIView { secure?.canvas ?? self }
    private var secure: SecureContainerView?

    init(controller: BrowserController) {
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = false
        scrollView.delegate = self
        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        scrollView.decelerationRate = .fast
        scrollView.scrollsToTop = false
        scrollView.accessibilityDelegateBridge = self
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /* ---------- 同步 ---------- */

    func sync(photos newPhotos: [MDPhoto], index newIndex: Int, configuration newConfiguration: MDPhotoBrowserConfiguration) {
        configuration = newConfiguration
        installSecureContainerIfNeeded()
        let idsChanged = newPhotos.map(\.id) != photos.map(\.id)
        photos = newPhotos
        if spacing != newConfiguration.pageSpacing {
            spacing = newConfiguration.pageSpacing
            laidOutSize = .zero
        }
        if idsChanged {
            reloadPages(at: newIndex)
        } else if newIndex != index, !scrollView.isTracking, !scrollView.isDecelerating {
            scroll(to: newIndex, animated: false)
        } else {
            // 同一组照片：只把新的说明、配置交给已有的页。
            for (pageIndex, page) in pages where photos.indices.contains(pageIndex) {
                page.update(photo: photos[pageIndex], configuration: configuration)
            }
        }
    }

    private func installSecureContainerIfNeeded() {
        guard configuration.protectsFromScreenshots, secure == nil else { return }
        let container = SecureContainerView(frame: bounds)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        insertSubview(container, at: 0)
        secure = container
        scrollView.removeFromSuperview()
        container.canvas.addSubview(scrollView)
        laidOutSize = .zero
        setNeedsLayout()
    }

    private func reloadPages(at newIndex: Int) {
        for page in pages.values { recycle(page) }
        pages.removeAll()
        index = photos.isEmpty ? 0 : min(max(newIndex, 0), photos.count - 1)
        laidOutSize = .zero
        setNeedsLayout()
        layoutIfNeeded()
    }

    /* ---------- 排版 ---------- */

    private var pageWidth: CGFloat { bounds.width + spacing }

    var photoCount: Int { photos.count }

    override func layoutSubviews() {
        super.layoutSubviews()
        secure?.frame = bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        if laidOutSize != bounds.size {
            laidOutSize = bounds.size
            relayingOut = true
            scrollView.frame = CGRect(x: -spacing / 2, y: 0, width: pageWidth, height: bounds.height)
            scrollView.contentSize = CGSize(width: pageWidth * CGFloat(photos.count), height: bounds.height)
            scrollView.contentOffset = CGPoint(x: pageWidth * CGFloat(index), y: 0)
            for (pageIndex, page) in pages {
                page.frame = frameForPage(pageIndex)
                page.boundsDidChange()
            }
            relayingOut = false
        }
        tilePages()
    }

    private func frameForPage(_ pageIndex: Int) -> CGRect {
        CGRect(x: pageWidth * CGFloat(pageIndex) + spacing / 2, y: 0, width: bounds.width, height: bounds.height)
    }

    /// 摆好当前页和两边各一页，别的收起来复用；再往外的预先取图。
    private func tilePages() {
        guard !photos.isEmpty else {
            for page in pages.values { recycle(page) }
            pages.removeAll()
            return
        }
        let wanted = Set(max(index - 1, 0)...min(index + 1, photos.count - 1))
        for (pageIndex, page) in pages where !wanted.contains(pageIndex) {
            recycle(page)
            pages[pageIndex] = nil
        }
        for pageIndex in wanted where pages[pageIndex] == nil {
            let page = reusable.popLast() ?? makePage()
            page.frame = frameForPage(pageIndex)
            page.pageIndex = pageIndex
            page.configure(photo: photos[pageIndex], configuration: configuration)
            scrollView.addSubview(page)
            pages[pageIndex] = page
        }
        prefetch()
    }

    private func makePage() -> ZoomPageView {
        let page = ZoomPageView()
        page.pager = self
        return page
    }

    private func recycle(_ page: ZoomPageView) {
        page.prepareForReuse()
        page.removeFromSuperview()
        if reusable.count < 3 { reusable.append(page) }
    }

    private func prefetch() {
        let distance = max(configuration.preloadDistance, 0)
        guard distance > 0, !photos.isEmpty else { return }
        let range = max(index - distance - 1, 0)...min(index + distance + 1, photos.count - 1)
        let sources = range.filter { pages[$0] == nil }.map { photos[$0].source }
        configuration.loader.prefetch(sources)
    }

    /* ---------- 滚动 ---------- */

    func scroll(to newIndex: Int, animated: Bool) {
        guard photos.indices.contains(newIndex) else { return }
        let offset = CGPoint(x: pageWidth * CGFloat(newIndex), y: 0)
        if animated {
            scrollView.setContentOffset(offset, animated: true)
        } else {
            index = newIndex
            relayingOut = true
            scrollView.contentOffset = offset
            relayingOut = false
            tilePages()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !relayingOut, !photos.isEmpty else { return }
        let current = ZoomGeometry.pageIndex(offset: scrollView.contentOffset.x, pageWidth: pageWidth, count: photos.count)
        guard current != index else { return }
        pages[index]?.resetZoom(animated: false)
        index = current
        tilePages()
        controller.pagerDidShow(index: current)
        announcePosition()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        controller.userInteracted()
    }

    private func announcePosition() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .pageScrolled, argument: configuration.labels.position(index + 1, photos.count))
    }

    /* ---------- 给浏览器的 ---------- */

    /// 当前页上的图和它此刻在窗口里的位置（算上放大、拖动）。关的时候从这里飞回去。
    func visibleImage() -> (image: UIImage, frame: CGRect, cornerRadius: CGFloat)? {
        guard let page = pages[index], let image = page.imageView.image else { return nil }
        let frame = page.imageView.convert(page.imageView.bounds, to: nil)
        guard frame.width > 0, frame.height > 0 else { return nil }
        return (image, frame, 0)
    }

    func image(at pageIndex: Int) -> UIImage? {
        pages[pageIndex]?.imageView.image
    }

    /// 系统的分享面板，从最上面那个页面弹出来；iPad 上是指着右上角按钮的气泡。
    func presentShareSheet(items: [Any]) {
        guard var top = window?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = CGRect(x: bounds.maxX - safeAreaInsets.right - 70, y: safeAreaInsets.top + 8, width: 44, height: 44)
            popover.permittedArrowDirections = .up
        }
        top.present(sheet, animated: true)
    }

    /* ---------- 页报上来的 ---------- */

    func pageDidLoad(_ page: ZoomPageView, image: UIImage) {
        guard let pageIndex = page.pageIndex, pages[pageIndex] === page else { return }
        controller.pagerDidLoad(image, at: pageIndex)
    }

    func pageDidSingleTap(_ page: ZoomPageView) {
        controller.singleTap()
    }

    func pageDidInteract(_ page: ZoomPageView) {
        controller.userInteracted()
    }

    func pageDragBegan(_ page: ZoomPageView) {
        controller.dragBegan()
    }

    func pageDragChanged(_ page: ZoomPageView, progress: CGFloat) {
        controller.dragChanged(progress: progress)
    }

    func pageDragEnded(_ page: ZoomPageView, dismiss: Bool) {
        controller.dragEnded(dismiss: dismiss)
    }

    var canDragToDismiss: Bool {
        configuration.swipeToDismiss && controller.phase == .open
    }

    /* ---------- 键盘 ---------- */

    // iPad、Mac 的键盘：左右翻页，Esc 关掉。翻页那一层出现时自己当第一响应者，按键才轮得到它（它不收字，不会弹键盘）。

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
    }

    override var keyCommands: [UIKeyCommand]? {
        let labels = configuration.labels
        let previous = UIKeyCommand(title: labels.previous, action: #selector(showPrevious), input: UIKeyCommand.inputLeftArrow)
        let next = UIKeyCommand(title: labels.next, action: #selector(showNext), input: UIKeyCommand.inputRightArrow)
        let close = UIKeyCommand(title: labels.close, action: #selector(closeBrowser), input: UIKeyCommand.inputEscape)
        // 方向键默认先给系统（焦点、滚动）；这里翻页优先。
        previous.wantsPriorityOverSystemBehavior = true
        next.wantsPriorityOverSystemBehavior = true
        return [previous, next, close]
    }

    @objc private func showPrevious() {
        controller.page(to: index - 1)
    }

    @objc private func showNext() {
        controller.page(to: index + 1)
    }

    @objc private func closeBrowser() {
        controller.close()
    }

    /* ---------- 读屏 ---------- */

    /// 读屏三指左右滑：翻页。
    func accessibilityScrollPage(_ direction: UIAccessibilityScrollDirection) -> Bool {
        switch direction {
        case .left, .next: controller.page(to: index + 1)
        case .right, .previous: controller.page(to: index - 1)
        default: return false
        }
        return true
    }
}

/// 分页的滚动视图：竖着的拖动不归它（留给页上的「往下拖关掉」），这样斜着拖时不会一边翻页一边往下走。
final class PagingScrollView: UIScrollView {
    weak var accessibilityDelegateBridge: PagerView?

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            if abs(velocity.y) > abs(velocity.x) { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        accessibilityDelegateBridge?.accessibilityScrollPage(direction) ?? false
    }
}
