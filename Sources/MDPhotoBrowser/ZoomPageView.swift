import SwiftUI
import UIKit

/// 一页：一张能缩放的图（`UIScrollView` 自己的缩放：双指捏、松手回弹、放大后拖着看）。
///
/// - 缩放 1 倍 = 整张放下（长图开了「铺满宽」时是铺满宽）。所以先画垫着的小图、原图到了再换，位置一点不动，
///   只是最大能放大到多少变了。
/// - 双击：没放大就以点的地方为中心放大（点在黑边上也行，见 `zoomsOnDoubleTapOutsideImage`），放大了就还原。
/// - 单击：交给浏览器（显隐控件或关掉），要等双击判断完。
/// - 没放大时上下拖：整页跟着手指走、慢慢缩小，松手时拖得够远或甩得够快就关掉，否则弹回来。
///   长图能上下滚，只有滚到顶再往下拖、滚到底再往上拖才算。
@MainActor
final class ZoomPageView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    weak var pager: PagerView?
    var pageIndex: Int?

    private(set) var photo: MDPhoto?
    private var configuration = MDPhotoBrowserConfiguration()
    private let indicator = UIActivityIndicatorView(style: .large)
    private let failure = FailureView()
    private var loadTask: Task<Void, Never>?
    private var placeholderTask: Task<Void, Never>?
    private var spinnerTask: Task<Void, Never>?
    private var showsFullImage = false
    /// 双击放到几倍（相对整张放下）。
    private var doubleTapScale: CGFloat = 2.5
    private var laidOutSize: CGSize = .zero
    private let singleTap = UITapGestureRecognizer()
    private let doubleTap = UITapGestureRecognizer()
    private let dismissPan = UIPanGestureRecognizer()

    init() {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        bouncesZoom = true
        scrollsToTop = false
        minimumZoomScale = 1
        maximumZoomScale = 1

        imageView.contentMode = .scaleToFill
        imageView.clipsToBounds = true
        imageView.accessibilityIgnoresInvertColors = true
        addSubview(imageView)

        indicator.hidesWhenStopped = true
        addSubview(indicator)
        failure.isHidden = true
        failure.onRetry = { [weak self] in self?.retry() }
        addSubview(failure)

        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(handleDoubleTap(_:)))
        addGestureRecognizer(doubleTap)
        singleTap.addTarget(self, action: #selector(handleSingleTap(_:)))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
        dismissPan.addTarget(self, action: #selector(handleDismissPan(_:)))
        dismissPan.maximumNumberOfTouches = 1
        addGestureRecognizer(dismissPan)
        // 没放大时竖着拖先问「往下拖关掉」；它不要（放大了、横着拖）自己的滚动才动。
        panGestureRecognizer.require(toFail: dismissPan)

        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /* ---------- 换照片 ---------- */

    func configure(photo: MDPhoto, configuration: MDPhotoBrowserConfiguration) {
        self.photo = photo
        apply(configuration)
        failure.isHidden = true
        showsFullImage = false
        if let full = configuration.loader.cachedImage(for: photo.source) {
            display(full, full: true)
            return
        }
        if let placeholder = photo.placeholder.flatMap({ configuration.loader.cachedImage(for: $0) }) {
            display(placeholder, full: false)
        } else {
            imageView.image = nil
            laidOutSize = .zero
            setNeedsLayout()
        }
        load()
    }

    /// 同一张照片换了说明或配置：不重新取图。
    func update(photo: MDPhoto, configuration: MDPhotoBrowserConfiguration) {
        self.photo = photo
        apply(configuration)
    }

    private func apply(_ configuration: MDPhotoBrowserConfiguration) {
        self.configuration = configuration
        showsHorizontalScrollIndicator = configuration.showsScrollIndicators
        showsVerticalScrollIndicator = configuration.showsScrollIndicators
        indicator.color = UIColor(configuration.indicatorColor)
        failure.apply(tint: UIColor(configuration.foregroundColor), message: configuration.labels.loadFailed,
                      retry: configuration.labels.retry)
        updateAccessibility()
    }

    private func updateAccessibility() {
        guard let photo, let pageIndex, let pager else { return }
        let position = configuration.labels.position(pageIndex + 1, pager.photoCount)
        if let label = photo.accessibilityLabel ?? photo.caption, !label.isEmpty {
            accessibilityLabel = label
            accessibilityValue = position
        } else {
            accessibilityLabel = position
            accessibilityValue = nil
        }
    }

    private func load() {
        guard let photo else { return }
        let loader = configuration.loader
        loadTask?.cancel()
        placeholderTask?.cancel()
        scheduleSpinner()
        // 手上什么都没有：垫着的那张和原图一起取，垫着的先到就先画它。
        if imageView.image == nil, let placeholder = photo.placeholder {
            placeholderTask = Task { [weak self] in
                guard let image = try? await loader.image(for: placeholder), !Task.isCancelled else { return }
                guard let self, !self.showsFullImage, self.photo?.id == photo.id else { return }
                self.display(image, full: false)
            }
        }
        loadTask = Task { [weak self] in
            do {
                let image = try await loader.image(for: photo.source)
                guard !Task.isCancelled, let self, self.photo?.id == photo.id else { return }
                self.display(image, full: true)
            } catch {
                guard !Task.isCancelled, let self, self.photo?.id == photo.id else { return }
                self.showFailure()
            }
        }
    }

    private func retry() {
        failure.isHidden = true
        load()
    }

    /// 慢的时候才转圈：快的（几百毫秒内到的）不闪这一下。
    private func scheduleSpinner() {
        spinnerTask?.cancel()
        spinnerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, !self.showsFullImage, self.failure.isHidden else { return }
            self.indicator.startAnimating()
        }
    }

    private func display(_ image: UIImage, full: Bool) {
        let previous = imageView.image
        imageView.image = image
        if full {
            showsFullImage = true
            spinnerTask?.cancel()
            placeholderTask?.cancel()
            indicator.stopAnimating()
            failure.isHidden = true
        }
        // 同一个宽高比（垫着的小图换成原图）且没放大：位置不动，只更新能放大到多少。
        let sameShape = previous.map { abs($0.size.width / max($0.size.height, 1) - image.size.width / max(image.size.height, 1)) < 0.01 } ?? false
        layoutImage(resetZoom: !sameShape || zoomScale <= minimumZoomScale + 0.001)
        if full { pager?.pageDidLoad(self, image: image) }
    }

    private func showFailure() {
        spinnerTask?.cancel()
        indicator.stopAnimating()
        // 垫着的图还在就留着它，只是不能放大；什么都没有才出错误。
        guard imageView.image == nil else { return }
        failure.isHidden = false
        setNeedsLayout()
    }

    func prepareForReuse() {
        loadTask?.cancel()
        placeholderTask?.cancel()
        spinnerTask?.cancel()
        photo = nil
        pageIndex = nil
        showsFullImage = false
        transform = .identity
        zoomScale = 1
        imageView.image = nil
        indicator.stopAnimating()
        failure.isHidden = true
        laidOutSize = .zero
    }

    /* ---------- 排版 ---------- */

    func boundsDidChange() {
        laidOutSize = .zero
        setNeedsLayout()
    }

    func resetZoom(animated: Bool) {
        guard zoomScale != minimumZoomScale else { return }
        setZoomScale(minimumZoomScale, animated: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if laidOutSize != bounds.size, bounds.width > 0, transform.isIdentity {
            laidOutSize = bounds.size
            layoutImage(resetZoom: true)
        }
        centerImage()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        indicator.center = center
        failure.frame = CGRect(x: bounds.minX + 24, y: bounds.midY - 80, width: bounds.width - 48, height: 160)
    }

    /// 按图和页面的大小算：整张放下有多大（缩放 1 倍），最多能放到几倍，双击放到几倍。
    private func layoutImage(resetZoom: Bool) {
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else {
            minimumZoomScale = 1
            maximumZoomScale = 1
            zoomScale = 1
            imageView.frame = .zero
            contentSize = .zero
            updateAccessibility()
            return
        }
        let screenScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let scales = ZoomGeometry.scales(
            image: image.size, imageScale: image.scale, bounds: bounds.size, padding: configuration.paddingValue,
            fitsLongPhotosToWidth: configuration.fitsLongPhotosToWidth, maximum: configuration.maximumZoomScale,
            screenScale: screenScale
        )
        let fitted = ZoomGeometry.fittedSize(image: image.size, scale: scales.minimum,
                                             room: ZoomGeometry.available(bounds.size, padding: configuration.paddingValue),
                                             screenScale: screenScale)
        minimumZoomScale = 1
        maximumZoomScale = max(scales.maximum / scales.minimum, 1)
        doubleTapScale = max(scales.doubleTap / scales.minimum, 1)
        if resetZoom {
            zoomScale = 1
            imageView.transform = .identity
            imageView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
            centerImage()
            // 长图从顶上看起。
            contentOffset = .zero
        }
        updateAccessibility()
    }

    /// 图比页面小的那一边居中（Apple PhotoScroller 的做法：放大缩小时每次排版都摆一次）。
    private func centerImage() {
        var frame = imageView.frame
        frame.origin.x = frame.width < bounds.width ? ((bounds.width - frame.width) / 2).rounded() : 0
        frame.origin.y = frame.height < bounds.height ? ((bounds.height - frame.height) / 2).rounded() : 0
        if imageView.frame != frame { imageView.frame = frame }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView.image == nil ? nil : imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        setNeedsLayout()
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        pager?.pageDidInteract(self)
    }

    /* ---------- 点 ---------- */

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        pager?.pageDidSingleTap(self)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard configuration.doubleTapToZoom, imageView.image != nil else { return }
        pager?.pageDidInteract(self)
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let imageBounds = imageView.bounds
        var point = gesture.location(in: imageView)
        if !imageBounds.contains(point) {
            guard configuration.zoomsOnDoubleTapOutsideImage else { return }
            point = CGPoint(x: min(max(point.x, 0), imageBounds.width), y: min(max(point.y, 0), imageBounds.height))
        }
        zoom(to: ZoomGeometry.zoomRect(scale: doubleTapScale, center: point, bounds: bounds.size), animated: true)
    }

    /* ---------- 往下拖关掉 ---------- */

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        guard pager?.canDragToDismiss == true, zoomScale <= minimumZoomScale + 0.01 else { return false }
        let velocity = dismissPan.velocity(in: self)
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        // 能上下滚的长图：滚到顶往下拖、滚到底往上拖才是关。
        if contentSize.height > bounds.height + 1 {
            let atTop = contentOffset.y <= 0.5
            let atBottom = contentOffset.y >= contentSize.height - bounds.height - 0.5
            return (velocity.y > 0 && atTop) || (velocity.y < 0 && atBottom)
        }
        return true
    }

    @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: superview)
        switch pan.state {
        case .began:
            pager?.pageDragBegan(self)
        case .changed:
            let progress = ZoomGeometry.dismissProgress(translation: translation.y, height: bounds.height)
            let scale = 1 - progress * 0.3
            transform = CGAffineTransform(translationX: translation.x, y: translation.y).scaledBy(x: scale, y: scale)
            pager?.pageDragChanged(self, progress: progress)
        case .ended, .cancelled, .failed:
            let velocity = pan.velocity(in: superview)
            let dismiss = pan.state == .ended && ZoomGeometry.shouldDismiss(translation: translation.y, velocity: velocity.y)
            if !dismiss {
                UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0,
                               options: [.allowUserInteraction, .beginFromCurrentState]) {
                    self.transform = .identity
                }
            }
            pager?.pageDragEnded(self, dismiss: dismiss)
        default:
            break
        }
    }
}

/// 取不到时的那一块：一个图标、一句话、一个「再试一次」。
@MainActor
private final class FailureView: UIView {
    var onRetry: (() -> Void)?
    private let icon = UIImageView(image: UIImage(systemName: "photo.badge.exclamationmark"))
    private let label = UILabel()
    private let button = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .light)
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center
        var config = UIButton.Configuration.bordered()
        config.cornerStyle = .capsule
        button.configuration = config
        button.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [icon, label, button])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(tint: UIColor, message: String, retry: String) {
        icon.tintColor = tint.withAlphaComponent(0.7)
        label.textColor = tint.withAlphaComponent(0.8)
        label.text = message
        var config = button.configuration ?? .bordered()
        config.title = retry
        config.baseForegroundColor = tint
        config.baseBackgroundColor = tint.withAlphaComponent(0.16)
        button.configuration = config
    }
}
