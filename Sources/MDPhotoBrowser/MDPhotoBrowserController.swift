import SwiftUI
import UIKit

/// UIKit 里用的浏览器。`present` 出来就是全屏浏览，照片从 `delegate` 给的缩略图视图里放大出来；`animated` 传什么都行，
/// 系统的转场换成了照片自己的。
///
/// ```swift
/// let browser = MDPhotoBrowserController(photos: photos, initialIndex: indexPath.item)
/// browser.delegate = self
/// present(browser, animated: true)
/// ```
@MainActor
public final class MDPhotoBrowserController: UIViewController {
    public weak var delegate: (any MDPhotoBrowserDelegate)?

    /// 打开着时也能改（比如换一组操作）。
    public var configuration: MDPhotoBrowserConfiguration {
        didSet { render() }
    }

    /// 浏览的照片。打开着时换一组，浏览器停在原来那张上，它没了就停在原来的位置。用户在浏览器里删掉的不在这里面。
    public var photos: [MDPhoto] {
        get { browser.photos }
        set {
            input = newValue
            if isViewLoaded { render() } else { browser.replacePhotos(newValue) }
        }
    }

    /// 当前这张的位置（从 0 数）。
    public var currentIndex: Int { browser.index }
    public var currentPhoto: MDPhoto? { browser.currentPhoto }
    /// 控件此刻看不看得见。
    public var controlsVisible: Bool { browser.chromeVisible }

    private let browser: BrowserController
    private var input: [MDPhoto]
    private var host: UIHostingController<BrowserRoot<EmptyView>>?
    private var hiddenSource: (view: UIView, alpha: CGFloat)?
    private let transition = InstantTransition()

    public init(photos: [MDPhoto], initialIndex: Int = 0, configuration: MDPhotoBrowserConfiguration = MDPhotoBrowserConfiguration()) {
        input = photos
        self.configuration = configuration
        browser = BrowserController(photos: photos, index: initialIndex, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = true
        transitioningDelegate = transition
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /* ---------- 操作 ---------- */

    /// 翻到第几张。
    public func jump(to index: Int, animated: Bool = true) {
        browser.page(to: index, animated: animated)
    }

    public func next() {
        browser.page(to: browser.index + 1)
    }

    public func previous() {
        browser.page(to: browser.index - 1)
    }

    public func setControlsVisible(_ visible: Bool) {
        browser.setControlsVisible(visible)
    }

    /// 走一遍删除（确认、`delegate` 同意）。
    public func deleteCurrentPhoto() {
        browser.requestDelete()
    }

    /// 关掉：照片缩回缩略图，动画走完再从界面上拿掉。
    public func dismissBrowser() {
        browser.close()
    }

    /* ---------- 视图 ---------- */

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let host = UIHostingController(rootView: root())
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        self.host = host
    }

    override public var childForStatusBarHidden: UIViewController? { host }
    override public var childForStatusBarStyle: UIViewController? { host }
    override public var childForHomeIndicatorAutoHidden: UIViewController? { host }

    private func render() {
        host?.rootView = root()
    }

    private func root() -> BrowserRoot<EmptyView> {
        BrowserRoot(controller: browser, configuration: configuration, photos: input, handlers: handlers) { _ in EmptyView() }
    }

    private var handlers: BrowserController.Handlers {
        var handlers = BrowserController.Handlers()
        handlers.onDelete = { [weak self] photo in
            guard let self, let delegate else { return true }
            let index = browser.photos.firstIndex { $0.id == photo.id } ?? browser.index
            return await delegate.photoBrowser(self, shouldDelete: photo, at: index)
        }
        handlers.onIndexChange = { [weak self] _ in
            guard let self else { return }
            delegate?.photoBrowser(self, didShowPhotoAt: browser.index)
        }
        handlers.onControlsVisibilityChange = { [weak self] visible in
            guard let self else { return }
            delegate?.photoBrowser(self, didChangeControlsVisibility: visible)
        }
        handlers.onWillDismiss = { [weak self] _ in
            guard let self else { return }
            delegate?.photoBrowser(self, willDismissAt: browser.index)
        }
        handlers.sourceProvider = { [weak self] id in self?.source(for: id) }
        handlers.hideSource = { [weak self] id in self?.hideSource(id) }
        handlers.onFinish = { [weak self] _ in
            guard let self else { return }
            let index = browser.index
            dismiss(animated: false) { [weak self] in
                guard let self else { return }
                delegate?.photoBrowser(self, didDismissAt: index)
            }
        }
        return handlers
    }

    /* ---------- 缩略图 ---------- */

    private func sourceView(for id: MDPhoto.ID) -> UIView? {
        guard let index = browser.photos.firstIndex(where: { $0.id == id }),
              let view = delegate?.photoBrowser(self, sourceViewForPhotoAt: index),
              view.window != nil else { return nil }
        return view
    }

    private func source(for id: MDPhoto.ID) -> BrowserController.SourceInfo? {
        guard let view = sourceView(for: id) else { return nil }
        return BrowserController.SourceInfo(frame: view.convert(view.bounds, to: nil), cornerRadius: view.layer.cornerRadius)
    }

    private func hideSource(_ id: MDPhoto.ID?) {
        if let hidden = hiddenSource {
            hidden.view.alpha = hidden.alpha
            hiddenSource = nil
        }
        guard let id, let view = sourceView(for: id) else { return }
        hiddenSource = (view, view.alpha)
        view.alpha = 0
    }
}

/// 浏览器报的事、要的东西。都有默认实现，只写要的。
@MainActor
public protocol MDPhotoBrowserDelegate: AnyObject {
    /// 第 `index` 张照片的缩略图视图（在界面上的话）：打开、关上时照片从它放大出来、缩回去，浏览这张时它藏着。
    /// 圆角取它的 `layer.cornerRadius`。
    func photoBrowser(_ browser: MDPhotoBrowserController, sourceViewForPhotoAt index: Int) -> UIView?
    /// 翻到了第 `index` 张（滑动、按钮、键盘、删除之后都算）。
    func photoBrowser(_ browser: MDPhotoBrowserController, didShowPhotoAt index: Int)
    /// 用户要删这张：返回 true 才从浏览器里拿掉。默认 true。
    func photoBrowser(_ browser: MDPhotoBrowserController, shouldDelete photo: MDPhoto, at index: Int) async -> Bool
    func photoBrowser(_ browser: MDPhotoBrowserController, didChangeControlsVisibility visible: Bool)
    /// 要关了（动画还没走）。
    func photoBrowser(_ browser: MDPhotoBrowserController, willDismissAt index: Int)
    /// 关完了，已经从界面上拿掉。
    func photoBrowser(_ browser: MDPhotoBrowserController, didDismissAt index: Int)
}

public extension MDPhotoBrowserDelegate {
    func photoBrowser(_ browser: MDPhotoBrowserController, sourceViewForPhotoAt index: Int) -> UIView? { nil }
    func photoBrowser(_ browser: MDPhotoBrowserController, didShowPhotoAt index: Int) {}
    func photoBrowser(_ browser: MDPhotoBrowserController, shouldDelete photo: MDPhoto, at index: Int) async -> Bool { true }
    func photoBrowser(_ browser: MDPhotoBrowserController, didChangeControlsVisibility visible: Bool) {}
    func photoBrowser(_ browser: MDPhotoBrowserController, willDismissAt index: Int) {}
    func photoBrowser(_ browser: MDPhotoBrowserController, didDismissAt index: Int) {}
}

/// 没有动画的弹出、收起：开关的动画由浏览器自己做（照片从缩略图飞出来、飞回去）。
@MainActor
private final class InstantTransition: NSObject, UIViewControllerTransitioningDelegate, UIViewControllerAnimatedTransitioning {
    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        self
    }

    func animationController(forDismissed dismissed: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        self
    }

    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        0
    }

    func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        if let view = transitionContext.view(forKey: .to), let controller = transitionContext.viewController(forKey: .to) {
            view.frame = transitionContext.finalFrame(for: controller)
            transitionContext.containerView.addSubview(view)
        }
        if let from = transitionContext.viewController(forKey: .from), from.isBeingDismissed {
            transitionContext.view(forKey: .from)?.removeFromSuperview()
        }
        transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
    }
}
