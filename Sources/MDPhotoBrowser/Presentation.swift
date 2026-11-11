import SwiftUI

public extension View {
    /// 全屏看照片。`selection` 设成一张照片的 id 就打开，照片从挂着同一个 id 的 `.mdPhotoSource` 缩略图里放大出来；
    /// 翻页时它跟着变成当前那张的 id，关掉后变回 nil。App 自己把它设成 nil 也会关掉（照片缩回缩略图）。
    ///
    /// ```swift
    /// LazyVGrid(columns: columns) {
    ///     ForEach(photos) { photo in
    ///         Thumbnail(photo)
    ///             .mdPhotoSource(photo.id, cornerRadius: 12)
    ///             .onTapGesture { selection = photo.id }
    ///     }
    /// }
    /// .mdPhotoBrowser(selection: $selection, photos: photos)
    /// ```
    ///
    /// - Parameters:
    ///   - photos: 浏览的照片。打开着时变了（删了、加了、改了说明），浏览器停在原来那张上，它没了就停在原来的位置。
    ///   - onDelete: 用户删了一张（`showsDeleteButton`）：返回 true 才从浏览器里拿掉。删到一张不剩就关掉。
    ///   - onDismiss: 关的动画走完、浏览器已经拿掉之后，带着最后看的那张。这时可以接着弹别的页面。
    func mdPhotoBrowser(
        selection: Binding<MDPhoto.ID?>,
        photos: [MDPhoto],
        configuration: MDPhotoBrowserConfiguration = MDPhotoBrowserConfiguration(),
        onDelete: (@MainActor (MDPhoto) async -> Bool)? = nil,
        onDismiss: (@MainActor (MDPhoto?) -> Void)? = nil
    ) -> some View {
        mdPhotoBrowser(selection: selection, photos: photos, configuration: configuration, onDelete: onDelete,
                       onDismiss: onDismiss) { _ in EmptyView() }
    }

    /// 同上，再在浏览器上盖一层自己的界面（`accessory`）：拿到当前这张、手上的图和 `proxy`（关掉、翻页、删除…）。
    /// 这一层铺满屏幕、不让开安全区以外的部分，空白的地方不挡手势；控件藏起来时要不要跟着藏，看 `context.controlsVisible`。
    func mdPhotoBrowser<Accessory: View>(
        selection: Binding<MDPhoto.ID?>,
        photos: [MDPhoto],
        configuration: MDPhotoBrowserConfiguration = MDPhotoBrowserConfiguration(),
        onDelete: (@MainActor (MDPhoto) async -> Bool)? = nil,
        onDismiss: (@MainActor (MDPhoto?) -> Void)? = nil,
        @ViewBuilder accessory: @escaping (MDPhotoBrowserContext) -> Accessory
    ) -> some View {
        modifier(PhotoBrowserPresenter(selection: selection, photos: photos, configuration: configuration,
                                       onDelete: onDelete, onDismiss: onDismiss, accessory: accessory))
    }

    /// 按位置打开：`index` 设成第几张（从 0 数）就打开，翻页时跟着变，关掉后变回 nil。
    func mdPhotoBrowser(
        index: Binding<Int?>,
        photos: [MDPhoto],
        configuration: MDPhotoBrowserConfiguration = MDPhotoBrowserConfiguration(),
        onDelete: (@MainActor (MDPhoto) async -> Bool)? = nil,
        onDismiss: (@MainActor (MDPhoto?) -> Void)? = nil
    ) -> some View {
        let selection = Binding<MDPhoto.ID?>(
            get: { index.wrappedValue.flatMap { photos.indices.contains($0) ? photos[$0].id : nil } },
            set: { id in index.wrappedValue = id.flatMap { id in photos.firstIndex { $0.id == id } } }
        )
        return mdPhotoBrowser(selection: selection, photos: photos, configuration: configuration, onDelete: onDelete,
                              onDismiss: onDismiss)
    }

    /// 这块缩略图就是浏览器里 `id` 那张照片：打开时照片从这里放大出来，关上时缩回这里，浏览这张时这里空着。
    /// 要挂在 `.mdPhotoBrowser` 那个视图的里面。
    ///
    /// - Parameters:
    ///   - cornerRadius: 缩略图的圆角，转场时照片的圆角从它变到 0。
    ///   - alignment: 缩略图铺满裁好时留的是哪一部分（比如封面取上部就是 `.top`），转场的缩略图那一头照着裁，
    ///     第一帧和缩略图一模一样。
    func mdPhotoSource(_ id: MDPhoto.ID, cornerRadius: CGFloat = 0, alignment: Alignment = .center) -> some View {
        modifier(PhotoSourceModifier(id: id, cornerRadius: cornerRadius, alignment: alignment))
    }
}

/* ---------- 弹出浏览器 ---------- */

/// 用 `fullScreenCover` 弹出浏览器：不要系统的上滑动画（照片自己从缩略图里飞出来），底是透明的（往下拖时看得见下面）。
private struct PhotoBrowserPresenter<Accessory: View>: ViewModifier {
    @Binding var selection: MDPhoto.ID?
    let photos: [MDPhoto]
    let configuration: MDPhotoBrowserConfiguration
    let onDelete: (@MainActor (MDPhoto) async -> Bool)?
    let onDismiss: (@MainActor (MDPhoto?) -> Void)?
    let accessory: (MDPhotoBrowserContext) -> Accessory

    @State private var registry = PhotoSourceRegistry()
    @State private var browser: BrowserController?
    /// 关掉时最后看的那张，等浏览器真正拿掉后交给 `onDismiss`。
    @State private var lastPhoto: MDPhoto?

    func body(content: Content) -> some View {
        content
            .environment(registry)
            .onChange(of: selection, initial: true) { _, id in follow(id) }
            .fullScreenCover(item: $browser, onDismiss: didDismiss) { browser in
                BrowserRoot(controller: browser, configuration: configuration, photos: photos, handlers: handlers,
                            accessory: accessory)
                    .presentationBackground(.clear)
            }
    }

    private var handlers: BrowserController.Handlers {
        var handlers = BrowserController.Handlers()
        handlers.onDelete = onDelete
        handlers.onIndexChange = { photo in
            if selection != photo.id { selection = photo.id }
        }
        handlers.sourceProvider = { [registry] id in registry.source(for: id) }
        handlers.hideSource = { [registry] id in registry.hide(id) }
        handlers.onFinish = { photo in
            lastPhoto = photo
            withTransaction(\.disablesAnimations, true) { browser = nil }
            if selection != nil { selection = nil }
        }
        return handlers
    }

    /// `selection` 变了：没开就开，开着就翻过去，nil 就关。
    private func follow(_ id: MDPhoto.ID?) {
        if let browser {
            guard let id else {
                browser.close()
                return
            }
            if browser.currentPhoto?.id != id, let index = browser.photos.firstIndex(where: { $0.id == id }) {
                browser.page(to: index)
            }
            return
        }
        guard let id else { return }
        guard let index = photos.firstIndex(where: { $0.id == id }) else {
            // 不是这组里的照片：不开，也别让 App 以为开着。
            selection = nil
            return
        }
        let browser = BrowserController(photos: photos, index: index, configuration: configuration)
        withTransaction(\.disablesAnimations, true) { self.browser = browser }
    }

    private func didDismiss() {
        registry.hide(nil)
        if selection != nil { selection = nil }
        let photo = lastPhoto
        lastPhoto = nil
        onDismiss?(photo)
    }
}

/* ---------- 缩略图登记 ---------- */

/// `.mdPhotoSource` 把缩略图在窗口里的位置报到这里，浏览器开关时来问；正在浏览的那张记在 `hidden`，它的缩略图藏起来。
///
/// 位置不参与界面刷新（滚动时每帧都在变）；只有 `hidden` 变了，挂着 `.mdPhotoSource` 的视图才重画。
@MainActor
@Observable
final class PhotoSourceRegistry {
    private(set) var hidden: MDPhoto.ID?
    @ObservationIgnored private var sources: [MDPhoto.ID: Source] = [:]

    private struct Source {
        /// 哪个视图报的：同一个 id 有两个缩略图时，先消失的那个不把后来的那个删掉。
        var token: UUID
        var info: BrowserController.SourceInfo
    }

    func update(_ id: MDPhoto.ID, token: UUID, info: BrowserController.SourceInfo) {
        sources[id] = Source(token: token, info: info)
    }

    func move(from old: MDPhoto.ID, to new: MDPhoto.ID, token: UUID) {
        guard let source = sources[old], source.token == token else { return }
        sources[old] = nil
        sources[new] = source
    }

    func remove(_ id: MDPhoto.ID, token: UUID) {
        if sources[id]?.token == token { sources[id] = nil }
    }

    func source(for id: MDPhoto.ID) -> BrowserController.SourceInfo? {
        sources[id]?.info
    }

    func hide(_ id: MDPhoto.ID?) {
        if hidden != id { hidden = id }
    }
}

private struct PhotoSourceModifier: ViewModifier {
    let id: MDPhoto.ID
    let cornerRadius: CGFloat
    let alignment: Alignment
    @Environment(PhotoSourceRegistry.self) private var registry: PhotoSourceRegistry?
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .opacity(registry?.hidden == id ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                registry?.update(id, token: token, info: .init(frame: frame, cornerRadius: cornerRadius, alignment: alignment))
            }
            .onChange(of: id) { old, new in registry?.move(from: old, to: new, token: token) }
            .onDisappear { registry?.remove(id, token: token) }
    }
}
