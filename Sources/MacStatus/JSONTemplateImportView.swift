import SwiftUI

struct JSONTemplateImportView: View {
    @Binding var json: String
    let onEdit: (MetricTemplate) -> Void
    let onError: () -> Void
    @State private var message: String?
    @State private var pendingExample: TemplateImportExample?
    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text("템플릿 JSON").font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 8)
                    Menu("예시 불러오기") {
                        ForEach(TemplateImportExample.allCases) { example in
                            Button(example.title) { loadExample(example) }
                        }
                    }.fixedSize()
                    Button(action: paste) { Label("붙여넣기", systemImage: "doc.on.clipboard") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Text("처음이라면 아래 예시의 이름과 숫자를 바꿔 보세요.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                TextEditor(text: $json)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden).scrollIndicators(.never)
                    .padding(12).frame(height: 250)
                    .background(Palette.background, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(message == nil ? Palette.line : Palette.tint("orange").opacity(0.7), lineWidth: 1))
                    .accessibilityLabel("템플릿 JSON 입력")
                if let message { errorNotice(message).id("json-import-error") }
                AccentButton(title: "검증하고 미리보기", symbol: "checkmark.shield", action: validate)
                Text("아직 저장되지 않습니다. 다음 화면에서 내용을 확인하고 추가할 수 있어요.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }.padding(22).cardSurface()
            VStack(alignment: .leading, spacing: 18) {
                Label("이렇게 설정하세요", systemImage: "info.circle")
                    .font(.system(size: 14, weight: .semibold))
                guideStep("1", title: "이름과 숫자 바꾸기", text: "name은 카드 이름, manualValue는 현재 값, limit은 목표나 한도예요. 숫자는 따옴표 없이 입력하세요. 한도가 없으면 limit을 null로 두세요.")
                guideStep("2", title: "미리보기 확인하기", text: "‘검증하고 미리보기’를 누르세요. 잘못된 부분이 있으면 고칠 곳을 알려 드려요.")
                guideStep("3", title: "내 통계에 추가하기", text: "다음 화면에서 이름·단위·연결을 확인하고 ‘항목 추가’를 누르세요. 저장한 항목은 상단바에서 볼 수 있어요.")
                Divider().overlay(Palette.line)
                VStack(alignment: .leading, spacing: 8) {
                    Text("자동으로 불러오는 통계가 필요하다면").font(.system(size: 12, weight: .semibold))
                    Text("‘예시 불러오기’에서 ‘API 연결 예시’를 선택하세요. endpoint는 실제 API 주소, valuePath는 응답에서 숫자가 있는 위치예요. 예: usage.total")
                    Text("example.com은 형식 설명용 주소예요. 실제 API 주소와 숫자 위치로 바꿔야 조회할 수 있어요.")
                    Text("API 키·토큰은 JSON에 넣지 마세요. 다음 화면의 보안 키 칸에 입력하면 Mac의 키체인에 저장돼요.")
                }
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading).cardSurface()
        }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            message = nil
            pendingExample = nil
        }
        .onChange(of: json) { _, _ in message = nil }
        .confirmationDialog("작성 중인 내용을 예시로 바꿀까요?", isPresented: Binding(
            get: { pendingExample != nil },
            set: { if !$0 { pendingExample = nil } }
        ), titleVisibility: .visible) {
            if let example = pendingExample {
                Button("예시로 바꾸기") { json = example.json; pendingExample = nil }
            }
            Button("취소", role: .cancel) { pendingExample = nil }
        } message: {
            Text("지금 입력한 내용이 선택한 예시로 바뀝니다.")
        }
    }

    private func guideStep(_ number: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.mint).frame(width: 24, height: 24)
                .background(Palette.mint.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorNotice(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("JSON을 확인해 주세요").font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }.textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.tint("orange"))
        .padding(15).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.tint("orange").opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.tint("orange").opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func loadExample(_ example: TemplateImportExample) {
        let current = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty || TemplateImportExample.allCases.contains(where: { $0.json == current }) {
            message = nil
            json = example.json
        } else { pendingExample = example }
    }

    private func paste() {
        guard let copied = NSPasteboard.general.string(forType: .string),
              !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showError("복사된 내용이 없어요. JSON을 복사한 뒤 다시 눌러 주세요.")
            return
        }
        json = copied
    }

    private func validate() {
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showError("입력한 내용이 없어요. 예시를 불러오거나 JSON을 붙여넣어 주세요.")
            return
        }
        do {
            var template = try TemplateEngine.decode(json)
            template.id = UUID()
            message = nil
            onEdit(template)
        } catch let error as StatusError {
            showError(error.localizedDescription)
        } catch {
            showError("JSON을 읽을 수 없어요. 예시와 비교해 다시 확인해 주세요.")
        }
    }

    private func showError(_ text: String) {
        guard isVisible else { return }
        message = text
        DispatchQueue.main.async {
            guard isVisible, message != nil else { return }
            onError()
        }
    }
}
