import SwiftUI
import UIKit

/// 浏览器的整个界面：底色、翻页那一层、开关时飞着的图、控件。铺满屏幕，控件让开安全区。
///
/// 配置、照片、回调由外面每次刷新时交进来：界面直接读参数，控制器拿一份不参与刷新的拷贝（init 里交）。
struct BrowserRoot<Accessory: View>: View {
    let controller: BrowserController
    let configuration: MDPhotoBrowserConfiguration
    let photos: [MDPhoto]
    let accessory: (MDPhotoBrowserContext) -> Accessory

    init(
        controller: BrowserController,
        configuration: MDPhotoBrowserConfiguration,
        photos: [MDPhoto],
        handlers: BrowserController.Handlers,
        @ViewBuilder accessory: @escaping (MDPhotoBrowserContext) -> Accessory
    ) {
        self.controller = controller
        self.configuration = configuration
        self.photos = photos
        self.accessory = accessory
        controller.configuration = configuration
        controller.handlers = handlers
    }

    var body: some View {
        ZStack {
            configuration.backgroundColor
                .opacity(controller.backgroundOpacity)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            PagerRepresentable(controller: controller, configuration: configuration,
                               ids: controller.photos.map(\.id), index: controller.index)
                .opacity(controller.pagerOpacity)
                .scaleEffect(controller.pagerScale)
                .ignoresSafeArea()
            FlightLayer(flight: controller.flight)
                .ignoresSafeArea()
            BrowserChrome(controller: controller, configuration: configuration)
            if let context = controller.context {
                accessory(context)
                    .opacity(controller.phase == .open ? 1 : 0)
                    .allowsHitTesting(controller.phase == .open)
                    .animation(.easeOut(duration: 0.18), value: controller.phase == .open)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { controller.open(in: proxy.size) }
                    .onChange(of: proxy.size) { _, size in controller.containerSize = size }
            }
            .ignoresSafeArea()
        }
        .statusBarHidden(!(configuration.showsStatusBar && controller.chromeVisible))
        .persistentSystemOverlays(controller.chromeVisible ? .automatic : .hidden)
        // 读屏的「两指 Z」：关掉。
        .accessibilityAction(.escape) { controller.close() }
        .confirmationDialog(
            configuration.labels.deleteConfirmation,
            isPresented: Binding(get: { controller.pendingDeletion != nil }, set: { if !$0 { controller.pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: controller.pendingDeletion
        ) { photo in
            Button(configuration.labels.delete, role: .destructive) {
                Task { await controller.delete(photo) }
            }
            Button(configuration.labels.cancel, role: .cancel) {}
        }
        .onChange(of: photos.map(PhotoSummary.init)) {
            controller.replacePhotos(photos)
        }
    }
}

/// 照片里界面关心的部分。图本身由 id 认：同一个 id 换了来源不算变。
private struct PhotoSummary: Equatable {
    let id: MDPhoto.ID
    let caption: String?
    let accessibilityLabel: String?

    init(_ photo: MDPhoto) {
        id = photo.id
        caption = photo.caption
        accessibilityLabel = photo.accessibilityLabel
    }
}

/* ---------- 飞着的图 ---------- */

/// 开、关时那张从缩略图里飞出来 / 飞回去的图：按缩略图的样子铺满裁好、圆角跟着变，到了全屏就是整张。
private struct FlightLayer: View {
    let flight: BrowserController.Flight?

    var body: some View {
        GeometryReader { proxy in
            if let flight {
                let origin = proxy.frame(in: .global).origin
                Image(uiImage: flight.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: max(flight.frame.width, 1), height: max(flight.frame.height, 1), alignment: flight.alignment)
                    .clipShape(RoundedRectangle(cornerRadius: flight.cornerRadius, style: .continuous))
                    .position(x: flight.frame.midX - origin.x, y: flight.frame.midY - origin.y)
                    .opacity(flight.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/* ---------- 控件 ---------- */

/// 顶栏（关闭、第几张、操作、删除）、说明、左右箭头。浏览器完全打开、用户没藏、手指没在拖时才显示。
///
/// 藏起来时整个从界面上拿掉（淡出），不是只调透明度：只调透明度加 `accessibilityHidden`，读屏那边有时不刷新，
/// 看不见的按钮还读得到、点得到。
private struct BrowserChrome: View {
    let controller: BrowserController
    let configuration: MDPhotoBrowserConfiguration

    var body: some View {
        let visible = controller.chromeVisible
        ZStack {
            if visible, let context = controller.context {
                VStack(spacing: 0) {
                    TopBar(controller: controller, configuration: configuration, context: context)
                    Spacer(minLength: 0)
                    CaptionView(configuration: configuration, photo: context.photo)
                }
                .overlay {
                    if configuration.showsPageArrows {
                        PageArrows(controller: controller, configuration: configuration, context: context)
                    }
                }
                .transition(.opacity)
            }
        }
        .foregroundStyle(configuration.foregroundColor)
        .animation(.easeOut(duration: 0.18), value: visible)
    }
}

private struct TopBar: View {
    let controller: BrowserController
    let configuration: MDPhotoBrowserConfiguration
    let context: MDPhotoBrowserContext

    var body: some View {
        let swapped = configuration.swapsCloseAndDeleteButtons
        HStack(spacing: 10) {
            if swapped { deleteButton } else { closeButton }
            Spacer(minLength: 0)
            ForEach(configuration.actions.filter { $0.placement == .toolbar }) { action in
                ChromeButton(systemImage: action.systemImage, label: action.title, style: configuration.chromeStyle) {
                    action.handler(context)
                }
            }
            shareOrMenu
            if swapped { closeButton } else { deleteButton }
        }
        .overlay {
            if configuration.showsCounter, context.count > 1 {
                Text(verbatim: "\(context.index + 1) / \(context.count)")
                    .font(.headline.monospacedDigit())
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .chromeBackground(configuration.chromeStyle, shape: Capsule())
                    .accessibilityLabel(Text(verbatim: configuration.labels.position(context.index + 1, context.count)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var closeButton: some View {
        if configuration.showsCloseButton {
            ChromeButton(systemImage: "xmark", label: configuration.labels.close, style: configuration.chromeStyle) {
                controller.close()
            }
        }
    }

    @ViewBuilder
    private var deleteButton: some View {
        if configuration.showsDeleteButton {
            ChromeButton(systemImage: "trash", label: configuration.labels.delete, style: configuration.chromeStyle) {
                controller.requestDelete()
            }
        }
    }

    /// 只有分享：一个分享按钮。还有自己加的菜单项：一个「更多」，分享是菜单里的第一项。
    @ViewBuilder
    private var shareOrMenu: some View {
        let menuActions = configuration.actions.filter { $0.placement == .menu }
        if !menuActions.isEmpty {
            Menu {
                if configuration.showsShareButton {
                    Button(configuration.labels.share, systemImage: "square.and.arrow.up") { controller.share() }
                        .disabled(context.image == nil)
                }
                ForEach(menuActions) { action in
                    Button(role: action.role) { action.handler(context) } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                }
            } label: {
                ChromeIcon(systemImage: "ellipsis", style: configuration.chromeStyle)
            }
            .accessibilityLabel(Text(verbatim: configuration.labels.more))
        } else if configuration.showsShareButton {
            ChromeButton(systemImage: "square.and.arrow.up", label: configuration.labels.share, style: configuration.chromeStyle) {
                controller.share()
            }
            .disabled(context.image == nil)
        }
    }
}

private struct CaptionView: View {
    let configuration: MDPhotoBrowserConfiguration
    let photo: MDPhoto

    var body: some View {
        let style = configuration.caption
        if configuration.showsCaptions, let caption = photo.caption, !caption.isEmpty {
            Text(verbatim: caption)
                .font(style.font)
                .foregroundStyle(style.color)
                .multilineTextAlignment(style.alignment)
                .lineLimit(style.lineLimit)
                .frame(maxWidth: .infinity, alignment: frameAlignment(style.alignment))
                .padding(.horizontal, 20)
                .padding(.top, style.background == nil ? 36 : 14)
                .padding(.bottom, 14)
                .background {
                    Group {
                        if let background = style.background {
                            background
                        } else {
                            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                        }
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
                .id(photo.id)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.18), value: photo.id)
        }
    }

    private func frameAlignment(_ alignment: TextAlignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

private struct PageArrows: View {
    let controller: BrowserController
    let configuration: MDPhotoBrowserConfiguration
    let context: MDPhotoBrowserContext

    var body: some View {
        HStack {
            ChromeButton(systemImage: "chevron.left", label: configuration.labels.previous, style: configuration.chromeStyle) {
                controller.page(to: context.index - 1)
            }
            .disabled(context.index == 0)
            Spacer()
            ChromeButton(systemImage: "chevron.right", label: configuration.labels.next, style: configuration.chromeStyle) {
                controller.page(to: context.index + 1)
            }
            .disabled(context.index >= context.count - 1)
        }
        .padding(.horizontal, 12)
    }
}

/// 一个 44 的圆按钮：玻璃底（或者没有底）上一个图标。
private struct ChromeButton: View {
    let systemImage: String
    let label: String
    let style: MDPhotoBrowserConfiguration.ChromeStyle
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ChromeIcon(systemImage: systemImage, style: style)
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
    }
}

private struct ChromeIcon: View {
    let systemImage: String
    let style: MDPhotoBrowserConfiguration.ChromeStyle

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 44)
            .chromeBackground(style, shape: Circle())
            .contentShape(Circle())
    }
}

private extension View {
    /// 顶栏按钮的底。玻璃：iOS 26 起是系统的 Liquid Glass，压一层深色（压在亮照片上它会变亮，白图标就看不见了），
    /// 之前是深色的薄材质。没有底：只加一点阴影，压在亮照片上也看得见。
    @ViewBuilder
    func chromeBackground<S: Shape>(_ style: MDPhotoBrowserConfiguration.ChromeStyle, shape: S) -> some View {
        switch style {
        case .glass:
            if #available(iOS 26.0, *) {
                glassEffect(.regular.tint(.black.opacity(0.32)).interactive(), in: shape)
            } else {
                background(.ultraThinMaterial, in: shape)
                    .environment(\.colorScheme, .dark)
            }
        case .plain:
            shadow(color: .black.opacity(0.45), radius: 4, y: 1)
        }
    }
}
