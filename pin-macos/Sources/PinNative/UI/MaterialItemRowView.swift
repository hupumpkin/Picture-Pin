import SwiftUI

/// 素材面板的一个条目行（§3.4 起是真实条目）。
///
/// 按 §3.6 的留白规则分层：行视图只吃数据与"怎么取缩略图"，
/// 不持有 store、不认识来源——容器（`MaterialPanel`）负责接线，
/// 行本身可以单独替换或重排。
///
/// 缩略图状态是本行自己的事：
///
/// - **只给可见行发请求**：行在 `LazyVStack` 里，滚出视口即销毁，
///   请求随 `.task(id:)` 一并取消（并发上限由提供者侧的闸门管）；
/// - 解码走共享 `ImageProvider`：缩略图与画布是同一份缓存，不新建体系；
/// - 失败/缺失退回图标占位——条目还在，只是看不到图，不把行藏起来。
struct MaterialItemRowView: View {
    let item: MaterialItem
    /// 取缩略图。`nil` = 这个来源没有缩略图（占位、字体）。
    let loadThumbnail: (CGSize) async -> ImageRequestResult?

    @Environment(\.displayScale) private var displayScale

    private enum Phase {
        /// 还没取（或请求被取消，等回到视口再取）。
        case waiting
        case ready(CGImage)
        /// 取不到：来源没有缩略图、素材缺失、或解码失败。占位图标兜底。
        case unavailable
    }
    @State private var phase: Phase = .waiting

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.compact) {
            thumbnail
            Text(item.title)
                .font(DesignTokens.Typography.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .task(id: item.id) {
            phase = .waiting
            let size = DesignTokens.Metrics.materialThumbnailSize
            let target = CGSize(width: size * displayScale, height: size * displayScale)
            guard let result = await loadThumbnail(target) else {
                phase = .unavailable
                return
            }
            switch result {
            case .image(let image):
                phase = .ready(image)
            case .cancelled:
                // 行离开视口被取消：留在等待态。行回来时 `.task` 会重新跑。
                phase = .waiting
            case .missing, .failed:
                phase = .unavailable
            }
        }
    }

    // 精校留白：就绪图与占位图之间的过渡（淡入、底色）留给 Codex 按面板
    // 整体节奏调；这里只保证四种终态都画得出来。
    @ViewBuilder
    private var thumbnail: some View {
        let size = DesignTokens.Metrics.materialThumbnailSize
        switch phase {
        case .ready(let image):
            Image(decorative: image, scale: displayScale)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
        case .waiting, .unavailable:
            RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                .fill(DesignTokens.Surface.rail)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: item.kind == .font ? "a.square" : "photo")
                        .font(.system(size: DesignTokens.Icon.inline))
                        .foregroundStyle(DesignTokens.Surface.secondaryText)
                }
        }
    }
}
