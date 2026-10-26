import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: StatusStore
    let openSettings: (Bool) -> Void
    var isDemo = false
    @State private var selected: MetricTemplate?
    @State private var pendingConnection: MetricKind?
    @State private var pendingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !store.activityTemplates.isEmpty {
                        ForEach(store.activityTemplates) { template in
                            ActivityCard(template: template, reading: store.reading(for: template)) { selected = template }
                        }
                    }
                    if !store.aiTemplates.isEmpty {
                        VStack(spacing: 6) {
                        sectionLabel("AI WORKSPACE", caption: "사용량과 남은 여유")
                        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                            ForEach(store.aiTemplates) { template in
                                AICard(template: template, reading: store.reading(for: template), isConnected: template.kind == .codex ? store.codexConnected : store.claudeConnected) { selected = template }
                            }
                        }
                        }
                    }
                    if !store.systemTemplates.isEmpty {
                        VStack(spacing: 6) {
                        sectionLabel("THIS MAC", caption: "실시간 시스템")
                        LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 8) {
                            ForEach(store.systemTemplates) { template in
                                SystemCard(template: template, reading: store.reading(for: template), history: store.histories[template.id, default: []]) { selected = template }
                            }
                        }
                        }
                    }
                    if !store.customTemplates.isEmpty {
                        VStack(spacing: 6) {
                        sectionLabel("MY METRICS", caption: "내가 고른 통계")
                        LazyVGrid(columns: Array(repeating: .init(.flexible()), count: min(3, store.customTemplates.count)), spacing: 8) {
                            ForEach(store.customTemplates) { template in
                                CustomMetricRow(template: template, reading: store.reading(for: template)) { selected = template }
                            }
                        }
                        }
                    }
                    if store.visibleTemplates.isEmpty {
                        Text("표시할 항목을 골라 주세요.").foregroundStyle(Palette.muted).padding(.vertical, 32)
                    }
                    Button { openSettings(true) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "plus.circle").font(.system(size: 13))
                            Text("나만의 항목 만들기").font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("TEMPLATE").font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(1)
                        }
                        .foregroundStyle(Palette.muted).padding(9)
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.muted.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 18).padding(.bottom, 8)
            }.scrollIndicators(.never)
            footer
        }
        .frame(width: 600, height: 746)
        .background(Palette.background).foregroundStyle(Palette.text)
        .preferredColorScheme(.dark)
        .sheet(item: $selected, onDismiss: {
            if let kind = pendingConnection {
                pendingConnection = nil
                store.connect(kind)
            } else if pendingSettings {
                pendingSettings = false
                openSettings(false)
            }
        }) { template in
            MetricDetailView(store: store, template: template,
                             onEdit: { pendingSettings = true; selected = nil },
                             onConnect: { pendingConnection = template.kind; selected = nil },
                             onConnectAPI: { pendingConnection = .claudeAPI; selected = nil })
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.mint).frame(width: 32, height: 32)
                .background(Palette.mint.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("Mac Status").font(.system(size: 17, weight: .semibold))
                    if isDemo {
                        Text("DEMO").font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.mint).padding(.horizontal, 5).padding(.vertical, 3)
                            .background(Palette.mint.opacity(0.1), in: Capsule())
                    }
                }
                Text("필요한 숫자, 한곳에.").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Spacer()
            QuietIconButton(symbol: "arrow.clockwise", label: "모든 통계 새로고침") { Task { await store.refresh(force: true) } }
                .disabled(store.isRefreshing)
            QuietIconButton(symbol: "slider.horizontal.3", label: "설정 및 항목 관리") { openSettings(false) }
        }.padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func sectionLabel(_ title: String, caption: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.8).foregroundStyle(Palette.muted)
            Spacer()
            Text(caption).font(.system(size: 10)).foregroundStyle(Palette.muted.opacity(0.7))
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(store.isRefreshing ? Palette.tint("yellow") : Palette.mint).frame(width: 5, height: 5)
            Text(store.isRefreshing ? "업데이트 중" : "시스템 3초 · AI 1분 간격")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
            Spacer()
            QuietIconButton(symbol: "power", label: "Mac Status 종료") { NSApp.terminate(nil) }
        }.padding(.horizontal, 20).padding(.vertical, 8)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

struct ActivityCard: View {
    let template: MetricTemplate
    let reading: MetricReading
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: template.symbol).font(.system(size: 20)).foregroundStyle(Palette.tint(template.tint))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(template.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(reading.state == .failed ? "업데이트 실패 · 상세 확인" : "기록 시간")
                            .font(.system(size: 9)).foregroundStyle(reading.state == .failed ? Palette.tint("orange") : Palette.muted)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("오늘").font(.system(size: 9)).foregroundStyle(Palette.muted)
                        Text(MetricFormat.value(reading, template: template))
                            .font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                    Rectangle().fill(Palette.line).frame(width: 1, height: 28).padding(.horizontal, 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("최근 7일").font(.system(size: 9)).foregroundStyle(Palette.muted)
                        Text(reading.details.first { $0.label == "최근 7일" }?.value ?? (reading.state == .needsSetup ? "연결 설정" : "—"))
                            .font(.system(size: 16, weight: .medium, design: .rounded)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                }
                .padding(.leading, 13).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .help("WakaTime 기록 상세 보기")
            WakaTimeDashboardButton()
        }.padding(.trailing, 13).cardSurface()
    }
}

struct SystemCard: View {
    let template: MetricTemplate
    let reading: MetricReading
    let history: [Double]
    let action: () -> Void
    private var tint: Color { Palette.tint(template.tint) }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: template.symbol).foregroundStyle(tint)
                    Text(template.name).foregroundStyle(Palette.muted)
                    Spacer()
                    if reading.state == .failed { Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.tint("orange")) }
                }.font(.system(size: 10, weight: .medium))
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(MetricFormat.value(reading, template: template))
                        .font(.system(size: reading.text != nil ? 17 : 21, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                    if reading.text == nil, reading.value != nil {
                        Text(template.unit).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 4)
                    if template.kind == .cpu { Sparkline(values: history, tint: tint).frame(width: 27, height: 18) }
                }
                if let fraction = reading.fraction {
                    UsageBar(fraction: fraction, tint: tint, height: 3)
                } else {
                    Text(reading.subtitle).font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(1)
                }
            }.padding(11).frame(maxWidth: .infinity, alignment: .leading).frame(height: 82).cardSurface()
        }.buttonStyle(.plain)
    }
}

struct CustomMetricRow: View {
    let template: MetricTemplate
    let reading: MetricReading
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Label(template.name, systemImage: template.symbol)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.tint(template.tint)).lineLimit(1)
                if reading.value != nil {
                    Text(MetricFormat.value(reading, template: template) + (reading.text == nil && template.unit != "USD" ? " " + template.unit : ""))
                        .font(.system(size: 14, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1)
                } else {
                    Text(reading.subtitle).font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(1)
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).frame(height: 58).cardSurface().contentShape(Rectangle())
        }.buttonStyle(.plain).help(reading.value == nil ? reading.subtitle : template.subtitle)
    }
}

struct MetricDetailView: View {
    @ObservedObject var store: StatusStore
    let template: MetricTemplate
    let onEdit: () -> Void
    let onConnect: () -> Void
    let onConnectAPI: () -> Void
    @Environment(\.dismiss) private var dismiss
    private var reading: MetricReading { store.reading(for: template) }
    private var connected: Bool { template.kind == .codex ? store.codexConnected : store.claudeConnected }
    private var isAI: Bool { [.codex, .claude].contains(template.kind) }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: template.symbol).foregroundStyle(Palette.tint(template.tint)).font(.system(size: 22))
                Text(template.name).font(.system(size: 19, weight: .semibold))
                if isAI, let planName = reading.planName {
                    SubscriptionPlanBadge(name: planName, tint: Palette.tint(template.tint))
                }
                Spacer()
                QuietIconButton(symbol: "xmark", label: "닫기") { dismiss() }
            }
            if isAI && !connected {
                connectionContent
            } else {
                if !isAI {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(MetricFormat.value(reading, template: template)).font(.system(size: template.kind == .wakatime ? 34 : 44, weight: .medium, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                    if reading.value != nil && reading.text == nil { Text(template.unit).foregroundStyle(Palette.muted) }
                    if let limit = reading.limit, template.unit != "%" { Text("/ \(MetricFormat.number(limit, unit: template.unit))").foregroundStyle(Palette.muted) }
                }
                }
                Text(reading.subtitle).font(.system(size: 12)).foregroundStyle(reading.state == .failed ? Palette.tint("orange") : Palette.muted).fixedSize(horizontal: false, vertical: true)
                if !isAI && reading.fraction != nil { UsageBar(fraction: reading.fraction, tint: Palette.tint(template.tint), height: 7) }
                ForEach(reading.details.filter { !($0.role == .cloud && $0.value == "플랜 한도 공유") && $0.label != "추가 크레딧 사용" }) { detail in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(detail.label); Spacer(); Text(detail.value).monospacedDigit() }.font(.system(size: 12))
                        if detail.fraction != nil { UsageBar(fraction: detail.fraction, tint: Palette.tint(template.tint)) }
                        if let date = detail.resetAt { Text(MetricFormat.reset(date)).font(.system(size: 10)).foregroundStyle(Palette.muted) }
                        if let note = detail.note { Text(note).font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                if let updated = reading.updatedAt {
                    Text("최근 확인 \(updated.formatted(date: .omitted, time: .standard))\(reading.state == .failed ? " · 마지막 성공 값" : "")")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                HStack {
                    AccentButton(title: "새로고침", symbol: "arrow.clockwise") {
                        Task { await store.refresh(force: true) }
                    }
                    if template.kind == .wakatime {
                        WakaTimeDashboardButton()
                    } else if !template.link.isEmpty {
                        Button("서비스 열기") { if let url = URL(string: template.link) { NSWorkspace.shared.open(url) } }.buttonStyle(.borderless)
                    }
                    Spacer()
                    if !isAI { Button("설정") { onEdit() }.buttonStyle(.borderless) }
                    if isAI { Button("로그인 창") { onConnect() }.buttonStyle(.borderless) }
                    if isAI { Button("연결 해제") { store.disconnect(template.kind) }.buttonStyle(.borderless).foregroundStyle(Palette.muted) }
                }.font(.system(size: 11))
                if template.kind == .claude {
                    HStack {
                        Button(store.claudeAPIConnected ? "API Console 연결 확인" : "API 크레딧 연결") { onConnectAPI() }
                            .buttonStyle(.borderless).font(.system(size: 12))
                        Spacer()
                        if store.claudeAPIConnected {
                            Button("API 연결 해제") { store.disconnect(.claudeAPI) }.buttonStyle(.borderless).font(.system(size: 11))
                        }
                    }
                }
            }
        }.padding(26)
        }.scrollIndicators(.never).frame(width: 410, height: isAI && connected ? 630 : 520)
            .background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
    }

    private var connectionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(template.kind == .codex ? "ChatGPT 계정으로 로그인하면 Codex 통계를 볼 수 있습니다." : "Claude 계정으로 로그인하면 사용량과 한도를 볼 수 있습니다.")
                .font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Text(template.kind == .codex
                 ? "이 앱의 로그인 창에서 ChatGPT에 로그인한 뒤 ‘연결 확인’을 누르세요. 별도 프로그램을 설치할 필요가 없습니다. 웹 사용량 조회 경로를 이용하므로 서비스 변경에 따라 연결이 중단될 수 있습니다."
                 : "이 앱의 로그인 창에서 Claude에 로그인한 뒤 ‘연결 확인’을 누르세요. Claude Code 설치는 필요하지 않습니다. 웹 사용량 조회 경로를 이용하므로 서비스 변경에 따라 연결이 중단될 수 있습니다.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true).lineSpacing(4)
            Label("조회만 수행하며 AI 요청이나 토큰 비용이 발생하지 않습니다.", systemImage: "lock.shield")
                .font(.system(size: 10)).foregroundStyle(Palette.mint).fixedSize(horizontal: false, vertical: true)
            AccentButton(title: "로그인하여 연결", symbol: "link") { onConnect() }
        }
    }
}
