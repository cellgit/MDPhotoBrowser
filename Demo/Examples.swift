import MDPhotoBrowser
import SwiftUI

/// 缩略图：方块、圆角、铺满裁好；挂着 `.mdPhotoSource`，照片从这里放大出来。
struct Thumbnail: View {
    let photo: MDPhoto
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            // 铺满裁好的图在格子外面还占着地方（长图、全景图），不限定的话会接走旁边格子的点按。
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .mdPhotoSource(photo.id, cornerRadius: 10)
            .task(id: photo.id) {
                image = try? await MDImageLoader.shared.image(for: photo.placeholder ?? photo.source)
            }
    }
}

private let columns = [GridItem(.adaptive(minimum: 104), spacing: 4)]

/// 网格：删除（要确认）、分享、「更多」里一个自己的操作、长图铺满宽。
struct GridExample: View {
    @State private var photos = SamplePhotos.all
    @State private var selection: MDPhoto.ID?
    @State private var copied: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    Button { selection = photo.id } label: { Thumbnail(photo: photo) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(photo.caption ?? photo.id))
                        .accessibilityIdentifier("thumb-\(index)")
                }
            }
            .padding(4)
            if let copied {
                Text("Copied \(copied)").foregroundStyle(.secondary).padding()
            }
        }
        .navigationTitle("Grid")
        .mdPhotoBrowser(
            selection: $selection,
            photos: photos,
            configuration: configuration,
            onDelete: { photo in
                photos.removeAll { $0.id == photo.id }
                return true
            }
        )
    }

    private var configuration: MDPhotoBrowserConfiguration {
        var configuration = MDPhotoBrowserConfiguration()
        configuration.showsDeleteButton = true
        configuration.showsShareButton = true
        configuration.fitsLongPhotosToWidth = true
        configuration.shareExtraText = "Shared from MDPhotoBrowser"
        configuration.actions = [
            MDPhotoBrowserAction(title: "Copy", systemImage: "doc.on.doc") { context in
                UIPasteboard.general.image = context.image
                copied = context.photo.caption
            },
        ]
        return configuration
    }
}

/// 慢的、会失败的图：先画同比例的小图垫着，原图到了再换；第一次失败的那张点「再试一次」就好了。
struct LoadingExample: View {
    @State private var selection: MDPhoto.ID?
    private let photos = LoadingExample.makePhotos()

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    Button { selection = photo.id } label: { Thumbnail(photo: photo) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(photo.caption ?? photo.id))
                        .accessibilityIdentifier("slow-\(index)")
                }
            }
            .padding(4)
        }
        .navigationTitle("Slow and failing loads")
        .mdPhotoBrowser(selection: $selection, photos: photos)
    }

    private actor Attempts {
        private var count = 0
        func next() -> Int {
            count += 1
            return count
        }
    }

    private static func makePhotos() -> [MDPhoto] {
        let attempts = Attempts()
        return SamplePhotos.scenes.prefix(3).enumerated().map { index, scene in
            let small = SamplePhotos.render(scene, scale: 0.06)
            let flaky = index == 2
            return MDPhoto(
                id: "slow-\(scene.name)",
                source: .custom(key: "slow-\(scene.name)") {
                    try await Task.sleep(for: .seconds(1.5))
                    if flaky, await attempts.next() == 1 { throw URLError(.timedOut) }
                    return SamplePhotos.render(scene)
                },
                placeholder: .image(small),
                caption: flaky ? "\(scene.name) (fails once)" : "\(scene.name) (slow)"
            )
        }
    }
}

/// 自己盖一层：右下角一颗心，跟着控件显隐。
struct AccessoryExample: View {
    @State private var selection: MDPhoto.ID?
    @State private var liked: Set<MDPhoto.ID> = []
    private let photos = Array(SamplePhotos.all.prefix(4))

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    Button { selection = photo.id } label: { Thumbnail(photo: photo) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(photo.caption ?? photo.id))
                        .accessibilityIdentifier("accessory-\(index)")
                }
            }
            .padding(4)
            Text(liked.isEmpty ? "Nothing liked yet" : "Liked: \(liked.sorted().joined(separator: ", "))")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("liked")
                .padding()
        }
        .navigationTitle("Accessory overlay")
        .mdPhotoBrowser(selection: $selection, photos: photos) { context in
            let isLiked = liked.contains(context.photo.id)
            Button {
                if isLiked { liked.remove(context.photo.id) } else { liked.insert(context.photo.id) }
            } label: {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isLiked ? .pink : .white)
                    .frame(width: 56, height: 56)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .accessibilityLabel(Text(isLiked ? "Unlike" : "Like"))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(24)
            .opacity(context.controlsVisible ? 1 : 0)
        }
    }
}

/// UIKit：一排 `UIImageView`，点了 present 一个 `MDPhotoBrowserController`，照片从点的那个视图里放大出来。
struct UIKitExample: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIKitGalleryController {
        UIKitGalleryController()
    }

    func updateUIViewController(_ controller: UIKitGalleryController, context: Context) {}
}

final class UIKitGalleryController: UIViewController, MDPhotoBrowserDelegate {
    private let photos = Array(SamplePhotos.all.prefix(3))
    private var thumbnails: [UIImageView] = []
    private let status = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, photo) in photos.enumerated() {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 12
            imageView.layer.cornerCurve = .continuous
            imageView.isUserInteractionEnabled = true
            imageView.isAccessibilityElement = true
            imageView.accessibilityTraits = .button
            imageView.accessibilityLabel = photo.caption
            imageView.accessibilityIdentifier = "uikit-\(index)"
            imageView.tag = index
            imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(open(_:))))
            if case .image(let image) = photo.source { imageView.image = image }
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor).isActive = true
            stack.addArrangedSubview(imageView)
            thumbnails.append(imageView)
        }
        status.textColor = .secondaryLabel
        status.text = "Tap a photo"
        status.accessibilityIdentifier = "uikit-status"
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        view.addSubview(status)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            status.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 16),
            status.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
        ])
    }

    @objc private func open(_ gesture: UITapGestureRecognizer) {
        guard let index = gesture.view?.tag else { return }
        var configuration = MDPhotoBrowserConfiguration()
        configuration.singleTapAction = .dismiss
        let browser = MDPhotoBrowserController(photos: photos, initialIndex: index, configuration: configuration)
        browser.delegate = self
        present(browser, animated: true)
    }

    func photoBrowser(_ browser: MDPhotoBrowserController, sourceViewForPhotoAt index: Int) -> UIView? {
        thumbnails.indices.contains(index) ? thumbnails[index] : nil
    }

    func photoBrowser(_ browser: MDPhotoBrowserController, didShowPhotoAt index: Int) {
        status.text = "Showing \(index + 1)"
    }

    func photoBrowser(_ browser: MDPhotoBrowserController, didDismissAt index: Int) {
        status.text = "Closed at \(index + 1)"
    }
}
