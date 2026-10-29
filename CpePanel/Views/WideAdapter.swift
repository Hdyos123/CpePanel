import SwiftUI

/// 大屏时限制内容宽度并居中，避免 iPad 横屏下内容过度拉伸
struct WideAdapter<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    let maxWidth: CGFloat
    @ViewBuilder var content: () -> Content

    init(maxWidth: CGFloat = 720, @ViewBuilder content: @escaping () -> Content) {
        self.maxWidth = maxWidth
        self.content = content
    }

    var body: some View {
        if hSize == .regular && vSize == .regular {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                content()
                    .frame(maxWidth: maxWidth)
                Spacer(minLength: 0)
            }
        } else {
            content()
        }
    }
}
