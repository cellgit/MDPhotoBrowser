import SwiftUI

/// 浏览器的样子和行为。都有默认值，只改要改的：
///
/// ```swift
/// var configuration = MDPhotoBrowserConfiguration()
/// configuration.showsDeleteButton = true
/// configuration.singleTapAction = .dismiss
/// ```
public struct MDPhotoBrowserConfiguration {
    /* ---------- 控件 ---------- */

    /// 左上角的关闭（×）。
    public var showsCloseButton = true
    /// 顶上中间的「3 / 9」。
    public var showsCounter = true
    /// 右上角的删除；删之前问一句（`confirmsDeletion`），删不删由 `onDelete` 说了算。
    public var showsDeleteButton = false
    public var confirmsDeletion = true
    /// 关闭放右边、删除放左边。
    public var swapsCloseAndDeleteButtons = false
    /// 分享（系统的分享面板，能存到相册）。默认关：打开之前宿主 App 的 Info.plist 要有
    /// `NSPhotoLibraryAddUsageDescription`，不然用户点「存储图像」时系统会让 App 崩掉。
    public var showsShareButton = false
    /// 分享时连说明一起。
    public var sharesCaption = true
    /// 分享时再附一句（比如 App 的名字、链接）。
    public var shareExtraText: String?
    /// 自己加的操作：放在顶栏（`.toolbar`）或「更多」菜单里（`.menu`）。
    public var actions: [MDPhotoBrowserAction] = []
    /// 两边的上一张 / 下一张（iPad、Mac 上有用）。
    public var showsPageArrows = false
    /// 照片下面的说明（`MDPhoto.caption`）。
    public var showsCaptions = true
    public var caption = CaptionStyle()
    /// 控件显示时露出状态栏。默认浏览时不显示状态栏。
    public var showsStatusBar = false
    /// 放大后拖动时的滚动条。
    public var showsScrollIndicators = false
    /// 不碰屏幕多久之后自己把控件藏起来；nil 是不藏。
    public var autoHideControlsAfter: Duration?
    /// 顶栏按钮的底：玻璃（iOS 26 的 Liquid Glass，之前是深色材质）或者没有底。
    public var chromeStyle: ChromeStyle = .glass

    /* ---------- 手势 ---------- */

    /// 点一下：显示 / 隐藏控件、关掉，或者什么都不做。
    public var singleTapAction: SingleTapAction = .toggleControls
    /// 双击放大 / 还原。
    public var doubleTapToZoom = true
    /// 双击图外面的黑边也放大（放大的中心收到图上离点最近的地方）。
    public var zoomsOnDoubleTapOutsideImage = true
    /// 往上或往下拖着关掉。
    public var swipeToDismiss = true

    /* ---------- 缩放与版式 ---------- */

    /// 最多放到整张放下时的几倍；nil 按清晰度自动算（至少 3 倍）。
    public var maximumZoomScale: CGFloat?
    /// 长图（比屏幕瘦得多的竖图）按宽铺满，从顶上看起。
    public var fitsLongPhotosToWidth = false
    /// 两页之间的空隙。
    public var pageSpacing: CGFloat = 20
    /// 图和屏幕边之间留的白。
    public var imagePadding = EdgeInsets()

    /* ---------- 外观 ---------- */

    public var backgroundColor: Color = .black
    /// 字和图标。
    public var foregroundColor: Color = .white
    /// 转圈的颜色。
    public var indicatorColor: Color = .white
    /// 打开时弹一下（转场用弹簧，略过头再回来）。
    public var bouncesOnPresent = false

    /* ---------- 加载 ---------- */

    public var loader: MDImageLoader = .shared
    /// 当前这张前后各预先取几张。
    public var preloadDistance = 1

    /* ---------- 安全 ---------- */

    /// 截屏、录屏时图是空的（只在真机上有效，模拟器上截屏照样有图）。
    public var protectsFromScreenshots = false

    /* ---------- 文案 ---------- */

    /// 按钮、读屏的字。默认跟着系统语言（英、简、繁、日、韩），App 可以换成自己的。
    public var labels = MDPhotoBrowserLabels()

    public init() {}

    /// 点一下照片做什么。
    public enum SingleTapAction: Sendable {
        case toggleControls
        case dismiss
        case none
    }

    /// 顶栏按钮的样子。
    public enum ChromeStyle: Sendable {
        /// 圆形的玻璃底（iOS 26 起是系统的 Liquid Glass）：压在亮的照片上也看得清。
        case glass
        /// 只有图标，带一点阴影。
        case plain
    }

    /// 说明的样子。
    public struct CaptionStyle {
        public var font: Font = .body
        public var color: Color = .white
        public var alignment: TextAlignment = .leading
        public var lineLimit: Int? = 3
        /// 说明后面的底；nil 是从透明到黑的渐变（压在照片上也读得清）。
        public var background: Color?

        public init() {}
    }

    var paddingValue: EdgeInsetsValue {
        EdgeInsetsValue(top: imagePadding.top, leading: imagePadding.leading, bottom: imagePadding.bottom, trailing: imagePadding.trailing)
    }
}

/// 一个自己加的操作：标题、图标、放在哪，点了做什么（拿到当前这张照片和浏览器）。
public struct MDPhotoBrowserAction: Identifiable {
    public enum Placement: Sendable {
        /// 顶栏右边的一个图标按钮。
        case toolbar
        /// 「更多」菜单里的一项。
        case menu
    }

    public var id: String
    public var title: String
    public var systemImage: String
    public var role: ButtonRole?
    public var placement: Placement
    public var handler: @MainActor (MDPhotoBrowserContext) -> Void

    public init(
        id: String? = nil,
        title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        placement: Placement = .menu,
        handler: @escaping @MainActor (MDPhotoBrowserContext) -> Void
    ) {
        self.id = id ?? "\(title)|\(systemImage)"
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.placement = placement
        self.handler = handler
    }
}

/// 浏览器里用到的字。默认的跟着系统语言。
public struct MDPhotoBrowserLabels {
    public var close = String(localized: "Close", bundle: .mdPhotoBrowser)
    public var delete = String(localized: "Delete", bundle: .mdPhotoBrowser)
    public var share = String(localized: "Share", bundle: .mdPhotoBrowser)
    public var more = String(localized: "More", bundle: .mdPhotoBrowser)
    public var previous = String(localized: "Previous Photo", bundle: .mdPhotoBrowser)
    public var next = String(localized: "Next Photo", bundle: .mdPhotoBrowser)
    public var retry = String(localized: "Try Again", bundle: .mdPhotoBrowser)
    public var loadFailed = String(localized: "This photo couldn’t be loaded.", bundle: .mdPhotoBrowser)
    public var deleteConfirmation = String(localized: "Delete this photo?", bundle: .mdPhotoBrowser)
    public var cancel = String(localized: "Cancel", bundle: .mdPhotoBrowser)
    /// 读屏念的「第 3 张，共 9 张」。
    public var position: @Sendable (_ index: Int, _ count: Int) -> String = { index, count in
        String(localized: "Photo \(index) of \(count)", bundle: .mdPhotoBrowser)
    }

    public init() {}
}

extension Bundle {
    /// 这个库自己的资源（文案）。SwiftPM 编出来在 `Bundle.module`，xcframework 里在框架自己的包里。
    static var mdPhotoBrowser: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        Bundle(for: BundleToken.self)
        #endif
    }
}

private final class BundleToken {}
