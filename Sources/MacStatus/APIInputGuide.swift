import SwiftUI

enum APIInputGuideTopic {
    case connection, authentication

    var title: String { self == .connection ? "API 연결 입력 예시" : "인증 입력 예시" }
}

struct APIInputGuideButton: View {
    let topic: APIInputGuideTopic
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Label("입력 예시 · 설정 방법", systemImage: "questionmark.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.mint)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Palette.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize()
        .accessibilityLabel(topic.title + "와 설정 방법")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            APIInputGuide(topic: topic) { isPresented = false }
        }
    }
}

private struct APIInputGuide: View {
    let topic: APIInputGuideTopic
    let close: () -> Void

    private var guideHeight: CGFloat { max(300, min(640, (NSScreen.main?.visibleFrame.height ?? 900) - 100)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(topic.title).font(.system(size: 16, weight: .semibold))
                    Text("예시는 설명용입니다. 입력한 설정을 바꾸지 않습니다.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 8)
                QuietIconButton(symbol: "xmark", label: "안내 닫기", action: close)
            }.padding(20)
            Divider().overlay(Palette.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if topic == .connection { connectionGuide }
                    else { authenticationGuide }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.never)
        }
        .frame(width: 510, height: guideHeight)
        .background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
    }

    private var connectionGuide: some View {
        Group {
            section("서비스 API에서 준비할 것") {
                paragraph("공식 문서에서 숫자를 조회하는 HTTPS GET 주소를 찾으세요. 이 앱은 주소의 쿼리 값으로 조회 기간 등을 전달하며, 요청 본문(body)을 보내지 않습니다.")
                paragraph("응답은 숫자가 들어 있는 JSON이어야 합니다. 조회할 기간·조직·프로젝트와 필요한 인증 권한도 확인하세요.")
            }
            section("요청 주소와 응답 예시") {
                code("GET " + APIGuideExamples.endpoint)
                Text("example.com은 가상의 설명용 주소입니다. 실제 조회 주소로 바꿔야 합니다.")
                    .font(.system(size: 11)).foregroundStyle(Palette.tint("orange"))
                Text("서비스가 아래 JSON을 반환한다고 가정합니다.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                code(APIGuideExamples.singleResponse)
            }
            section("앱에는 이렇게 입력하세요") {
                exampleRow("API 주소 · GET", APIGuideExamples.endpoint)
                exampleRow("값 JSON 경로", "usage.current")
                exampleRow("한도 JSON 경로", "usage.limit")
                exampleRow("여러 값 처리", "단일 값")
                exampleRow("값 배율", "1")
                paragraph("이 예시의 표시 값은 42, 한도는 100입니다. 한도가 응답에 없으면 한도 JSON 경로를 비우세요.")
            }
            section("배열 합계와 단위 변환") {
                code(APIGuideExamples.sumResponse)
                exampleRow("값 JSON 경로", "data.*.count")
                exampleRow("여러 값 처리", "합계 → 20")
                paragraph("배열의 첫 숫자 하나는 data.0.count처럼 지정합니다. 금액이 센트 단위라면 값 배율을 0.01로, 이미 달러라면 1로 설정하세요.")
            }
            section("기간과 연결 확인") {
                paragraph("API 문서의 쿼리 이름을 사용하세요. URL의 {{month_start_unix}}, {{now_unix}}, {{month_start_iso}}는 UTC 기준 시각으로 바뀝니다.")
                paragraph("여러 페이지로 나뉘는 API는 기간·limit을 조정해 전체 결과가 한 응답에 들어오게 하세요. 설정을 마친 뒤 아래 ‘연결 테스트’를 눌러 확인합니다.")
            }
        }
    }

    private var authenticationGuide: some View {
        Group {
            section("서비스에서 준비할 것") {
                paragraph("인증이 필요한 API는 서비스의 개발자·관리자 콘솔에서 키를 발급하세요. 조회하려는 사용량·비용 GET API를 읽을 수 있는 권한이 있어야 합니다.")
                paragraph("키의 조직·프로젝트 범위가 조회 대상과 일치하는지, 만료·비활성 상태나 IP 접근 제한이 없는지 확인하세요. 서비스가 요구하는 API 이용 조건도 확인합니다.")
                paragraph("이 화면은 API 통계용입니다. 채팅 구독의 5시간·주간 사용 한도와는 구분됩니다.")
            }
            section("1 · Bearer 인증") {
                exampleRow("API 키", "서비스에서 발급받은 실제 키")
                exampleRow("인증 헤더", "Authorization")
                exampleRow("키 앞에 붙일 값", "Bearer + 공백 한 칸")
                code("Authorization: Bearer <발급받은 키>")
                paragraph("키 칸에는 키 자체만 입력합니다. 접두어에는 Bearer 뒤에 공백을 한 칸 넣으세요.")
            }
            section("2 · x-api-key 인증") {
                exampleRow("API 키", "서비스에서 발급받은 실제 키")
                exampleRow("인증 헤더", "x-api-key")
                exampleRow("키 앞에 붙일 값", "빈칸")
                code("x-api-key: <발급받은 키>")
            }
            section("3 · 인증이 없는 공개 API") {
                paragraph("API 키·인증 헤더·키 앞에 붙일 값을 모두 비우세요. 키만 비우고 인증 헤더를 남겨 두면 키 연결이 필요한 항목으로 표시됩니다.")
            }
            section("사용량·비용용 키의 예") {
                paragraph("OpenAI 조직 사용량·비용 조회는 Admin API 키를 사용합니다. 일반 프로젝트 키로 대체할 수 없습니다.")
                Link("OpenAI Admin API 공식 문서", destination: APIProviderRequirement.openAIOrganization.documentationURL)
                    .font(.system(size: 11))
                paragraph("Anthropic 조직 사용량·비용 조회는 Admin 키, org:admin OAuth 토큰 또는 워크스페이스에 묶이지 않은 개인·서비스 계정 키 등 Admin API 자격 증명을 사용합니다. 해당 조직의 접근 권한이 필요합니다.")
                Link("Anthropic 사용량·비용 공식 문서", destination: APIProviderRequirement.anthropicOrganization.documentationURL)
                    .font(.system(size: 11))
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted)
            .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
    }

    private func code(_ text: String) -> some View {
        Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.mint)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func exampleRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(Palette.muted).frame(width: 112, alignment: .leading)
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
