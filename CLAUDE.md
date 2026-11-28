# stockdashboard 작업 안내

세 대시보드가 함께 따르는 규칙은 아래 파일에 있습니다. 먼저 읽고 따릅니다.

@DASHBOARD-RULES.md

## 이 저장소

- 이름: **JH 투자 DASHBOARD**(화면 제목, 메일 제목·머리, 보내는 사람). 개인 투자 참고용입니다.
- 페이지: https://jhkim0603.github.io/stockdashboard/ , 기본 가지는 `master` 입니다(다른 두 저장소는 `main`).
- 주요 파일
  - `Update-StockDashboard.ps1`: 시세·뉴스를 받아 `dashboard.html` 과 메일(`email-summary.html`, `email-subject.txt`)을 만듭니다.
  - `template.html`: 화면. 자료는 `const 이름 = …;` 자리에 들어갑니다.
  - `watchlist.json`(관심 종목), `buy-rules.json`(사용자 본인의 매수 기준: 분할 매수 단계, 이평선 도달), `market-calendar.json`(해마다 갱신)
  - `backtest/`: 매수 기준의 과거 10년 검증. 규칙을 바꾸면 다시 돌려 `backtest-stats.json` 을 새로 만듭니다.
  - `news-filter.ps1`, `mail_charts.py`: work-dashboard 와 똑같은 파일입니다. 고치면 두 저장소를 같이 고칩니다.

## 실행과 확인

- 로컬 실행(Windows PowerShell 5.1, 브라우저를 열지 않음, 몇 분): `$env:CI = "1"; .\Update-StockDashboard.ps1`
- 로컬 실행 뒤 되돌릴 파일(봇이 관리): `translation-cache.json`, `earnings-cache.json`, `target-cache.json`, `signal-log.json`, `indicator-cache.json`, `.last-digest`
- 이 PC 는 C 드라이브가 거의 차 있습니다. 로컬 실행과 크롬 점검 전에 `$env:TEMP`, `$env:TMP` 를 D 드라이브 폴더로 바꾸고, 크롬 프로필도 D 드라이브에 둡니다.
- 메일 그림 확인: `python mail_charts.py stock dashboard.html <메일 파일 복사본>` (원본 `email-summary.html` 은 건드리지 않게 복사본에 넣습니다)
- 화면 스크립트는 즉시 실행 함수 안에 있어 종목 자료가 전역 변수가 아닙니다. 브라우저 점검은 화면(DOM)으로 합니다.
- 시험 실행: `gh workflow run update-dashboard.yml -R JHKim0603/stockdashboard -f send_email=false` (아무것도 주지 않으면 메일이 나갑니다)

## 이 저장소의 색과 표현

- 상승은 빨강(`--rise`), 하락은 파랑(`--fall`)입니다(국내 증권 앱과 같음). 분할 매수 단계는 청록(강조색)으로만 표시합니다.
- 공포·탐욕지수는 행동 색입니다. 매수 구간 초록, 매도 구간 빨강(`--good`/`--bad`).
- 여러 종목을 겹쳐 비교하는 선에는 빨강과 파랑을 쓰지 않습니다.
- 매수 신호는 사용자 본인 규칙을 그대로 적용한 표시이고 매매 권유가 아니라는 문장을 화면과 메일에 둡니다.
- 메일 순서: 오늘의 브리핑(결론 포함) → 그림(매수 단계 지도, 공포·탐욕 1년) → 지금 주목할 점 → 기간별 등락 → 관련 지표 → 다가오는 일정 → 종목별 상세.
- 관련 지표(2026-11-23)는 인증키 없이 받는 공개 자료만 씁니다: 메모리 현물가(DRAMeXchange), 국내 증시 자금(금융투자협회), 외국인 매매(네이버 증권), VIX, 코인 공포·탐욕지수(Alternative.me). 외국인 순매수는 빨강, 순매도는 파랑입니다.
- 결론은 오늘 새로 생긴 신호만, 브리핑은 개수와 상태만, 카드 위 해설은 다음 매수 기준선만 말합니다(2026-11-17 정리).
- 개인 값(보유 수량·평단·종목 예산·투자 가능 현금·달러 자산 매수 환율)은 브라우저의 `stock-holdings-v1` 에만 둡니다. 맨 위 '내 계좌' 줄도
  그 값으로만 그리고, 보유가 없으면 숨습니다. 저장소, 메일, 공개 화면의 자료에는 넣지 않습니다(2026-11-28).
