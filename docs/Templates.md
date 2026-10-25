# 통계 항목 템플릿

Mac Status는 JSON 설정을 같은 통계 카드로 렌더링합니다. 새 서비스를 추가할 때 앱 코드를 다시 빌드하지 않아도 됩니다. 템플릿은 **API 자동 조회**(읽기 전용 HTTP GET) 또는 **숫자 수동 입력**을 지원하며 코드, 셸 명령, JavaScript를 실행하지 않습니다.

앱에서 항목 추가 → AI용 생성 프롬프트를 복사해 원하는 AI에 요청한 다음, 생성된 JSON을 가져오세요. 실제 공식 API가 없는 서비스는 **숫자 수동 입력** 항목으로 만들어야 합니다. 생성된 엔드포인트와 필드가 실제 문서에 있는지 확인하세요.

`kind: "http"`는 API 자동 조회 편집 화면으로, `kind: "manual"`은 숫자 수동 입력 편집 화면으로 열립니다. 편집 화면에서 두 방식 사이를 전환하는 선택기는 없습니다. 수동 입력에는 기본 표시 설정과 현재 값·단위·선택 한도·바로가기를 표시하고, API 연결·인증·새로고침 설정은 표시하지 않습니다. API 자동 조회에는 현재 값을 직접 입력하는 칸이 없습니다.

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
| `valuePath` | 점으로 구분한 JSON 경로. `usage.total`, `data.0.value`, `data.*.value` |
| `limitPath` | API에서 한도를 읽는 단일 숫자 경로. 비어 있으면 `limit` 사용 |
| `aggregation` | 단일 숫자는 `first`, 여러 숫자의 합은 `sum` |
| `multiplier` | API 숫자와 API 한도에 곱할 단위 변환 배율 |
| `limit` | 표시 단위의 고정 한도. `null`은 한도 없이 표시 |
| `refreshInterval` | 초 단위, 3~86,400 |
| `headers` | 비밀이 아닌 추가 헤더. 예: `anthropic-version` |
| `authHeader`, `authPrefix` | 별도 보안 키를 전달할 헤더와 접두어 |
| `symbol`, `tint` | SF Symbols 이름, mint/blue/purple/orange |

`x-api-key` 인증은 `authHeader: "x-api-key"`, `authPrefix: ""`로 설정합니다. 실제 키는 앱의 보안 키 필드에 입력하며 macOS 키체인에 저장됩니다. 템플릿, URL, 일반 헤더에 토큰·Cookie·비밀번호를 넣을 수 없습니다. 템플릿을 내보내도 키는 포함되지 않습니다.

인증 없는 공개 API는 `authHeader: ""`로 설정하세요.

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

Anthropic 예시는 Admin API 키를 보안 키 필드에 입력해야 합니다. `authHeader: x-api-key`, 빈 `authPrefix`, `headers`의 `anthropic-version: 2023-06-01`을 사용합니다. Claude Code 구독 OAuth 사용량과 API 조직 비용은 별도입니다. 두 예시도 UTC 이번 달의 일별 버킷을 최대 31개 요청하며 페이지가 남으면 합계를 표시하지 않습니다.

## 데이터 해석과 실패 처리

숫자 또는 숫자로 된 문자열만 표시합니다. `sum`에서 명시적인 빈 배열의 합계는 0입니다. 예를 들어 사용 내역이 없는 달의 `data: []` 또는 `results: []`는 비용 0으로 표시할 수 있습니다. 경로 누락, `null`, 불리언, 일부 항목의 필드 누락은 0으로 바꾸지 않습니다. `first`에서 빈 배열은 오류입니다. 합계에는 실제로 존재하는 모든 항목에 해당 경로가 있어야 합니다. `first` 경로가 여러 숫자를 반환하면 첫 번째 숫자만 임의로 고르지 않고 오류를 표시합니다.

`sum` 응답의 `has_more: true` 또는 비어 있지 않은 `next_page`는 불완전한 합계로 처리합니다. 페이지 필드의 자료형이 잘못되어도 추측하지 않고 오류를 표시합니다. API 키는 앞뒤 공백과 줄바꿈 없이 입력하세요. 자동 갱신은 키체인 권한 창을 반복해서 띄우지 않으며, 키 접근이 차단되면 연결 설정에서 키를 다시 저장해야 합니다.

HTTPS를 사용하세요. 로컬 도구에 한해 `localhost`, `127.0.0.1`, `::1`의 HTTP를 허용합니다. 인증 정보가 다른 서버로 전달되지 않도록 다른 출처로의 리디렉션을 거부합니다. 요청은 임시 세션에서 수행하며 Cookie를 저장하지 않습니다. 응답은 최대 1 MiB, 요청 시간은 최대 20초입니다.

`Templates/custom-json-api.json`은 로컬 JSON 서버의 형식 예시입니다. 해당 서버가 실제로 실행 중이어야 하며, 앱은 예제 서버를 자동으로 시작하지 않습니다.
