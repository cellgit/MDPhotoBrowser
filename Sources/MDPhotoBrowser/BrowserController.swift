import SwiftUI
import UIKit

/// 一次浏览的全部状态：哪几张、看到第几张、控件显不显示、正在开 / 关 / 拖，以及开关时飞着的那张图。
///
/// SwiftUI 的界面（`BrowserRoot`）读它，UIKit 的翻页（`PagerView`）把手势报给它。只在主线程。
@MainActor
@Observable
final class BrowserController: Identifiable {
    enum Phase {
        /// 正在从缩略图放大出来。
        case opening
        case open
        /// 手指正拖着照片（要关还没关）。
        case dragging
        /// 正在缩回缩略图 / 淡出。
        case closing
        case closed
    }

    /// 开、关时飞着的那张图（窗口坐标）。它在飞的时候翻页那一层是藏着的。
    struct Flight {
        var image: UIImage
        var frame: CGRect
        var cornerRadius: CGFloat
        /// 图比框大时露哪一部分：照着缩略图的裁法，缩略图那一头和格子一模一样。
        var alignment: Alignment = .center
        var opacity: Double = 1
    }

    /// 浏览器报给外面的事、向外面要的东西。外面每次刷新都交一份新的（`BrowserRoot` 的 init），所以闭包里拿到的总是最新的状态。
    struct Handlers {
        /// 删这张：返回 true 才从浏览器里拿掉。没给就直接拿掉。
        var onDelete: (@MainActor (MDPhoto) async -> Bool)?
        var onIndexChange: (@MainActor (MDPhoto) -> Void)?
        var onControlsVisibilityChange: (@MainActor (Bool) -> Void)?
        var onWillDismiss: (@MainActor (MDPhoto?) -> Void)?
        /// 关的动画走完了：把浏览器从界面上拿掉。
        var onFinish: (@MainActor (MDPhoto?) -> Void)?
        /// 一张照片的缩略图在窗口里的哪儿、圆角多大；没登记或不在界面上是 nil。
        var sourceProvider: (@MainActor (MDPhoto.ID) -> SourceInfo?)?
        /// 把这张的缩略图藏起来（nil 是都不藏）：浏览时它的位置空着，往下拖时看得到照片是从哪儿来的。
        var hideSource: (@MainActor (MDPhoto.ID?) -> Void)?
    }

    struct SourceInfo {
        var frame: CGRect
        var cornerRadius: CGFloat
        var alignment: Alignment = .center
    }

    let id = UUID()
    private(set) var photos: [MDPhoto]
    private(set) var index: Int
    private(set) var controlsVisible = true
    private(set) var phase: Phase = .opening
    var backgroundOpacity: Double = 0
    var pagerOpacity: Double = 0
    var pagerScale: CGFloat = 1
    var flight: Flight?
    /// 当前这页上画着的图（分享、操作要用）；还没取到是 nil。
    private(set) var currentImage: UIImage?
    /// 等用户确认要删的那张。
    var pendingDeletion: MDPhoto?

    /* ---------- 外面交进来的（不参与界面刷新：界面从 `BrowserRoot` 的参数读配置） ---------- */

    @ObservationIgnored var configuration: MDPhotoBrowserConfiguration
    @ObservationIgnored var handlers = Handlers()
    @ObservationIgnored weak var pager: PagerView?
    @ObservationIgnored var containerSize: CGSize = .zero
    @ObservationIgnored private var autoHideTask: Task<Void, Never>?
    @ObservationIgnored private var openTask: Task<Void, Never>?

    init(photos: [MDPhoto], index: Int, configuration: MDPhotoBrowserConfiguration) {
        self.photos = photos
        self.index = photos.isEmpty ? 0 : min(max(index, 0), photos.count - 1)
        self.configuration = configuration
    }

    var currentPhoto: MDPhoto? {
        photos.indices.contains(index) ? photos[index] : nil
    }

    /// 控件看得见：用户没藏、浏览器完全打开了、手指没在拖。
    var chromeVisible: Bool {
        controlsVisible && phase == .open
    }

    var context: MDPhotoBrowserContext? {
        guard let photo = currentPhoto else { return nil }
        return MDPhotoBrowserContext(photo: photo, index: index, count: photos.count, image: currentImage,
                                     controlsVisible: chromeVisible, proxy: MDPhotoBrowserProxy(controller: self))
    }

    /// 不用等的那一张：原图在缓存里就用原图，否则用垫着的那张。
    func immediateImage(for photo: MDPhoto) -> UIImage? {
        configuration.loader.cachedImage(for: photo.source)
            ?? photo.placeholder.flatMap { configuration.loader.cachedImage(for: $0) }
    }

    /* ---------- 开、关 ---------- */

    private var openAnimation: Animation {
        configuration.bouncesOnPresent ? .bouncy(duration: 0.46, extraBounce: 0.08) : .smooth(duration: 0.36)
    }

    /// 界面第一次出现：有缩略图、手上有图，就从缩略图里放大出来；否则整个淡入。
    ///
    /// 手上没有能马上画的图时（内存里只有裁成方块的缩略图），先等垫着的那张最多 `firstImageWait`：
    /// 从磁盘解一张小图只要几十毫秒，等到了照样从缩略图里飞出来，等不到才原地淡入。等的时候界面是透明的。
    func open(in size: CGSize) {
        containerSize = size
        guard phase == .opening, openTask == nil, let photo = currentPhoto else { return }
        if let image = immediateImage(for: photo) {
            start(photo, image: image)
            return
        }
        let loader = configuration.loader
        let source = photo.placeholder ?? photo.source
        openTask = Task { [weak self] in
            let image = await withTaskGroup(of: UIImage?.self) { group in
                group.addTask { try? await loader.image(for: source) }
                group.addTask {
                    try? await Task.sleep(for: Self.firstImageWait)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let self, phase == .opening else { return }
            start(photo, image: image)
        }
    }

    /// 打开时最多等垫着的那张多久。
    nonisolated static let firstImageWait: Duration = .milliseconds(250)

    private func start(_ photo: MDPhoto, image: UIImage?) {
        let screen = CGRect(origin: .zero, size: containerSize)
        if let image,
           let source = handlers.sourceProvider?(photo.id),
           ZoomGeometry.isVisible(source.frame, in: screen) {
            let target = ZoomGeometry.fittedFrame(image: image.size, in: screen, padding: configuration.paddingValue,
                                                  fitsLongPhotosToWidth: configuration.fitsLongPhotosToWidth)
            flight = Flight(image: image, frame: source.frame, cornerRadius: source.cornerRadius, alignment: source.alignment)
            currentImage = image
            // 飞着的图先在缩略图的位置上画一帧，下一轮再藏缩略图、开始飞。缩略图和浏览器是两层，不在同一帧更新：
            // 同一轮藏的话，缩略图会先空一帧。
            DispatchQueue.main.async { [self] in
                handlers.hideSource?(photo.id)
                withAnimation(openAnimation) {
                    flight?.frame = target
                    flight?.cornerRadius = 0
                    backgroundOpacity = 1
                } completion: { [self] in
                    pagerOpacity = 1
                    flight = nil
                    if phase == .opening { phase = .open }
                    scheduleAutoHide()
                }
            }
        } else {
            handlers.hideSource?(photo.id)
            pagerScale = 0.92
            withAnimation(.smooth(duration: 0.26)) {
                backgroundOpacity = 1
                pagerOpacity = 1
                pagerScale = 1
            } completion: { [self] in
                if phase == .opening { phase = .open }
                scheduleAutoHide()
            }
        }
    }

    /// 关掉：照片缩回它的缩略图（在屏幕上的话），否则原地缩小淡出。
    func close() {
        guard phase != .closing, phase != .closed else { return }
        openTask?.cancel()
        let photo = currentPhoto
        handlers.onWillDismiss?(photo)
        phase = .closing
        cancelAutoHide()
        let screen = CGRect(origin: .zero, size: containerSize)
        let source = photo.flatMap { handlers.sourceProvider?($0.id) }.flatMap { ZoomGeometry.isVisible($0.frame, in: screen) ? $0 : nil }
        guard let visible = pager?.visibleImage() else {
            withAnimation(.smooth(duration: 0.22)) {
                pagerOpacity = 0
                backgroundOpacity = 0
            } completion: { [self] in finish() }
            return
        }
        flight = Flight(image: visible.image, frame: visible.frame, cornerRadius: visible.cornerRadius,
                        alignment: source?.alignment ?? .center)
        pagerOpacity = 0
        if let photo { handlers.hideSource?(photo.id) }
        DispatchQueue.main.async { [self] in
            withAnimation(.smooth(duration: 0.32)) {
                if let source {
                    flight?.frame = source.frame
                    flight?.cornerRadius = source.cornerRadius
                } else {
                    let frame = visible.frame
                    flight?.frame = frame.insetBy(dx: frame.width * 0.08, dy: frame.height * 0.08)
                    flight?.opacity = 0
                }
                backgroundOpacity = 0
            } completion: { [self] in finish() }
        }
    }

    /// 缩略图先露出来（飞着的图正好盖在它上面），下一轮再拿掉飞着的图和浏览器：同一轮拿掉的话，两层不在同一帧更新，
    /// 缩略图会空一帧。
    private func finish() {
        handlers.hideSource?(nil)
        DispatchQueue.main.async { [self] in
            flight = nil
            phase = .closed
            handlers.onFinish?(currentPhoto)
        }
    }

    /* ---------- 往下拖 ---------- */

    func dragBegan() {
        guard phase == .open else { return }
        phase = .dragging
        cancelAutoHide()
    }

    func dragChanged(progress: CGFloat) {
        guard phase == .dragging else { return }
        backgroundOpacity = Double(1 - min(max(progress, 0), 1))
    }

    func dragEnded(dismiss: Bool) {
        guard phase == .dragging else { return }
        if dismiss {
            close()
        } else {
            phase = .open
            withAnimation(.smooth(duration: 0.25)) { backgroundOpacity = 1 }
            scheduleAutoHide()
        }
    }

    /* ---------- 点、控件 ---------- */

    func singleTap() {
        guard phase == .open else { return }
        switch configuration.singleTapAction {
        case .toggleControls: setControlsVisible(!controlsVisible)
        case .dismiss: close()
        case .none: break
        }
    }

    func setControlsVisible(_ visible: Bool) {
        guard controlsVisible != visible else { return }
        withAnimation(.easeOut(duration: 0.2)) { controlsVisible = visible }
        handlers.onControlsVisibilityChange?(visible)
        scheduleAutoHide()
    }

    /// 碰了一下屏幕：重新计时自动隐藏。
    func userInteracted() {
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        guard let delay = configuration.autoHideControlsAfter, controlsVisible, phase == .open else { return }
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.setControlsVisible(false)
        }
    }

    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    /* ---------- 翻页 ---------- */

    /// 翻页那一层报：现在停在第几张了。
    func pagerDidShow(index newIndex: Int) {
        guard photos.indices.contains(newIndex), newIndex != index else { return }
        index = newIndex
        currentImage = pager?.image(at: newIndex)
        if phase == .open || phase == .dragging { handlers.hideSource?(photos[newIndex].id) }
        handlers.onIndexChange?(photos[newIndex])
        scheduleAutoHide()
    }

    /// 翻页那一层报：第几张的图到了。
    func pagerDidLoad(_ image: UIImage, at loadedIndex: Int) {
        if loadedIndex == index { currentImage = image }
    }

    /// 翻到第几张（按钮、键盘、App 调用）。
    func page(to newIndex: Int, animated: Bool = true) {
        guard photos.indices.contains(newIndex), newIndex != index else { return }
        pager?.scroll(to: newIndex, animated: animated)
        if !animated || pager == nil { pagerDidShow(index: newIndex) }
    }

    /// 外面换了一组照片（删了、加了）：停在原来那张上，它没了就停在原来的位置。
    func replacePhotos(_ newPhotos: [MDPhoto]) {
        guard newPhotos.map(\.id) != photos.map(\.id) else {
            photos = newPhotos
            return
        }
        let currentID = currentPhoto?.id
        photos = newPhotos
        guard !newPhotos.isEmpty else {
            close()
            return
        }
        if let currentID, let kept = newPhotos.firstIndex(where: { $0.id == currentID }) {
            index = kept
        } else {
            index = min(index, newPhotos.count - 1)
            handlers.onIndexChange?(newPhotos[index])
        }
        currentImage = pager?.image(at: index)
        if phase == .open || phase == .dragging { handlers.hideSource?(newPhotos[index].id) }
    }

    /* ---------- 删除、分享 ---------- */

    func requestDelete() {
        guard let photo = currentPhoto, phase == .open else { return }
        if configuration.confirmsDeletion {
            pendingDeletion = photo
        } else {
            Task { await delete(photo) }
        }
    }

    /// 删这张：问 `onDelete`，它同意（或者没给）才从浏览器里拿掉。删到一张不剩就关掉。
    func delete(_ photo: MDPhoto) async {
        let approved = await handlers.onDelete?(photo) ?? true
        guard approved, let removed = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        var rest = photos
        rest.remove(at: removed)
        guard !rest.isEmpty else {
            photos = rest
            close()
            return
        }
        photos = rest
        index = min(removed, rest.count - 1)
        currentImage = nil
        handlers.onIndexChange?(rest[index])
        handlers.hideSource?(rest[index].id)
    }

    func share() {
        guard let image = currentImage else { return }
        var items: [Any] = [image]
        if configuration.sharesCaption, let caption = currentPhoto?.caption, !caption.isEmpty { items.append(caption) }
        if let extra = configuration.shareExtraText, !extra.isEmpty { items.append(extra) }
        pager?.presentShareSheet(items: items)
    }
}

/// 自己加的界面、操作拿到的：当前这张、第几张、一共几张、手上的图，以及能对浏览器做什么（`proxy`）。
@MainActor
public struct MDPhotoBrowserContext {
    public let photo: MDPhoto
    /// 从 0 数。
    public let index: Int
    public let count: Int
    /// 当前页上画着的图；还没取到是 nil。
    public let image: UIImage?
    /// 控件此刻看不看得见（自己加的界面跟着显隐）。
    public let controlsVisible: Bool
    public let proxy: MDPhotoBrowserProxy
}

/// 对浏览器做事：关掉、翻页、显隐控件、删除、分享。
@MainActor
public struct MDPhotoBrowserProxy {
    let controller: BrowserController

    /// 关掉（照片缩回缩略图）。
    public func dismiss() {
        controller.close()
    }

    public func page(to index: Int, animated: Bool = true) {
        controller.page(to: index, animated: animated)
    }

    public func next() {
        controller.page(to: controller.index + 1)
    }

    public func previous() {
        controller.page(to: controller.index - 1)
    }

    public func setControlsVisible(_ visible: Bool) {
        controller.setControlsVisible(visible)
    }

    /// 走一遍删除（确认、`onDelete`）。
    public func deleteCurrentPhoto() {
        controller.requestDelete()
    }

    /// 打开系统的分享面板。
    public func shareCurrentPhoto() {
        controller.share()
    }
}
