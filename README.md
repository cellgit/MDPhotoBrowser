# MDPhotoBrowser

我们自己的全屏看图库。iOS 17+，Swift 6，零第三方依赖，SwiftUI 优先，UIKit 也能用。

功能对齐 [SKPhotoBrowser](https://github.com/suzuki-0000/SKPhotoBrowser)：照片从缩略图里放大出来、缩回去；左右翻页，
双指缩放、双击放大，往上或往下拖着关；说明文字、删除、分享、自己加的操作；网上的图、本地文件、动图，先垫小图再换原图，
取不到能重试；读屏和键盘都能用。

## 目录

```
MDPhotoBrowser/                   仓库根
├── Package.swift                 SPM 接入
├── Sources/MDPhotoBrowser/       库的源码、文案（Localizable.xcstrings）、隐私清单
├── Tests/MDPhotoBrowserTests/    单元测试（Swift Testing）：几何、解码、照片列表
├── MDPhotoBrowser.xcodeproj      framework（出 xcframework 用）、单元测试、示例 App、UI 测试
├── Demo/                         示例 App：网格、慢的和会失败的图、自己盖一层、UIKit
├── DemoUITests/                  在示例 App 里真点一遍
└── scripts/build-xcframework.sh
```

`Package.swift` 和 `MDPhotoBrowser.xcodeproj` 编的是同一份 `Sources/MDPhotoBrowser`。工程用的是同步文件夹，往里加文件
不用改工程。

## 接入

### xcframework（我们自己的 App 用这个）

```bash
scripts/build-xcframework.sh
```

产出 `build/MDPhotoBrowser.xcframework`（真机 + 模拟器两片，各带 dSYM）、zip 和它的 checksum。拷进 App 仓库
（`Frameworks/MDPhotoBrowser.xcframework`），拖进 App target 的 Frameworks, Libraries, and Embedded Content，
选 Embed & Sign。框架打开了库演进，只带 `.swiftinterface`，换了 Swift 编译器的 App 也能用。

### SPM

```swift
.package(url: "https://github.com/cellgit/MDPhotoBrowser.git", branch: "main")
```

## 用法（SwiftUI）

```swift
import MDPhotoBrowser

struct Gallery: View {
    let photos: [MDPhoto]
    @State private var selection: MDPhoto.ID?

    var body: some View {
        LazyVGrid(columns: columns) {
            ForEach(photos) { photo in
                Thumbnail(photo)
                    .mdPhotoSource(photo.id, cornerRadius: 12)   // 照片从这里放大出来、缩回这里
                    .onTapGesture { selection = photo.id }
            }
        }
        .mdPhotoBrowser(selection: $selection, photos: photos)
    }
}
```

- `selection` 设成一张照片的 id 就打开；翻页时它跟着变；关掉后变回 nil。App 自己把它设成 nil 也会关（照片缩回去）。
  按位置开用 `.mdPhotoBrowser(index: $index, photos:)`。
- `.mdPhotoSource` 要挂在 `.mdPhotoBrowser` 那个视图的里面。没挂、或者缩略图不在屏幕上，照片原地淡入淡出。
  浏览哪张，哪张的缩略图就空着，往下拖时看得到照片是从哪儿来的。
- **缩略图要从和原图同比例的图裁出来**（同一张图 `scaledToFill` 铺满裁好），并且让浏览器拿得到这张图（`placeholder`
  或 `source` 的 `cached`）：点下去时照片立刻从格子里飞出来，第一帧和格子一模一样。服务端裁好的方图（比如按脸裁的）
  比例对不上，做不了转场的起点；手上没有同比例的图时浏览器先等垫着的那张最多 0.25 秒，等不到就原地淡入。
- 缩略图取的不是正中（比如封面取上部），传 `alignment`：`.mdPhotoSource(id, alignment: .top)`。
- 缩略图铺满裁好的话，给它加 `.contentShape(…)`：裁掉的部分还占着地方，会接走旁边格子的点按。
- `photos` 打开着时可以变（删了、加了、改了说明），浏览器停在原来那张上，它没了就停在原来的位置。
- `onDelete: { photo in … return true }`：返回 true 才从浏览器里拿掉，删到一张不剩就关。
  `onDismiss: { photo in … }`：关的动画走完、浏览器已经拿掉之后调，这时可以接着弹别的页面。

### 照片从哪里来

```swift
MDPhoto.image(uiImage)                         // 手上的图
MDPhoto.url(url, placeholder: .url(smallURL))  // 网上的图，先垫同比例的小图
MDPhoto.file(fileURL)                          // 本地文件
MDPhoto(id: "a", source: .data(gifData))       // 字节：JPEG、PNG、HEIC、GIF、APNG、动的 WebP

// App 自己取（带令牌的接口、自己的缓存）：cached 是不用等就能给的那张（打开的那一下拿它做转场），load 真正去取
MDPhoto(id: media.id, source: .custom(key: media.id, cached: { cache.image(media.id) }) {
    try await api.image(media.id)
})
```

`placeholder` 要和原图**同一个宽高比**（服务端小一档的图），先用它画，原图到了位置不动地换上。裁成方块的缩略图不行，
换的那一下会跳。

网上的图走 `MDImageLoader`：`URLSession` 取（`URLCache` 是磁盘那一层），解好的图进内存缓存（`NSCache`，按解码后的
字节算，默认 128 MB），在后台解码，长边超过 4096 的缩小。要带请求头就给 `configuration.loader` 换一个
`MDImageLoader(session:cache:maximumPixelSize:makeRequest:)`；缓存要接别处的，实现 `MDImageCaching`。

### 配置

```swift
var configuration = MDPhotoBrowserConfiguration()
configuration.showsDeleteButton = true
configuration.actions = [
    MDPhotoBrowserAction(title: "心动这张照片", systemImage: "heart", placement: .toolbar) { context in
        liked = context.photo.id
        context.proxy.dismiss()
    },
]
```

| 配置 | 默认 | 说明 |
| --- | --- | --- |
| `showsCloseButton` / `showsCounter` | 开 | 左上角 ×、顶上「3 / 9」 |
| `showsDeleteButton` / `confirmsDeletion` | 关 / 开 | 右上角删除，删之前问一句 |
| `swapsCloseAndDeleteButtons` | 关 | 关闭放右边、删除放左边 |
| `showsShareButton` | 关 | 系统分享面板。打开前 Info.plist 要有 `NSPhotoLibraryAddUsageDescription`，不然点「存储图像」会崩 |
| `sharesCaption` / `shareExtraText` | 开 / 无 | 分享时带上说明、再附一句 |
| `actions` | 无 | 自己的操作：顶栏一个图标（`.toolbar`），或「更多」菜单里一项（`.menu`） |
| `showsPageArrows` | 关 | 两边的上一张 / 下一张（iPad） |
| `showsCaptions` / `caption` | 开 | 说明文字和它的字体、颜色、对齐、行数、底 |
| `showsStatusBar` | 关 | 控件显示时露出状态栏 |
| `autoHideControlsAfter` | 不藏 | 不碰屏幕多久后藏控件 |
| `chromeStyle` | `.glass` | 按钮的底：iOS 26 的 Liquid Glass（之前是深色材质），或 `.plain` 只有图标 |
| `singleTapAction` | `.toggleControls` | 单击：显隐控件、关掉、什么都不做 |
| `doubleTapToZoom` / `zoomsOnDoubleTapOutsideImage` | 开 | 双击放大还原，点在黑边上也算 |
| `swipeToDismiss` | 开 | 往上、往下拖着关 |
| `maximumZoomScale` | 自动 | 最多放到整张放下时的几倍；自动按清晰度算，至少 3 倍 |
| `fitsLongPhotosToWidth` | 关 | 长图按宽铺满、从顶上看起 |
| `pageSpacing` / `imagePadding` | 20 / 0 | 页间距、图四周留白 |
| `backgroundColor` / `foregroundColor` / `indicatorColor` | 黑 / 白 / 白 | |
| `bouncesOnPresent` | 关 | 打开时弹一下 |
| `loader` / `preloadDistance` | 共享 / 1 | 取图的加载器、前后各预先取几张 |
| `protectsFromScreenshots` | 关 | 截屏、录屏时图是空的（只在真机上有效） |
| `labels` | 跟系统语言 | 按钮和读屏的字：英、简、繁、日、韩、德、法、西 |

### 自己盖一层

```swift
.mdPhotoBrowser(selection: $selection, photos: photos) { context in
    LikeButton(photo: context.photo)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(24)
        .opacity(context.controlsVisible ? 1 : 0)
}
```

`context` 里有当前这张、第几张、一共几张、手上的图，和 `proxy`（`dismiss()`、`page(to:)`、`next()`、`previous()`、
`setControlsVisible(_:)`、`deleteCurrentPhoto()`、`shareCurrentPhoto()`）。这一层铺满屏幕，空白的地方不挡手势。

## 用法（UIKit）

```swift
let browser = MDPhotoBrowserController(photos: photos, initialIndex: indexPath.item, configuration: configuration)
browser.delegate = self
present(browser, animated: true)

extension GalleryViewController: MDPhotoBrowserDelegate {
    func photoBrowser(_ browser: MDPhotoBrowserController, sourceViewForPhotoAt index: Int) -> UIView? {
        collectionView.cellForItem(at: IndexPath(item: index, section: 0))?.contentView
    }
}
```

代理（都有默认实现）：`sourceViewForPhotoAt`（转场的缩略图，圆角取它的 `layer.cornerRadius`）、`didShowPhotoAt`、
`shouldDelete … async -> Bool`、`didChangeControlsVisibility`、`willDismissAt`、`didDismissAt`。
控制器上：`photos`（可改）、`currentIndex`、`jump(to:animated:)`、`next()`、`previous()`、`setControlsVisible(_:)`、
`deleteCurrentPhoto()`、`dismissBrowser()`。

## 手势和读屏

- 左右滑翻页；双指缩放，松手回弹；双击放大到点的地方，再双击还原。
- 没放大时往上、往下拖：照片跟着手指走、慢慢缩小，背景变透明；拖过 110 点或甩得够快就关，否则弹回来。
  长图滚到顶再往下拖、滚到底再往上拖才算。
- 单击显隐控件（要等双击判断完）。控件藏起来时整个拿掉，读屏读不到看不见的按钮。
- 读屏：每页念说明（没有就念「第 3 张，共 9 张」），三指左右滑翻页，两指 Z 字关掉。
- iPad、Mac 的键盘：← → 翻页，Esc 关掉。

## 测试

```bash
xcodebuild test -project MDPhotoBrowser.xcodeproj -scheme MDPhotoBrowser -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
xcodebuild test -project MDPhotoBrowser.xcodeproj -scheme Demo -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

第一条是单元测试，第二条在示例 App 里点一遍：打开、翻页、单击显隐、双击放大、往上往下拖关掉、删除、自己盖一层、
UIKit、慢的和会失败的图。iOS 26 和 iOS 18 都要过。
