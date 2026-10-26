# 통계 항목 템플릿

Mac Status는 JSON 설정을 같은 통계 카드로 렌더링합니다. 새 서비스를 추가할 때 앱 코드를 다시 빌드하지 않아도 됩니다. 템플릿은 **API 자동 조회**(읽기 전용 HTTP GET) 또는 **숫자 수동 입력**을 지원하며 코드, 셸 명령, JavaScript를 실행하지 않습니다. API 자동 조회에서는 **숫자 통계**와 **JSON 값 그대로** 중 표시 방식을 고를 수 있습니다.

앱에서 **API 숫자 통계**를 선택하면 직접 주소와 `A.B.C` 경로를 입력할 수 있습니다. AI용 생성 프롬프트로 JSON 템플릿을 만든 뒤 가져오는 방법도 지원합니다. 조회할 API가 없는 통계는 **숫자 수동 입력** 항목으로 만드세요. AI가 생성한 엔드포인트와 필드는 실제 문서에서 확인하세요.

`kind: "http"`는 API 자동 조회 편집 화면으로, `kind: "manual"`은 숫자 수동 입력 편집 화면으로 열립니다. 편집 화면에서 두 방식 사이를 전환하는 선택기는 없습니다. 수동 입력에는 기본 표시 설정과 현재 값·단위·선택 한도·바로가기를 표시하고, API 연결·인증·새로고침 설정은 표시하지 않습니다. API 자동 조회에는 현재 값을 직접 입력하는 칸이 없습니다.

## API 주소·JSON 경로로 값 불러오기

1. 새 항목에서 **API 숫자 통계**를 선택하고 **API 연결** 탭을 엽니다. 숫자를 가져올 때는 기본 **숫자 통계**를 사용하고, 값을 계산 없이 표시하려면 **불러올 값 → JSON 값 그대로**를 선택합니다. 기존 API 항목도 같은 설정을 사용할 수 있습니다.
2. JSON을 반환하는 GET 주소와 값의 위치를 입력합니다. 예를 들어 응답이 `{"A":{"B":{"C":42}}}`이면 두 표시 방식 모두 경로에 `A.B.C`를 입력해 `42`를 가져옵니다. 이름은 대소문자를 구분하며, 배열의 첫 항목은 `data.0.value`처럼 지정합니다. JSON 값 그대로 모드는 정확한 경로만 사용하므로 `*`는 사용할 수 없습니다.
3. 공개 API는 키 없이 **연결 테스트**를 누르면 됩니다. 인증이 필요할 때만 **인증** 탭에 보안 키와 인증 방식을 설정한 뒤 저장합니다.

다음 템플릿은 입력 형식만 보여 주는 가상 예시입니다. `example.com`을 실제 API 주소로 바꿔야 조회됩니다.

```json
{
  "name": "내 JSON 값",
  "kind": "http",
  "valueMode": "json",
  "endpoint": "https://example.com/api/status",
  "valuePath": "A.B.C",
  "unit": "",
  "limit": null,
  "authHeader": "",
  "authPrefix": "",
  "refreshInterval": 60
}
```

**JSON 값 그대로**는 숫자·문자열·불리언·객체·배열을 표시합니다. 단위·한도·합계·배율을 적용하지 않습니다. 연결 실패, JSON 파싱 실패, 경로 누락 또는 응답의 `null`은 화면에 `null`로 표시하며 이전 성공 값을 유지하지 않습니다. 상세 화면에서 사유를 확인할 수 있고, 다음 조회가 성공하면 새 값으로 바뀝니다. 실제 `0`과 `false`는 `null`로 바꾸지 않으며 빈 문자열은 `""`로 표시합니다. 선택한 값의 표시 길이가 4,096자를 넘으면 `null`과 함께 더 안쪽 경로를 지정하라는 안내를 표시합니다.

## 기본 형식

```json
{
  "name": "내 서비스",
  "kind": "http",
  "subtitle": "이번 달 사용량",
  "symbol": "chart.bar.fill",
  "tint": "mint",
  "unit": "GB",
  "limit": null,
  "endpoint": "https://example.com/api/usage",
  "valuePath": "usage.used",
  "limitPath": "usage.limit",
  "aggregation": "first",
  "multiplier": 1,
  "headers": {},
  "authHeader": "Authorization",
  "authPrefix": "Bearer ",
  "refreshInterval": 60,
  "link": "https://example.com/dashboard"
}
```

`name`과 `kind`는 필수입니다. API 자동 조회(`kind: "http"`)에는 `endpoint`와 `valuePath`도 필요합니다. 숫자 수동 입력(`kind: "manual"`)은 `manualValue`에 입력한 숫자를 저장합니다. `manualValue: null`은 미설정 상태이며 실제 0과 구분합니다. 기존 JSON의 `http`·`manual` 값은 그대로 사용합니다.

| 필드 | 의미 |
| --- | --- |
| `valueMode` | `number`: 숫자 통계(기본값), `json`: 선택한 JSON 값 그대로 표시. 생략한 기존 템플릿은 숫자 통계로 유지 |
| `valuePath` | 점으로 구분한 JSON 경로. `usage.total`, `data.0.value`, `data.*.value` |
| `limitPath` | 숫자 통계에서 한도를 읽는 단일 숫자 경로. 비어 있으면 `limit` 사용 |
| `valueExpression` | 값 경로에서 읽은 숫자에 적용할 계산식. 예: `value * 2`. 생략·빈칸은 원래 숫자 사용 |
| `limitExpression` | 한도 경로에서 읽은 숫자에 적용할 독립 계산식. `limitPath`가 있을 때만 사용 |
| `aggregation` | 숫자 통계의 단일 숫자는 `first`, 여러 숫자의 합은 `sum` |
| `multiplier` | 숫자 통계의 계산식을 적용한 값과 API 한도에 마지막으로 곱할 단위 변환 배율 |
| `limit` | 숫자 통계에서 표시할 고정 한도. `null`은 한도 없이 표시 |
| `refreshInterval` | 초 단위, 3~86,400 |
| `headers` | 비밀이 아닌 추가 헤더. 예: `anthropic-version` |
| `authHeader`, `authPrefix` | 별도 보안 키를 전달할 헤더와 접두어 |
| `symbol`, `tint` | SF Symbols 이름, mint/blue/purple/orange |

`x-api-key` 인증은 `authHeader: "x-api-key"`, `authPrefix: ""`로 설정합니다. 실제 키는 앱의 보안 키 필드에 입력하며 macOS 키체인에 저장됩니다. 템플릿, URL, 일반 헤더에 토큰·Cookie·비밀번호를 넣을 수 없습니다. 템플릿을 내보내도 키는 포함되지 않습니다.

인증 없는 공개 API는 보안 키를 입력하지 않고 `authHeader: ""`, `authPrefix: ""`로 설정하세요.

## 앱의 입력 예시와 서비스 설정

항목 편집의 **API 연결** 또는 **인증** 탭에서 **입력 예시 · 설정 방법**을 누르면 상세 안내가 열립니다. 설명은 읽기 전용이며, 현재 입력값이나 보안 키를 자동으로 바꾸지 않습니다. 숫자 수동 입력 화면에는 이 API 설정을 표시하지 않습니다.

API 문서에서 JSON을 반환하는 GET 주소를 찾고, 필요한 기간·프로젝트 등 조건을 URL의 쿼리에 넣습니다. 숫자 통계는 해당 경로의 숫자를 계산에 사용하고, JSON 값 그대로는 선택한 값을 표시합니다. 이 앱은 요청 본문(body)을 보내지 않습니다. 다음 주소와 응답은 숫자 통계 입력 형식만 설명하기 위한 가상 예시입니다.

```text
GET https://example.com/api/usage?period=month
```

```json
{
  "usage": {
    "current": 42,
    "limit": 100
  }
}
```

앱에 `valuePath: "usage.current"`, `limitPath: "usage.limit"`, `aggregation: "first"`, `multiplier: 1`을 입력하면 이 설명용 응답에서는 값 42와 한도 100을 읽습니다. `example.com`은 실제 조회 서비스가 아니므로 서비스의 공식 주소·쿼리·응답 경로로 바꿔야 합니다.

인증이 필요한 API는 서비스의 개발자·관리자 콘솔에서 해당 조회 API에 쓸 수 있는 키를 준비합니다. 사용량·비용 GET API의 읽기 권한, 조회할 조직·프로젝트 범위, 만료·비활성 상태와 접근 제한을 확인하세요. 키가 모델 호출에 사용된다고 해서 조직의 비용 조회 권한도 있다는 뜻은 아닙니다.

| 서비스 문서의 인증 방식 | 인증 헤더 | 키 앞에 붙일 값 | API 키 입력 |
| --- | --- | --- | --- |
| Bearer | `Authorization` | `Bearer ` — 마지막 공백 한 칸 포함 | 발급받은 실제 키만 입력 |
| x-api-key | `x-api-key` | 빈칸 | 발급받은 실제 키만 입력 |
| 인증 없음 | 빈칸 | 빈칸 | 빈칸 |

키와 토큰은 예시 JSON이나 URL에 넣지 않고 앱의 보안 키 칸에 입력합니다. 설정 후 **연결 테스트**로 값이 읽히는지 확인하고 저장합니다. 채팅 구독의 5시간·주간 한도와 이 API 통계는 구분됩니다.

## 날짜 변수

URL에서 다음 변수를 사용할 수 있습니다. 달 경계는 UTC 기준입니다.

- `{{month_start_unix}}`: 이번 달 1일 00:00 UTC, Unix 초
- `{{now_unix}}`: 현재 시각, Unix 초
- `{{month_start_iso}}`: 이번 달 1일 ISO 8601 시각

## API 비용과 토큰

`Templates/openai-monthly-cost.json`은 OpenAI 조직 Costs API의 `amount.value`를 합산합니다. 조직 사용량 조회 권한이 있는 **Admin API key**를 보안 키 필드에 입력해야 합니다. ChatGPT/Codex 구독 사용량과 별도인 **API 조직 비용**이며, 일반 모델 호출용 키로 조회되지 않을 수 있습니다. [OpenAI Costs API 문서](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/costs)를 참고하세요.

`Templates/openai-monthly-input-tokens.json`은 Completions Usage API의 `input_tokens`를 합산합니다. 캐시를 포함하는 입력 토큰 수이며 출력 토큰은 제외합니다. 출력 토큰을 별도로 보려면 이름을 바꾸고 `valuePath`를 `data.*.results.*.output_tokens`로 바꾸세요. [OpenAI Usage API 문서](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/completions)를 참고하세요.

두 예시는 UTC 이번 달을 최대 31개의 일별 버킷으로 요청합니다. API가 `has_more: true`를 반환하면 합계를 표시하지 않습니다. 범용 템플릿은 페이지를 자동으로 순회하지 않으므로 기간과 `limit`을 조정해 전체 응답을 가져오세요. 단순 토큰 수에 임의의 모델 단가를 곱해 실제 청구 비용처럼 표시하지 않습니다.

`Templates/anthropic-monthly-cost.json`은 Anthropic 조직 Cost Report의 `amount`를 합산합니다. API의 금액은 센트 단위 십진 문자열이므로 `multiplier: 0.01`로 USD로 변환합니다. 이 비용 API에는 Priority Tier 비용이 포함되지 않습니다. [Anthropic Usage and Cost API 문서](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)와 [Cost Report 스키마](https://platform.claude.com/docs/en/api/beta/organization/cost_report/retrieve)를 참고하세요.

`Templates/anthropic-monthly-input-tokens.json`은 `uncached_input_tokens`만 합산합니다. 캐시 읽기/쓰기와 출력은 제외한 값입니다. `output_tokens`, `cache_read_input_tokens`, `cache_creation.ephemeral_5m_input_tokens`, `cache_creation.ephemeral_1h_input_tokens`는 각각 별도 항목으로 만들 수 있습니다. [Messages Usage Report 스키마](https://platform.claude.com/docs/en/api/beta/organization/usage_report/retrieve_messages)를 참고하세요.

Anthropic 기본 예시는 Admin API 키를 보안 키 필드에 입력하고 `authHeader: x-api-key`, 빈 `authPrefix`, `headers`의 `anthropic-version: 2023-06-01`을 사용합니다. 현재 공식 문서는 Admin 키 외에 `org:admin` OAuth 토큰과 워크스페이스에 묶이지 않은 개인·서비스 계정 키 등 Admin API 자격 증명도 지원합니다. 워크스페이스 범위 키는 사용할 수 없으며, 다른 자격 증명은 공식 문서의 인증 헤더에 맞춰 설정합니다. Claude Code 구독 사용량과 API 조직 비용은 별도입니다. 두 예시도 UTC 이번 달의 일별 버킷을 최대 31개 요청하며 페이지가 남으면 합계를 표시하지 않습니다. [Anthropic 공식 사용량·비용 인증 안내](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)

## 데이터 해석과 실패 처리

숫자 통계의 **값 계산식**과 **한도 계산식**은 각각 해당 경로에서 읽은 숫자를 `value`로 사용합니다. 예를 들어 경로가 `A.B.C`이고 응답의 숫자가 25일 때 `value * 2`는 50, `(value + 5) / 2`는 15입니다. 한도 경로의 숫자가 100이면 한도 계산식 `value / 2`는 한도 50을 만듭니다. 두 식은 서로의 값을 참조하지 않습니다.

계산 순서는 **숫자 추출 또는 합계 → 각 계산식 → 값 배율**입니다. 계산식은 생략하거나 비울 수 있으며, 한도 경로가 없으면 한도 계산식을 사용하지 않습니다. 고정 `limit`은 표시 단위 기준의 값을 그대로 사용합니다. `JSON 값 그대로` 모드에는 계산식을 적용하지 않습니다.

계산식은 `value`, 유한한 숫자, `+ - * /`, 괄호와 부호만 허용합니다. 곱셈·나눗셈을 먼저 계산하며 괄호로 순서를 지정할 수 있습니다. 일반 코드·함수는 실행하지 않습니다. 식은 최대 512바이트·256토큰·32단계 깊이로 제한합니다.

`value / 0`, `value / (value - value)`처럼 0으로 나누거나 중간 계산이 유한한 숫자를 벗어나면 결과 전체를 `null`로 표시합니다. 계산한 한도가 0 이하인 경우도 `null`입니다. 카드·상세·상단바에서 이전 정상 값이나 0으로 대체하지 않으며 다음 조회의 계산이 성공하면 새 숫자를 표시합니다. 실제 계산 결과 0은 정상적인 0으로 표시합니다. 잘못된 계산식 문법은 입력칸의 빨간 `*`로 안내합니다.

**숫자 통계**에서는 숫자 또는 숫자로 된 문자열만 계산에 사용합니다. `sum`에서 명시적인 빈 배열의 합계는 0입니다. 예를 들어 사용 내역이 없는 달의 `data: []` 또는 `results: []`는 비용 0으로 표시할 수 있습니다. 경로 누락, `null`, 불리언, 일부 항목의 필드 누락은 0으로 바꾸지 않습니다. `first`에서 빈 배열은 오류입니다. 합계에는 실제로 존재하는 모든 항목에 해당 경로가 있어야 합니다. `first` 경로가 여러 숫자를 반환하면 첫 번째 숫자만 임의로 고르지 않고 오류를 표시합니다.

**JSON 값 그대로**에서는 선택한 값을 표시하며 조회할 수 없는 상태를 `null`로 구분합니다. 이 모드의 실패나 누락은 숫자 `0` 또는 마지막 성공 값으로 대체하지 않습니다.

`sum` 응답의 `has_more: true` 또는 비어 있지 않은 `next_page`는 불완전한 합계로 처리합니다. 페이지 필드의 자료형이 잘못되어도 추측하지 않고 오류를 표시합니다. API 키는 앞뒤 공백과 줄바꿈 없이 입력하세요. 자동 갱신은 키체인 권한 창을 반복해서 띄우지 않으며, 키 접근이 차단되면 연결 설정에서 키를 다시 저장해야 합니다.

HTTPS를 사용하세요. 로컬 도구에 한해 `localhost`, `127.0.0.1`, `::1`의 HTTP를 허용합니다. 인증 정보가 다른 서버로 전달되지 않도록 다른 출처로의 리디렉션을 거부합니다. 요청은 임시 세션에서 수행하며 Cookie를 저장하지 않습니다. 응답은 최대 1 MiB, 요청 시간은 최대 20초입니다.

`Templates/custom-json-api.json`은 로컬 JSON 서버의 형식 예시입니다. 해당 서버가 실제로 실행 중이어야 하며, 앱은 예제 서버를 자동으로 시작하지 않습니다.
