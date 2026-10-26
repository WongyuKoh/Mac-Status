import SwiftUI

struct WakaTimeDashboardButton: View {
    var body: some View {
        Button {
            NSWorkspace.shared.open(WakaTimeProvider.dashboardURL)
        } label: {
            HStack(spacing: 5) {
                Text("대시보드")
                Image(systemName: "arrow.up.right").accessibilityHidden(true)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.tint("blue"))
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(Palette.tint("blue").opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.tint("blue").opacity(0.35), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).fixedSize()
        .accessibilityLabel("WakaTime 대시보드 열기")
        .help("WakaTime 웹 대시보드를 기본 브라우저에서 엽니다.")
    }
}
