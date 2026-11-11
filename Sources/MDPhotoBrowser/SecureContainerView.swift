import UIKit

/// 截屏、录屏时里面是空的：把内容放进一个「密码输入框」的画布里——系统截屏、录屏、投屏时会把密码框的内容抹掉。
///
/// 这是系统没有公开的做法（找输入框里画字的那一层）。哪天那一层不在了，`canvas` 就是一个普通的视图：照片照常显示，
/// 只是不再防截屏，不会坏掉。模拟器上截屏不抹，要在真机上验。
@MainActor
final class SecureContainerView: UIView {
    /// 把要保护的内容加到这里。
    let canvas: UIView
    private let field: SecureField

    override init(frame: CGRect) {
        let field = SecureField()
        field.isSecureTextEntry = true
        field.backgroundColor = .clear
        let found = Self.canvas(in: field)
        self.field = field
        canvas = found ?? UIView()
        super.init(frame: frame)
        backgroundColor = .clear
        if found != nil {
            field.frame = bounds
            field.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(field)
        } else {
            addSubview(canvas)
        }
        canvas.isUserInteractionEnabled = true
        canvas.frame = bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 画字的那一层：iOS 17 起是 `_UITextLayoutCanvasView`，名字里都带 Canvas。有的版本排一次版才建出来。
    private static func canvas(in field: UITextField) -> UIView? {
        func search() -> UIView? { field.subviews.first { String(describing: type(of: $0)).contains("Canvas") } }
        if let found = search() { return found }
        field.layoutIfNeeded()
        return search()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        field.frame = bounds
        canvas.frame = bounds
    }

    /// 触摸直接交给画布里的内容：输入框自己永远不是被点中的那个（点中它会弹键盘）。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        canvas.hitTest(convert(point, to: canvas), with: event)
    }
}

/// 不会成为第一响应者的密码框：不弹键盘、不出光标。
private final class SecureField: UITextField {
    override var canBecomeFirstResponder: Bool { false }
}
