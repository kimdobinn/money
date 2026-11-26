# Brokers — 토스증권 + IBKR 통합 포트폴리오 (macOS)

메뉴바 · 대시보드 · 바탕화면 위젯으로 두 증권사 보유 종목을 합산해서 보여주는 개인용 앱.

```
IB Gateway ─┐                 ┌─ 메뉴바 (총자산 · 오늘 등락)
IBKR Flex  ─┼─▶ brokerd ──HTTP─┼─ 대시보드 창 (차트 · 비중 · 합산 테이블)
토스 Open API┘  (127.0.0.1:8765) └─ 위젯 (small / medium / large)
```

- `helper/` — Python 백그라운드 헬퍼 `brokerd`. LaunchAgent로 로그인 시 자동 실행·자동 재시작. 데이터 수집, 합산, 5분 스냅샷, 히스토리 복원.
- `app/` — SwiftUI 앱(메뉴바 + 창 + 설정)과 WidgetKit 위젯. `xcodegen`으로 프로젝트 생성.
- 주문 기능은 코드에 없음. IBKR은 `readonly=True`로 접속, 토스는 조회 API만 호출.
- 키·토큰은 macOS Keychain(`com.brokers.helper`)에만 저장.

## 설치 / 업데이트

```bash
~/Brokers/helper/install.sh     # 헬퍼 설치·재시작
~/Brokers/app/build.sh          # 앱 빌드 → /Applications/money.app 설치·실행
```

앱은 로그인 시 자동 실행됩니다(설정 > 표시에서 끌 수 있음). Spotlight로 Brokers를 다시 실행하면 대시보드가 열립니다.
위젯: 바탕화면 우클릭 > 위젯 편집 > "Brokers" 검색.

계정을 연결하기 전까지는 **데모 데이터**가 표시됩니다.

## 1. 토스증권 연결

1. 토스증권 웹(WTS) 로그인 > 설정 > **Open API** > 클라이언트 등록 → `client_id`, `client_secret` 발급
2. 같은 화면 하단 **허용 IP 관리**에 Mac mini의 공인 IP 등록
   (앱 설정 > 계정 연결에 현재 공인 IP와 복사 버튼이 있음)
3. 앱 설정 > 계정 연결 > 토스증권에 붙여넣고 저장

> 공인 IP가 바뀌면 토스가 403으로 차단합니다. 앱이 "허용 IP가 아닙니다"를 표시하면 새 IP를 다시 등록하세요.
> 싱가포르 가정용 회선은 IP가 가끔 바뀔 수 있어요 — 자주 바뀌면 통신사 고정 IP 옵션을 고려.

## 2. IBKR — IB Gateway (실시간)

1. IBKR 웹사이트에서 **IB Gateway (Stable)** 설치 → IBKR 계정으로 로그인 (IBKR Mobile 2FA)
2. Gateway > Configure > Settings > **API > Settings**
   - Enable ActiveX and Socket Clients ✅
   - **Read-Only API ✅** (주문 불가 상태로 고정)
   - Socket port **4001**
   - Trusted IPs: 127.0.0.1
3. Settings > **Lock and Exit** > Auto restart 선택 → 매일 재시작돼도 로그인 유지 (일요일마다 1회 재로그인 + 2FA)
4. 시스템 설정 > 일반 > 로그인 항목에 IB Gateway 추가

Gateway가 꺼져 있으면 앱은 자동으로 Flex(전일 기준) 데이터로 전환하고 "전일 기준" 배지를 표시합니다.

## 3. IBKR — Flex Web Service (백업 + 거래내역)

1. IBKR 포털 > Performance & Reports > **Flex Queries** > Activity Flex Query 생성
   - Sections: **Open Positions**(Summary), **Cash Report**, **Trades**(Execution), **Conversion Rates**
   - Period: **Last 365 Calendar Days**, Format: **XML**
   - 저장 후 Query ID 확인
2. 같은 페이지 **Flex Web Service Configuration** > 활성화 → Token 생성 (만료일 확인, 최대 1년)
3. 앱 설정 > 계정 연결 > Flex에 Token, Query ID 입력 후 저장

## 히스토리

- 헬퍼가 5분마다 총자산을 기록 (`~/Library/Application Support/Brokers/brokers.sqlite3`)
- 계정을 처음 연결하면 토스 거래내역 + Flex 거래내역 + 과거 일별 종가로 과거 자산 추이를 자동 복원 (설정 > 히스토리에서 재실행)
- 복원된 과거 구간은 평가금액만 있고 투자원금 선은 실시간 기록 구간부터 표시됩니다

## 계산 방식

- 합산 평단 = Σ(브로커별 수량 × 브로커 평단) ÷ 총 수량 (종목의 거래 통화 기준, 미국주식은 USD)
- 현재가: 토스 시세 API(실시간) 우선, 없으면 브로커 제공 가격
- 오늘 손익: (현재가 − 전일 종가) × 수량. 오늘 산 종목은 전일 종가 기준이라 실제와 다를 수 있음
- 환율: USD/KRW는 토스, SGD 등은 IBKR, 없으면 ECB 기준(frankfurter) 사용
- 현금: 토스 매수가능금액(KRW·USD) + IBKR 통화별 현금

## 문제 해결

- 로그: `~/Library/Logs/Brokers/brokerd.log`
- 헬퍼 상태: `curl -s 127.0.0.1:8765/v1/status | python3 -m json.tool`
- 헬퍼 재시작: `launchctl kickstart -k gui/$(id -u)/com.brokers.helper`
- 헬퍼 제거: `launchctl bootout gui/$(id -u)/com.brokers.helper && rm ~/Library/LaunchAgents/com.brokers.helper.plist`
