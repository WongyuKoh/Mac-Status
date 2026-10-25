import SwiftUI

struct AICard: View {
    let template: MetricTemplate
    let reading: MetricReading
    let isConnected: Bool
    let action: () -> Void
    private var tint: Color { Palette.tint(template.tint) }
    private var creditDetails: [MetricDetail] {
        reading.details.filter { $0.role == .credits && $0.label != "추가 크레딧 사용" }.sorted { priority($0) < priority($1) }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: template.symbol).font(.system(size: 14)).foregroundStyle(tint)
                    Text(template.name).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    if reading.state == .failed {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Palette.tint("orange"))
                    }
                    Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(Palette.muted)
                }.frame(height: 18)
                if reading.value != nil || (isConnected && reading.state == .unavailable) {
                    quota(title: "5시간 사용량", detail: reading.details.first { $0.role == .session }).padding(.top, 9)
                    quota(title: "주간 사용량", detail: reading.details.first { $0.role == .weekly }).padding(.top, 7)
                    Rectangle().fill(Palette.line).frame(height: 1).padding(.vertical, 7)
                    VStack(spacing: 4) {
                        if creditDetails.isEmpty {
                            HStack {
                                Text("크레딧").foregroundStyle(Palette.muted)
                                Spacer()
                                Text("정보 미제공")
                            }.font(.system(size: 10))
                        }
                        ForEach(creditDetails) { detail in creditRow(detail) }
                    }
                } else {
                    Text("—").font(.system(size: 30, weight: .light)).foregroundStyle(Palette.muted.opacity(0.6)).padding(.top, 14)
                    Text(isConnected ? reading.subtitle : "사용량과 한도를 연결하세요")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(3).padding(.top, 5)
                    HStack(spacing: 4) {
                        Text(isConnected ? "상세 확인" : "계정 연결")
                        Image(systemName: "arrow.right").font(.system(size: 8))
                    }.font(.system(size: 11, weight: .semibold)).foregroundStyle(tint).padding(.top, 12)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).frame(height: 240, alignment: .top)
                .cardSurface().contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
        .help(reading.state == .failed ? "업데이트 실패 · 마지막 확인 값\n" + reading.subtitle : "사용량과 크레딧 상세 보기")
    }

    private func quota(title: String, detail: MetricDetail?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer(minLength: 4)
                if let fraction = detail?.fraction {
                    Text(detail?.value.components(separatedBy: " ").first ?? String(format: "%.0f%%", fraction * 100))
                        .font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
                } else {
                    Text("미제공").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }.frame(height: 21)
            UsageBar(fraction: detail?.fraction, tint: tint, height: 3)
            Text(detail?.resetAt.map(MetricFormat.reset) ?? (detail == nil ? "계정에서 수치를 제공하지 않습니다" : "초기화 시각 미제공"))
                .font(.system(size: 8.5)).foregroundStyle(Palette.muted.opacity(0.8)).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func creditRow(_ detail: MetricDetail) -> some View {
        let balance = ["API 토큰", "Console API 잔액"].contains(detail.label)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(detail.label).font(.system(size: 10)).foregroundStyle(balance ? Palette.text : Palette.muted)
            Spacer(minLength: 0)
            Text(detail.value).font(.system(size: balance ? 14 : 11, weight: balance ? .semibold : .medium, design: .rounded))
                .foregroundStyle(balance ? tint : Palette.text).monospacedDigit().lineLimit(1).minimumScaleFactor(0.9)
        }.frame(minHeight: 18)
            .help(detail.label + ": " + detail.value + (detail.note.map { "\n" + $0 } ?? ""))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(detail.label + ", " + detail.value)
    }

    private func priority(_ detail: MetricDetail) -> Int {
        switch detail.label {
        case "API 토큰": return 0
        case "Console API 잔액": return 1
        case "크레딧 잔액": return 1
        case "클라우드 세션 크레딧": return 2
        default: return 3
        }
    }
}
