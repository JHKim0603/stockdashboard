# Stock Dashboard

Local stock-summary dashboard. No backend, no build step — just PowerShell + a static HTML/JS template.

**Live:** https://jhkim0603.github.io/stockdashboard/ — republished daily by the GitHub Actions workflow.

## Files

- `DASHBOARD-RULES.md`: 세 대시보드(stockdashboard, work-dashboard, realestate-dashboard)가 똑같이 쓰는 작업 규칙입니다(문체, 글자 12px, 숫자 표기, 메일 모양, 작업 순서, 올리기 전 점검). 고치면 세 저장소를 같이 고칩니다. 실행 때마다 다른 저장소의 파일과 비교해 다르면 경고합니다.
- `CLAUDE.md`: 이 저장소만의 작업 안내(실행 방법, 봇이 관리하는 자료 파일, 색의 뜻). 공통 규칙을 불러옵니다.
- `Update-StockDashboard.ps1` — fetches live quotes (Yahoo Finance chart API, no key), recent
  headlines (Google News RSS, no key), quarterly financials + analyst consensus (Naver Finance,
  no key) for the tickers listed in `watchlist.json`, then renders `template.html` into
  `dashboard.html`.
- `watchlist.json` — the ticker list. Only `"Symbol"` is required. ETF 는 실적·목표주가가 없어
  `"FinanceMode": "none"` 으로 그 조회를 끄고, 자동 규칙이 맞히지 못하는 거래소 표기와 메일 가격 링크를 `"MarketLabel"`,
  `"PageUrl"` 로 직접 적습니다(예: QLD 는 NYSE Arca, `google.com/finance/quote/QLD:NYSEARCA`).
- `buy-rules.json` — 이평선 도달 매수 기준과 분할 매수 단계의 기준값.
- `backtest-stats.json` — 매수 신호의 과거 10년 성적(분야별). `backtest/backtest.py` 가 만들고 대시보드가 신호 옆에 붙입니다.
- `backtest/` — 매수 기준 과거 검증 도구와 결과(`backtest/README.md`).
- `template.html` — the dashboard UI: per-card 1M/3M/6M/1Y range toggle + 20/60/180일 이동평균선
  with a plain-language trend comment (cross event, 정배열/역배열), sparkline with hover tooltip,
  a "최근 이슈" news list (real article titles/links, not AI-written summaries), 실적/목표주가
  popups. See "What's on the page" below.
- `translation-cache.json` — English headline → Korean translations, committed back by the
  workflow so each run doesn't re-translate (and hit 429s) from an empty cache. `fix: 1` 은 'shares'를 '공유'로
  옮겨 한 번 더 번역한 항목입니다(다음 실행에서 다시 묻지 않음).
- `earnings-cache.json` — next earnings dates as fetched by the day's (KST) first run; later runs
  that day reuse them instead of asking Nasdaq again. Committed back by the workflow.
- `signal-log.json` — 신호 실전 기록부(신호가 켜진 날짜·종가·시장 지수 값, 분할 단계 구간). 스크립트가 쓰고 workflow 가 커밋합니다.
- `news-filter.ps1` — 뉴스 제목 거르기(`Test-SpamHeadline`). work-dashboard 와 같은 파일이며 워크플로가 서로 비교합니다.
- `target-cache.json` — 증권사 목표주가 평균의 날짜별 기록(종목마다 한 줄, 400일치). 전 기록과 비교해 바뀐 날을 알리는 데
  쓰므로 workflow 가 다른 캐시와 함께 커밋합니다. 로컬 실행 뒤에는 지우거나 `git checkout` 합니다.
- `indicator-cache.json` — 메모리 현물가(DRAMeXchange)의 조사일별 기록(품목마다 한 줄). 과거 시세가 회원 전용이라 직접 쌓으며,
  workflow 가 다른 캐시와 함께 커밋합니다. 로컬 실행 뒤에는 `git checkout` 합니다.
- `run.bat` — double-click launcher (bypasses PowerShell execution-policy prompts).
- `dashboard.html` — generated output, opened automatically after each run. Not tracked in git.
- `email-summary.html` / `email-subject.txt` — generated daily email body/subject. Written every run for local
  preview; actually *sending* it only happens in the GitHub Actions workflow. Not tracked in git.
  본문 순서는 페이지와 같습니다(2026-10-29): 지금 주목할 점, **오늘의 매수 단계**(분할 매수 3·2·1단계와 이평선 도달
  종목, 괄호 안은 52주 고점 대비 하락률), 공포·탐욕지수, **기간별 등락**(분야별 소제목에 오늘 상승·하락 종목 수, 오늘·1주·
  1개월·1년, 평소 등락 폭보다 크면 칸 색칠), **다가오는 일정 14일**, 종목별 상세(분야별, 추세, 매수 신호, 알림가, 실적, 기사 2건).
  지금 주목할 점에서는 단계별로 묶은 매수 단계 줄을 뺍니다(매수 단계 상자와 겹쳐서). 메일 크기는 약 45KB 입니다(Gmail 은
  102KB 가 넘으면 자릅니다).

## What's on the page

- **한눈 요약 (2026-10-28, work-dashboard 요약판을 옮겨 온 것)**: 카드 위 한 덩어리로 세 부분입니다.
  - **분야별 등락 지도** (Finviz 지도 방식): `watchlist.json` 의 `Group`(국내 반도체, 미국 반도체, 빅테크·AI, 시장 지수,
    레버리지 ETF, 코인; 없으면 시장으로 자동 분류)마다 한 줄, 종목마다 타일 하나. [오늘]·[1주]·[1개월]·[연초 대비]·[1년]으로 기간을 바꿔
    봅니다. 타일 색은 그 종목의 평소 등락 폭(같은 기간 수익률의 표준편차) 대비 0.4배·1배·2배를 넘을 때마다 진해집니다.
  - **지금 주목할 점**: 실적 발표 3일 이내, 52주 신고가·신저가와 고점 3% 이내, 20/60일선 교차, 거래량 평균의 2배 이상,
    하루 등락이 5%와 평소 폭의 2배를 모두 넘을 때, 알림가 돌파·이탈, 시장 대비 1개월 ±15%p 이상을 문장으로 최대 6개
    보여 줍니다(메일 맨 위에도 같은 목록). 줄을 누르면 해당 카드로 이동합니다.
  - **기간별 표**: 종목(최근 흐름) · 현재가 · 오늘 · 1주 · 1개월 · 연초 대비 · 1년 · 시장 대비(1개월, 국내는 코스피,
    미국은 나스닥과의 차이 %p) · 최근 6개월 추이선. 평소 폭보다 크면 칸을 옅게, 2배 이상이면 진하게 칠합니다. 머리글을
    누를 때마다 큰 순 → 작은 순 → 분야별 순서로 정렬합니다. 820px 미만에서는 종목별 카드 모양으로 바뀝니다.
- **이평선 도달 매수 기준 (2026-10-29)**: 이평선에 닿았을 때 사는 방식에 맞춰, 종목과 지수마다 20·60·180일선과의 거리를
  매일 잽니다(기준값은 `buy-rules.json`, 종목별로는 `watchlist.json` 의 `"BuyMA": [60, 120]`).
  - **닿음**: 그날 저가가 이평선 위 1% 안까지 내려왔고 종가가 이평선 아래 1%보다 높게 끝난 경우. 종가가 이평선 위 1% 밖이면 '장중 도달'.
  - **매수 기준 도달**: 닿았고, 5거래일 전 종가가 이평선 위 1% 밖에 있었던 경우(위에서 내려온 눌림목, `fromAboveOnly`)이면서
    52주 고점보다 20% 넘게 내려온 상태(`maMinDrawdownPct`, 2026-10-30 추가)입니다. 과거 10년 검증에서 고점 근처에서 닿은 경우는
    아무 날이나 산 것과 결과가 같아, 그런 경우는 '도달(참고)'로만 적고 지금 주목할 점에는 낮은 순위의 [이평선 참고]로 올립니다.
    아래에서 올라와 닿은 경우는 카드에 '(아래에서 닿음)'으로만 적습니다.
  - **매수 대기**: 종가가 이평선 위 3% 안(`nearPct`). 닿으면 매수 기준이 되는 경우(고점보다 20% 넘게 내려온 상태)만 알립니다.
  - 표시: 지금 주목할 점 맨 위([매수 기준], [매수 대기]), 등락 지도 타일의 '◎ 20일선 도달', 기간별 표의 '이평선' 칸, 카드 가격 줄
    배지와 '이평선과의 거리' 줄, 메일 종목 줄. 메일 제목에는 처음 닿은 날만 '샌디스크 180일선 도달'처럼 올립니다.
  - 그날 저가는 야후 일봉의 저가(장중이면 그때까지의 저가)입니다. 본인 매매 기준을 그대로 적용한 표시이며 매매를 권하는 것이 아닙니다.
- **분할 매수 단계 (2026-10-29)**: "120일선에 닿으면 사고 200일선에 닿으면 더 산다. 전고점 대비 −10%, −20%, −30%마다 더
  줍는다"는 QLD 적립식 매수법을 종목마다 그대로 적용합니다(기준값은 `buy-rules.json` 의 `dip`). 두 기준 중 높은 쪽이 그날의 단계입니다.
  - **분할 1단계**: 52주 고점보다 10% 이상 낮거나 120일선에 닿음.
  - **분할 2단계**: 52주 고점보다 20% 이상 낮거나 200일선에 닿음.
  - **분할 3단계**: 52주 고점보다 30% 이상 낮음.
  - 2026-10-30 과거 10년 검증 뒤 바꾼 점: 이름에서 '매수 추천·추가 매수 추천·매수 적극추천'을 뺐습니다(1·2단계는 아무 날이나 산 것과
    결과가 비슷했습니다). 지수는 120·200일선 단계 없이 고점 대비 하락만 봅니다(`dip.indexMaSteps`, 종목별로는 `"DipMA": []`).
    코인은 `watchlist.json` 의 `"DipSteps": [20, 40, 60]` 을 씁니다.
  - **과거 성적**: 켜진 신호마다 카드('과거 10년 성적')와 메일, 지금 주목할 점에 그 분야(지수, 개별 종목, 레버리지 ETF, 코인)의 과거 10년 성적을
    붙입니다. 예: '개별 종목에서는 이 신호 뒤 1년이 지나 46번 중 40번 올랐습니다(아무 날이나 샀을 때 71%). 산 뒤 3개월
    안에 중간값 10.0% 더 내려갔습니다.' 숫자는 `backtest-stats.json`(`backtest/backtest.py` 가 만듦)에서 오고, 5건 미만이면 붙이지
    않습니다. 기준을 바꾸면 `backtest/` 를 다시 돌려 이 파일을 새로 만들어야 합니다.
  - '닿음'은 이평선 도달 매수 기준과 같은 `touchPct`(1%)를 씁니다. 그날 저가가 선 위 1% 안까지 내려왔거나 선 아래에 있으면
    닿은 것으로 봅니다. 고점은 카드 요약 문장의 '52주 고점'과 같은 값(야후 52주 고가)입니다.
  - 드문 알림이 아니라 '오늘 얼마나 살 구간인가'를 말하는 표시라, 그 구간에 머무는 동안 계속 켜져 있습니다.
  - 표시: 지금 주목할 점(오늘 단계가 오른 종목은 한 줄씩, 이미 2단계 이상에 있던 종목은 단계별로 한 줄에 묶음), 등락 지도 타일과
    기간별 표 '이평선' 칸, 카드 가격 줄 배지와 근거 줄('52주 고점 대비 −47.7%(3단계 기준 −30%), 120일선 −17.9%(도달), 200일선 +2.5%'),
    메일 종목 줄. 메일 제목에는 2단계 이상으로 오른 날만 'SK하이닉스 분할 3단계'처럼 올립니다.
  - 기준 숫자가 2배 레버리지 QLD 에서 나온 것이라 변동성이 큰 종목일수록 자주 켜집니다. 5년치(2021-10~2026-10)로 돌려 보니
    3단계가 켜져 있던 날이 S&P 500 은 0%, 나스닥 3%, 마이크로소프트 4% 였고, 샌디스크 31%, 마이크론 29%, 이더리움 54% 였습니다.
    그런 종목은 `watchlist.json` 에 `"DipSteps": [20, 40, 60]` 처럼 단계를 넓게 적습니다.
  - 참고: [QLD 조건부 적립 프로젝트](https://github.com/keyonetwoonetwo/QLD-Indicator-Based-DCA-Trading-KB)는 QQQ 200일선 위아래,
    당일 양봉과 음봉, 공포·탐욕지수(10 미만, 45 미만, 그 이상)로 12칸 금액표를 만들어 '200일선 아래, 음봉, 공포'일 때 가장 많이
    삽니다. 같은 생각(빠질수록, 무서울수록 더 산다)이며, 이 대시보드는 그중 가격 기준만 단계로 보여 주고 공포·탐욕지수는 위쪽에 따로 둡니다.
  - 본인 매매 기준을 그대로 적용한 표시이며 매매를 권하는 것이 아닙니다.
- **오늘의 브리핑 (2026-10-30)**: 한눈 요약 맨 위와 메일 맨 위에 오늘 상황을 항목별 한두 문장으로 정리합니다(시장, 관심 종목,
  매수 신호, 심리·일정). 증권 앱의 AI 시장 요약처럼 읽히게 했지만 AI 를 부르지 않고 스크립트가 계산한 값으로 문장을 만듭니다
  (같은 데이터면 같은 문장이고 숫자가 틀릴 일이 없습니다). 나중에 AI 로 바꾸려면 이 부분(`$brief`)의 문장만 바꾸면 됩니다.
- **종목 한 줄 해설 (2026-10-30)**: 카드 가격 아래와 메일 종목 칸에 추세, 매수 신호, '다음 매수 기준선'(현재가 바로 아래의
  이평선이나 분할 매수 기준과 거리)을 문장으로 적습니다(`comment`). 해설 첫 문장이 추세라 카드의 따로 있던 추세 줄은 뺐습니다.
  값 뒤에 조사를 붙이지 않게 문장을 짰습니다(숫자 끝자리에 따라 '로/으로'가 바뀌므로).
- **접는 설명 (2026-10-30)**: 한눈 요약의 긴 설명은 첫 문장만 두고 [표시 읽는 법]으로 접었습니다. 지금 주목할 점은 5건만
  먼저 보이고 [나머지 N건 더 보기]로 펼칩니다. 기간이나 정렬을 바꿔도 펼친 상태는 유지됩니다.
- **맨 위 시장 띠 (2026-10-30, 토스증권·구글 금융 벤치마킹)**: KOSPI, KOSDAQ, 나스닥, S&P 500, 필라델피아 반도체, VIX,
  원/달러 환율, 비트코인을 한 줄로 보여 줍니다. 값, 직전 거래일 대비 등락, 최근 1개월 작은 그래프입니다. 관심 종목에 있는 것은
  그 데이터를 쓰고 없는 것(KOSDAQ, 필라델피아 반도체, VIX)만 3개월치를 따로 받습니다. 누르면 카드로 이동하고 환율은 환율 창을
  엽니다. 목록은 스크립트의 `$stripDefs` 에서 바꿉니다.
- **관련 기사 한 줄 (2026-10-30, Perplexity·구글 금융의 시장 요약 벤치마킹)**: 지금 주목할 점에서 종목마다 맨 위 줄 아래에
  그 종목의 최근 3일 안 기사 제목을 하나 붙여 "왜 움직였나"를 같이 보여 줍니다. 이미 받는 뉴스를 쓰므로 AI 를 부르지 않습니다.
  여러 종목을 묶은 줄과 실적 일정 줄에는 붙이지 않습니다. 메일의 지금 주목할 점에도 같은 줄이 붙습니다.
- **52주 범위 안의 위치 (2026-10-30)**: 카드 차트 아래 막대의 왼쪽 끝이 52주 최저, 오른쪽 끝이 최고이고 점이 현재가입니다.
  위 눈금은 20·60·180일선(차트 선과 같은 색), 아래 점선 눈금은 분할 매수 단계 기준(52주 고점 대비 −10·−20·−30%, 종목별
  DipSteps 를 따름)입니다. 가까운 눈금은 이름을 하나로 묶습니다. 한눈 요약 표의 이평선 칸에는 같은 막대를 작게 넣었습니다.
  카드 아래 '52주 범위' 문구는 이 막대 양 끝으로 옮겼습니다.
- **수익률 비교 (2026-10-30, Koyfin 벤치마킹)**: 고른 종목을 기간 시작일 종가 0%로 맞춰 한 그래프에 겹쳐 봅니다. 기간은
  1개월·3개월·6개월·연초 대비·1년이고, 시작일 계산이 기간별 표와 같아 끝 값이 표와 같습니다. 시장 지수는 회색 점선, 종목은
  6색(보라, 주황, 청록, 노랑, 분홍, 초록. 색약 검사를 통과한 순서이고 상승 빨강·하락 파랑과 헷갈리지 않게 두 색은 뺐습니다)으로
  한 번에 6개까지입니다. 색은 고를 때 빈 자리를 받아 다른 종목을 끄고 켜도 바뀌지 않습니다. 고른 종목과 기간은 그 브라우저에
  기억합니다(`localStorage`). 마우스를 올리거나 누르면 그날 모든 선의 값이, 방향키로 날짜를 옮길 수 있습니다.
  2026-11-28 부터 종목 고르는 단추 대신 '기간 수익률 순위 막대'로 고르고, 한눈 요약 바로 아래에 둡니다(아래 기록).
- **수익률 비교 확장 (2026-10-30)**: 기간에 [2년]과 [직접]을 더했습니다. [직접]은 시작일을 골라 산 날짜부터의 수익률을 봅니다
  (받아 둔 자료 약 2년 안, 고른 날짜는 그 브라우저에 기억). 자료가 시작일보다 열흘 넘게 짧은 종목(샌디스크 등)은 이름 뒤에 *를
  붙이고 첫 자료일을 0%로 맞춥니다.
- **카드 차트 '시장과 비교' (2026-10-30)**: 국내 종목은 KOSPI, 미국 종목은 나스닥을 그 기간 첫날 종목 가격에 맞춰(같은 출발점)
  회색 점선으로 겹칩니다. 점선보다 위에 있으면 그 기간 시장보다 잘 간 것입니다. 차트 아래에 '이 기간 삼성전자 −17.4%, KOSPI −16.6%'
  처럼 두 수익률을 적고, 마우스를 올리면 그날까지의 두 수익률이 나옵니다. [시장과 비교] 버튼 하나로 모든 카드가 함께 켜지고 꺼지며
  그 브라우저에 기억합니다. 지수와 코인 카드에는 없습니다.
- **목표주가 변화 (2026-10-30, 토스증권 '한 줄 요약' 벤치마킹)**: 증권사 목표주가 평균을 날마다 `target-cache.json` 에 적고,
  전 기록보다 1% 넘게 바뀌면 그날 지금 주목할 점에 올립니다. 카드의 목표주가 옆에는 2주 안에 바뀐 날과 폭을 적습니다
  (예: `10/30 5.4% 상향`). 기록이 60일 넘게 쌓이면 '기록을 모은 N일 중 가장 높습니다'도 붙습니다. 기록은 첫 실행부터 쌓이므로
  첫날에는 비교할 값이 없습니다.
- **다가오는 일정 (120일)**: 미국 종목 실적 발표일(Nasdaq/Zacks)과 `market-calendar.json` 의 시장 일정(FOMC, 미국 CPI,
  한국은행 금통위, 미국·한국 증시 휴장일)을 날짜순 한 목록으로 보여 줍니다. **`market-calendar.json` 은 매년 초에 그해 일정을
  더해야 합니다**(2027년 한국 증시 설 연휴는 한국거래소 발표 뒤 추가).
- **카드 구역과 바로가기**: 카드를 분야별 구역으로 나누고, 위에 [한눈 요약]·[수익률 비교]·[일정]·분야별 바로가기가 따라옵니다.
- **차트 표시**: 카드 차트에 화면 기간 안의 20/60일선 교차 지점을 세로 점선(골든 빨강, 데드 파랑)으로, 알림가를 주황 가로선으로
  그립니다(마우스를 올리면 날짜와 값).
- **색**: 가격 방향은 국내 증권 앱처럼 **상승 빨강, 하락 파랑**입니다. `template.html` 맨 위 색 정의의 `--rise`/`--fall` 한곳에서
  정하므로, 미국식으로 되돌리려면 그 값을 `var(--good)`/`var(--bad)` 로 바꾸면 됩니다. 메일도 같은 색입니다.
- **글자와 문구**: 화면 글자는 12px 이상입니다. 화면·메일 문구는 사내 문서 문체(-습니다, 한 문장에 한 내용, 줄표·가운뎃점 나열
  없음)로 씁니다. 이동평균 추세 표시는 "골든크로스, 상승 전환", "정배열, 상승 추세", "단기 하락"처럼 짧게 적습니다.
- **화면 크기**: 1800px 이상에서는 페이지 최대 폭을 1,760px(2,300px 이상은 2,160px)로 넓힙니다.
- **Per card:** price and change, 1M/3M/6M/1Y chart with 20/60/180일 moving averages (기간은 30·91·182·365일 전부터, 그 기간 수익률을
  그래프 위에 적음), 52주 범위 안의 위치 막대,
  거래량 with `평균의 N배` (vs the prior 20 trading days' average, highlighted at 2× and over),
  target price, next earnings (US listings), alert-level flag, and the 최근 이슈 news list.
- **News tags:** `[호재]` / `[악재]` come from headline keywords only (not the article body).
  English headlines are machine-translated; the link always goes to the original.
- **스팸 거르기 (2026-10-29)**: 도박 광고 글은 단어(카지노, 바카라, 토토, 먹튀 등)와 출처(Calgary Roughnecks, icaremn.com 등)로
  거릅니다. 목록은 `Update-StockDashboard.ps1` 의 `$spamKeywords`, `$spamSources` 이고 정규식입니다. 걸러낸 제목은 실행 기록에
  남습니다. 처음 켠 날 이더리움 기사에서 8~16건이 걸렸습니다(모두 Calgary Roughnecks). work-dashboard 목록에서 '베팅', '배팅',
  '도박'은 뺐습니다('거세질 역외 베팅'처럼 정상 기사에 흔합니다). 다른 낱말 안에 들어가는 단어는 앞뒤 글자를 보고 맞춥니다:
  `포커(?!스)`('[마켓포커스]', '포커스온경제'), `(?<!포)토토`('포토토크'), `(?<!분)야동`('분야동향'), `머니상(?!승)`.
- **메일 용량**: 실행 기록에 `email-summary.html (44.6 KB)` 처럼 남기고, 90KB 를 넘으면 경고합니다(work-dashboard 와 같음).
- **Stale warning:** the 조회 시각 pill turns red with `N시간 전 데이터` once the data is over
  26 hours old. KST Sunday/Monday runs are skipped on purpose, so from Sunday until the Tuesday
  slots finish (14:00 KST) up to 80 hours counts as normal. Before this the pill was always green,
  so a stopped workflow looked like today's page.
- Long prices (₩1,862,000, BTC in won) drop one font size so the change pill stays on the same
  line; otherwise that card's chart sat lower than its neighbour's.
- **가시성·표현 점검 반영 (2026-10-30)**: 공개 페이지를 데스크톱·휴대폰(390px)·다크 모드로 찍어 본 점검 결과를 고쳤습니다.
  - **기사 제목 버그**: '지금 주목할 점'의 알파벳 관련 기사가 'META_TITLE_QUOTE'(언론사 페이지의 빈 틀 글자)로 나왔습니다.
    `Test-SpamHeadline` 이 대문자·숫자를 밑줄로 이은 한 단어와 빈 제목을 거르고, 페이지도 한 번 더 거릅니다(`isRealTitle`).
  - **파랑 한 가지 뜻**: 하락 파랑(#1f5fcc)과 강조색(#2a78d6)이 거의 같아 '분할 3단계' 같은 매수 단계 배지가 하락처럼 읽혔습니다.
    강조색을 청록(밝은 화면 #0f766e, 어두운 화면 #2a9d8f)으로 바꾸고 단계 배지의 ▼를 뺐습니다. 파랑은 가격이 내린 것만 뜻합니다(메일도 같음).
  - **같은 숫자 반복**: 해설이 '52주 고점보다 39.9% 낮아 분할 3단계'라고 말하면, 분할 단계 줄은 '3단계 기준(고점 대비 −30%)을 넘음'으로,
    20거래일 요약은 고점 부분을 빼고 적습니다(예전에는 한 카드에 같은 하락률이 세 번).
  - **지수 칸**: 줄마다 같은 개수가 되게 열 수를 정합니다(8개를 6+2 대신 4+4). 휴대폰은 두 칸 그대로.
  - **일정**: 2주 안 일정만 펴 두고(4건 이상) 나머지는 [이후 일정 n건 더 보기]로 접습니다.
  - **읽는 단위**: 1억 원이 넘는 원화(비트코인)는 '1억 366만 원'(지수 칸·카드 옆·52주 막대 양 끝), 차트 축은 '1.14억'.
    거래량은 '2,178만 주', 코인 거래대금은 '73.5조 원', '254억 달러'(예전 21.8M, 73.5T, 25.4B).
  - **종목 수**: 머리글을 '관심 종목 11개 · 시장 지수 3개'로 적어 브리핑의 '관심 종목 11개'(지수 제외)와 맞췄습니다.
  - **이평선 칸**: 표의 작은 막대를 키우고(112×16 → 132×22), 분할 단계 배지 아래에 '고점 대비 −39.9%'를 숫자로 적습니다.
  - **휴대폰**: 종목 카드는 시세·해설·그래프만 두고 이평선 거리, 분할 단계 근거, 과거 성적, 52주 위치, 거래량·목표주가,
    최근 이슈, 실적은 [자세히 보기]로 접습니다. 390px 폭 페이지 길이 24,215px → 14,145px.
- **증권 시황 기사 표현 반영 (2026-11-06)**: 시황 기사와 지수 발표문에서 쓰는 네 가지 표현을 넣었습니다.
  - **한 줄 결론**: 오늘의 브리핑 맨 위(메일도)에 제목 한 줄과 설명(`HEADLINE`). 지수가 급등·급락하면 그 지수('나스닥이 하루
    5.5% 급락했습니다'), 아니면 관심 종목 전체의 방향을 제목으로 쓰고, 설명 끝에 새로 매수 단계·이평선 기준에 든 종목을 붙입니다.
    결론이 코스피·나스닥을 말하므로 브리핑 '시장' 줄은 코스닥, S&P 500, 필라델피아 반도체지수, VIX 를 적습니다.
  - **크기를 말로**: 평소 하루 움직임(최근 2년 하루 수익률의 표준편차, `perf.thr.d1`)의 2.5배 이상이면서 2% 넘게 움직이면
    '급등·급락'으로 쓰고, 2배 이상이면 '평소 하루 움직임의 3.3배입니다'를 붙입니다(`Get-MoveContext`, `Test-BigMove`).
  - **언제 이후**: 하루 변화가 평소의 2배 이상이면 그만큼 컸던 가장 최근 날을 찾아 '2025년 4월 이후 가장 큰 하루 하락입니다',
    2년 기록에 없으면 '최근 2년 중'. 52주 신고가·신저가에는 1년보다 앞까지 거슬러 갈 때만 '2024년 9월 이후 가장 낮은 가격입니다'.
  - **며칠째**: 5거래일 이상 같은 방향이면 주목할 점에 '5거래일 연속 하락', 코스피·나스닥은 3거래일부터 결론에 적습니다.
  - 조사: 괄호 앞 말에 맞춥니다('엔비디아(고점 대비 −25.4%, 200일선 도달)가'). '으로/로'는 `Get-JosaRo`('20으로', '28.2로').
- **고도화 (2026-11-08)**
  - **먼저 볼 종목**: 시장 전체가 빠지면 관심 종목 대부분이 분할 매수 단계에 들어 신호만으로는 구분이 안 됩니다(11/7: 14개 중 12개).
    단계에 든 종목을 과거 성적(그 분야·단계의 1년 뒤 백분위, 35점), 단계(15점), 시장보다 더 빠진 정도(최근 1개월, 25점),
    평소보다 큰 하락(1개월 하락 ÷ 평소 1개월 움직임, 25점)으로 점수 내 1~3위를 한눈 요약 칸에 '먼저 ①②③'으로, 브리핑과 메일에
    '먼저 볼 종목' 줄로 적습니다(단계에 든 종목이 셋 이상일 때). 사라는 뜻이 아니라 살펴볼 순서입니다. 칸에 마우스를 올리면 이유가 보입니다.
  - **신호 실전 기록부** (`signal-log.json`, 페이지 '신호 기록' 구역): 분할 단계는 더 높은 단계에 처음 든 날, 이평선 매수 기준은 켜진 날의
    날짜·종가·시장 지수 값을 남기고, 페이지가 그 뒤 수익률·시장 대비·지난 날을 보여 줍니다. 기록을 처음 시작한 날 이미 단계 안에
    있던 종목은 '시작일'로 따로 셉니다. 워크플로가 다른 캐시와 함께 커밋합니다. 과거 10년 검증이 지금 시장에서도 맞는지 보는 용도입니다.
  - **원화 기준**: 한눈 요약의 [원화 기준]을 켜면 미국 종목·미국 지수·달러 코인의 등락(오늘·1주·1개월·연초·1년)과 수익률 비교 그래프를
    그날 원/달러 환율로 바꾼 값으로 다시 잽니다. 그 브라우저에 기억합니다. 이를 위해 환율 일봉을 1년에서 2년으로 늘렸습니다.
  - **시장 띠에 미국 10년물 금리·달러인덱스**: `^TNX`(변화는 bp), `DX-Y.NYB`. 하루에 10bp 넘게 움직이거나 달러인덱스가 0.7% 넘게
    움직이면 브리핑 '시장' 줄에도 적습니다. 띠가 10칸이 되어 5칸씩 두 줄로 놓입니다.
  - **내 보유와 분할 매수 계획** (접힌 구역): 종목별 수량·평단·예산을 넣으면 평가손익, 비중, 지금 단계까지 계획한 금액 중 더 살 금액
    (예산 × 단계별 비율 합 − 이미 산 금액), 다음 단계 가격과 남은 %를 보여 줍니다. 단계별 비율 기본값은 30·30·40%.
    **이 저장소와 페이지는 공개라 보유 정보는 그 브라우저(localStorage)에만 저장합니다.** 다른 기기로는 [내보내기]·[가져오기]로 옮깁니다.
  - **뉴스 거르기 공통 파일**: `Test-SpamHeadline`을 work-dashboard 와 똑같은 `news-filter.ps1`로 옮겼습니다. 워크플로가 실행 때마다
    work-dashboard 의 같은 파일과 비교해 다르면 경고를 남깁니다.

- **그래프 강화 (2026-11-10)**: 분할 매수 판단을 그림으로 보게 했습니다.
  - **그림으로 보기**(한눈 요약 아래, `#visual`): ① 매수 단계 지도(종목별 52주 고점 대비 하락률 막대, 배경은 그 종목의 1·2·3단계 구간,
    다음 단계까지 남은 %), ② 하락폭과 최근 흐름(가로 고점 대비 하락률, 세로 최근 1개월 수익률, 점 크기는 내 보유 금액, 고점 대비 20% 넘게
    빠졌고 최근 오른 칸을 색칠), ③ 시장 심리(공포·탐욕지수 반원 게이지와 최근 1년 추이, 0~24·25~44 구간 색칠). 1년 추이는 CNN 응답의
    `fear_and_greed_historical`(252일)을 `fearGreed.trend` 로 담습니다.
  - **카드 차트**: 기본 기간 3개월, 분할 단계 가격(52주 고점 × (1 − 단계%)) 청록 점선과 이름(바로 아래 단계가 12% 안이면 축을 넓혀 보임),
    과거에 단계에 들어간 날 ▲(그날까지 1년 최고 종가 대비 하락률로 다시 매김, 같은 단계는 20거래일에 한 번), 거래량 막대(`volumes`, 최근 260거래일).
  - **신호 실전 기록**: 신호 뒤 거래일별 수익률 선(종목별 가는 선, 평균 굵은 선, 시장 점선). 평균은 그날까지 온 신호가 충분할 때만 잇습니다.
  - **내 보유**: 분야별 비중 도넛, 종목별 평가손익 막대, 분할 매수 진행(예산 중 산 금액, 지금 단계까지 계획 표시).
  - **한눈 요약**: [보유 금액 크기]를 켜면 칸 넓이가 내 보유 금액인 지도(squarified treemap). 지도 칸의 '분할 n단계'는 흰 바탕 배지로.
  - **원화 기준**을 켜면 미국 종목 카드에 '원화로 본 수익 = 주가 + 환율'(1개월, 연초 대비, 1년).
  - 문구: 과거 성적은 '아무 날이나 샀을 때(71%)보다 높았습니다'처럼 해석까지, 목표주가는 '(지금보다 140% 위)', '11/5에 1.1% 낮아짐',
    다음 실적은 '2026년 3분기', 추세는 '하락 추세(역배열)'처럼 쉬운 말 먼저. 영문 기사는 호재·악재를 표시하지 않고 낚시성 제목
    (Prediction:, Should you buy, Jim Cramer, Motley Fool 등, `Test-ClickbaitTitle`)은 뺍니다.
  - 페이지 자료를 한 줄 JSON(`-Compress`)으로 넣어 페이지가 1.1MB(들여 쓴 모양)에서 0.5MB 로 줄었습니다.

- **메일 그림 (2026-11-12)**: 메일 프로그램은 화면의 그래프를 보여 주지 않아, 메일을 보내는 실행에서 `mail_charts.py stock` 이
  '매수 단계 지도'와 '공포·탐욕지수 1년' 그림(PNG, `mail-charts/`)을 만들어 브리핑 바로 아래 `<!--MAIL_CHARTS-->` 자리에 끼웁니다.
  워크플로 'Draw mail charts' 단계가 나눔고딕을 설치하고 실행하며, 첨부 그림은 파일 이름이 cid 가 되어 본문에 보입니다.
  그림을 못 만들면 메일은 글로만 나갑니다. work-dashboard 와 같은 파일이니 고칠 때 두 저장소를 같게 맞춥니다.
  같은 날 과거 성적 문장의 '…보다 비슷했습니다'를 '…와 비슷했습니다'로 고쳤습니다.

- **메일 자체 평가 감점 보완 (2026-11-12)**: 시세가 빠진 날(Yahoo 가 종가를 비워 보낸 날)이 끼면 '이틀 동안'으로 적고(d1Gap, 시장 띠 gap),
  국내 장중(09:00~15:30)에 실행되면 메일 머리와 결론에 '국내 종목은 HH:MM 장중 가격'을 적는다. 주목할 점의 관련 기사는 종목 이름·티커가 든
  국내 기사만, 종목별 상세는 이름이 든 기사 한 건(국내 먼저). 시세 안내 페이지(Stock Price, News, Quote)는 거른다. 결론의 지수 문장은 한 문장으로
  ('코스피는 0.9% 올라 3거래일 연속 상승했습니다'), 먼저 볼 종목은 이름과 순서 기준만, 이평선 참고는 '매수 기준에는 들지 않습니다'.
  그림이 들어가면 '오늘의 매수 단계'·공포탐욕 상자는 메일에서 뺀다(<!--FALLBACK_START--> 블록). 종목별 상세에서 한 줄 해설과 과거 성적 문장(종목마다 같은 문장)은 뺐다. 메일 글씨 12px.
- **시각화 보완 (2026-11-14)**: 화면을 PC(1280px)와 휴대폰(390px) 폭으로 찍어 점검한 뒤 고친 것입니다.
  - 공포·탐욕 게이지의 숫자가 바늘에 가려지던 것을 게이지 아래로 내렸습니다.
  - "하락폭과 최근 흐름" 그림: 구석 설명 글자가 점을 덮으면 0% 선 옆으로 옮기고, 종목 이름은 다른 종목의 점도 피해 놓습니다.
    휴대폰에서 아래 축 제목 두 개가 겹치던 것은 짧은 제목으로 바꿨습니다.
  - 종목 카드: 그래프를 글보다 먼저 두고 키웠습니다(82px → 116px, 휴대폰 94px). 이평선 거리·분할 단계 근거·과거 성적은
    그래프 아래 "판단 근거" 접는 칸으로 모았습니다. 단계 이름표는 가격선과 덜 겹치는 쪽(왼쪽 또는 오른쪽)에 둡니다.
    52주 위치 막대의 이름표는 가까우면 하나로 묶는 간격을 글자 폭에 맞췄습니다(9% → 이평선 17%, 단계 12%).
    목표주가 줄이 카드 밖으로 잘리던 것은 줄바꿈을 허용했습니다.
  - 신호 실전 기록: 기록이 20거래일 쌓이기 전에는 선이 뭉쳐 읽기 어려워, 신호별 수익률 막대(세로 눈금은 같은 기간 시장)로 보입니다.
    20거래일부터는 예전의 날짜별 선 그래프로 바뀝니다. 표는 5줄만 먼저 보이고 나머지는 접습니다.
  - 표 읽는 법에 최근 6개월 그래프의 색 기준(6개월 전보다 올랐으면 빨강, 내렸으면 파랑)을 적었습니다.
  - 2차 보완(2026-11-15, 휴대폰·다크 모드·상세 창 점검):
    - 종목 카드의 단계 이름표를 그림 오른쪽 바깥 여백으로 옮겼습니다(그림 안에서는 가격선과 겹쳤음). 붙는 이름표는 위아래로 벌립니다.
    - "하락폭과 최근 흐름"은 휴대폰 폭에서 구석 설명을 빼고(위 설명 글에 같은 내용) 높이를 키웠습니다. 이름이 들어갈 빈 자리가 없으면
      그림 밖으로 나가지 않는 자리라도 고릅니다.
    - 실적 창: 분기 매출·영업이익 막대(예상치는 옅게)를 표 위에 넣었습니다.
    - 목표주가 창: 최고·최저 목표가가 있는 종목은 "최저–평균–최고 목표가와 현재가" 막대를, 수급 동향 표에는 칸마다 0을 가운데 둔
      막대(순매수 빨강, 순매도 파랑)를 넣었습니다.
  - 그대로 둔 것: 한눈 요약 타일 묶음의 빈 자리. 두 줄로 나누면 타일이 좁아져 종목 이름이 잘려서 두었습니다.
- **문장·구성 정리 (2026-11-17, Fable 점검 반영)**: 11/14·15 시각화 보완이 다루지 않은 문장과 구성 쪽입니다.
  - 결론·브리핑·주목할 점이 같은 말을 되풀이하지 않습니다. 오른 수·내린 수는 브리핑 '관심 종목'에만, 오늘 새로 든 매수 신호는 결론에만
    ('오늘 새로 매수 기준에 든 종목은 알파벳(분할 3단계)…'), 브리핑 '매수 신호'는 단계별 개수와 며칠째 이평선에 닿아 있는 종목만 적습니다.
    이평선 도달은 오늘 처음 닿은 것(firstTouch)만 '새로'에 넣습니다.
  - 결론 제목: 4개 오르고 7개 내린 날에 '비슷합니다'가 나갔습니다. 차이가 1개 이하일 때만 '비슷'이고, 더 벌어지면 '관심 종목 11개 중 7개가 내렸습니다'.
  - 카드 위 해설은 카드의 다른 곳에 없는 말만 합니다(다음 매수 기준선, 고점 근처에서 닿아 참고로만 본다는 말). 추세는 그래프 위 추세 줄이,
    단계는 시세 옆 표시가 말합니다. '아래에 남은 매수 기준선은 없습니다'는 뺐습니다. 20거래일 요약에서 '오른 날·내린 날' 개수를 뺐습니다.
  - 과거 성적: 같은 분야 같은 신호는 카드마다 같은 긴 문장이라 '개별 종목 31번 중 1년 뒤 오른 비율 87% (평소 71%)'로 줄이고 긴 설명은 마우스를 올리면.
  - 카드 세부(판단 근거, 52주 위치, 20거래일 요약, 최근 이슈, 실적)는 넓은 화면에서도 접습니다(페이지 12,000px → 9,000px 안팎). 거래량·목표주가 줄은 그대로.
    52주 막대의 읽는 법 글은 제목에 마우스를 올리면 보입니다. 카드 그래프 비율을 칸에 맞춰 끝점 원이 세로로 늘어나지 않게 했습니다.
  - 카드 '최근 이슈'와 주목할 점·메일의 관련 기사는 같은 이름 목록(Get-NewsTerms: 화면 이름, 티커, 검색어의 영문 이름, 지수 별칭)이 제목(번역 전
    원문 포함)에 있는 기사만 씁니다. 지수 카드에 'IJH 보유자는…', '민주당 스윕…' 같은 번역 기사가 붙었습니다.
  - 지수 띠: 소수 첫째 자리로 0.0%가 되는 변화는 '보합'(달러인덱스 0.0% 옆에 빨간 ▲가 붙었음). 신호 기록 표의 겹친 괄호
    ('이더리움(이평선 매수 기준(180일선))')는 신호를 이름 아래 작은 글씨로.
  - 국내 장중 실행이면 국내 종목 거래량 배수를 빼고 '11:15 장중'으로 적습니다(그날 일부만 쌓인 거래량을 평균과 견주면 작게 나옴). 거래량 급증 알림도 함께 빠집니다.
  - 메일: 이름을 화면 제목·보내는 사람과 같은 'JH 투자 DASHBOARD'로(제목, 머리). 모양을 업무 메일과 같게: 구역 제목은 상자 밖 작은 회색 글씨,
    상자는 흰 바탕, 오늘 방향·매수 구간·공포탐욕 구간은 상자 왼쪽 띠 색으로만.
- **관련 지표 (2026-11-23)**: 사용자 요청("D램 가격, 낸드 가격 등 내 주식과 연관된 지표, 인증키 없이 바로 넣을 수 있는 것만").
  다른 시황 사이트의 '시장 온도계'를 참고했고, 그 사이트와 같은 원본에서 받아 숫자가 같은 것을 확인했습니다. '그림으로 보기' 아래 구역입니다.
  - 메모리 가격: DRAMeXchange 첫 화면 표의 DDR5·DDR4 16Gb 칩 현물가(평일), DDR5 RDIMM 32GB 서버 모듈과 NAND 512Gb TLC 웨이퍼(주 1회).
    값은 그날 평균, 변화는 표에 적힌 직전 조사 대비 %. 과거 시세는 회원 전용이라 `indicator-cache.json` 에 조사일별로 쌓고(봇이 커밋),
    값이 두 번 모이면 그래프가 나옵니다. 공개 페이지라 품목은 넷으로 줄이고 출처와 원본 링크를 둡니다.
  - 국내 증시 자금: 금융투자협회 FreeSIS(빚투 = 신용융자 잔고, 투자자예탁금, 위탁매매 미수금, 장내파생상품 거래예수금). 3년치를 실행마다 받습니다. 발표가 이틀쯤 늦습니다.
  - 외국인 매매: 네이버 증권 투자자별 매매(관심 종목 중 국내 개별 종목, 60거래일). 금액은 수량 × 그날 종가로 어림합니다. 국내 장중 실행이면 오늘 줄은 뺍니다.
  - 시장 심리: VIX 3년(맨 위 띠와 같은 값, 점선 20·30), 코인 공포·탐욕지수(Alternative.me) 3년.
  - 카드마다 기간 단추(1개월·3개월·1년·3년, 자료가 짧으면 줄어듦)와 마우스를 올리면 그날 값. 큰 값·변화·기준일 글은 스크립트가 만들어 화면과 메일이 같이 씁니다.
  - 지금 주목할 점: 칩 현물가 하루 3%·모듈과 웨이퍼 한 주 5% 이상 변화, 외국인 5거래일 이상 연속 순매수·순매도, 빚투·예탁금의 최근 3년 최고·최저.
    우선순위는 종목 신호보다 낮아(66~82) 종목 신호가 많은 날에는 8개 안에 들지 않습니다.
  - 메일: '기간별 등락' 다음에 '관련 지표' 표(값, 변화, 기준일). 받지 못한 자료는 화면과 메일에 적고, 메모리 가격은 지난 기록을 보여 줍니다.
  - 그대로 둔 것: 한국은행 D램·플래시메모리 수출물가(무료 인증키 필요), 반도체 수출액(공공데이터포털 키 필요), DRAM 고정거래가격(첫 화면 표에 숫자 없음), HBM 가격(공개 시세 없음).
  - 같은 날 시각 보완(사용자 "오류랑 개선 모두 다 적용"). 배포 페이지를 1440·1024·390px 로 찍어 검토한 12건:
    - 3년 보기에서 왼쪽 끝 눈금(첫 해 2024)이 잘려 빠지던 것을 끝에 붙여 표시. VIX 점선 끝에 20·30 숫자(그 옆 보통 눈금은 뺌).
    - 조사·발표일이 8일 넘게 지난 값은 화면 '(14일 전)'(주황), 메일 날짜 칸 '11/9(월), 14일 전'(서버 모듈이 11/9 조사에서 멈춰 있었음).
    - 선 색: 보고 있는 기간의 처음보다 올랐으면 빨강, 내렸으면 파랑(한눈 요약 6개월 그래프와 같은 규칙). 코인 공포·탐욕은 구간 색이 있어 검정.
    - 기간 중 최고·최저 점과 이름표('최고 38.63조(6/24)', 해가 다르면 '24년 12/12'). 빈 자리를 찾고 바탕색 테두리. 휴대폰은 날짜를 빼고, 선을 덮는 자리뿐이면 점만.
    - 기록 전 메모리 카드는 빈 그림 칸 없이 낮게. 기간 단추는 묶음마다 하나(12벌 → 4벌, 같은 날짜 자료를 같은 기간으로).
    - 휴대폰: 그래프 112px, 묶음 설명은 [설명 보기]로 접음. 이 구역 3,753px → 2,999px.
    - 외국인 카드: '최근 5거래일 합계'를 큰 숫자 아래로, 막대의 마지막 5일에 옅은 바탕, 맨 끝 날짜 눈금, 제목을 누르면 그 종목 카드로 이동.
    - 나란히 놓인 외국인 매매·시장 심리 카드의 높이를 맞추고, 늘어난 높이만큼 그래프를 키움(최대 90px). 코인 공포·탐욕의 구간 이름에 CNN 게이지와 같은 구간 색.
- **시각화 개편 (2026-11-24)**: 사용자 요청("live3x.com 같은 사이트를 참고해 시각화와 대시보드 구성 개선, work·stock 모두").
  live3x 화면을 찍어 비교한 뒤, 그 사이트의 특징 가운데 이 페이지에 맞는 것을 옮겼습니다. 업무 대시보드와 같은 날 같은 원칙으로 고쳤습니다.
  - 맨 위 시장 칸: 오른쪽 작은 선 대신 칸 오른쪽 아래를 채우는 옅은 면 그래프(최근 1개월, 오르면 빨강·내리면 파랑, 위에서 아래로 옅어짐).
    값 글자를 15px → 17px 로 키우고, 그래프 위에 오는 글자에는 바탕색 그림자를 둘러 선과 겹쳐도 읽히게 했습니다.
  - 관련 지표 그래프: 오른쪽 축에 지금 값 이름표(선 색 바탕, 밝은 화면은 흰 글자, 어두운 화면은 거의 검은 글자). 이름표와 같은 높이의 눈금 숫자는 뺍니다.
    축 폭은 눈금 숫자와 이름표 글자 폭 가운데 넓은 쪽에 맞춥니다. 방향이 없는 코인 공포·탐욕은 회색 바탕.
  - 종목 분야 머리줄: '국내 반도체 종목 2개, 오늘 하락 2개'처럼 종목 수와 오늘 오른·내린 종목 수(±0.05% 안은 보합).
  - 그대로 둔 것: 종목 카드 그래프에는 이름표를 넣지 않았습니다. 오른쪽에 분할 매수 단계 이름표(2단계 −20% 등)가 있어 겹치기 쉽고, 단계 이름표가 더 중요합니다.
    live3x 의 카드마다 붙은 기간 단추는 옮기지 않았습니다(묶음마다 하나인 지금 방식을 유지).
  - 점검: 1440·390px, 밝은·어두운 화면에서 JS 오류, 12px 미만 글자, 겹친 글, 카드 밖 글, 가로 넘침 모두 0건.
- **시각화 점검 (2026-11-27)**: 사용자 요청("대시보드 3개 모두 시각화 부분에서 개선할만한게 있는지 점검하고 적용"). 넓은 화면과 휴대폰, 밝은·어두운 화면을 찍어 보고 네 가지를 고쳤습니다.
  - 종목 카드 그래프의 끝점: 그림이 칸에 맞춰 가로로 늘어나서(SVG preserveAspectRatio none) 넓은 카드(QLD 등)에서 끝점 원이 옆으로 퍼진
    타원이 됐습니다. 끝점과 마우스 점을 ▲ 표시처럼 그림 위 HTML 점으로 바꿔 어느 폭에서나 동그랗게 그립니다. 시장 칸 그래프도 같습니다.
  - 하락폭과 최근 흐름: 점이 몰린 곳에서 이름표가 남의 점 옆에 붙어 어느 점인지 헷갈렸습니다(알파벳 점 옆의 '비트코인' 등).
    빈 자리를 위아래·옆으로 더 넓게 찾고, 점에서 떨어진 이름표는 가는 선으로 잇고, 이름표에 바탕색 테두리를 둘렀습니다.
    휴대폰에서 서로 겹치던 이름표가 모두 떨어졌습니다.
  - 눈금 숫자: 하락폭과 최근 흐름은 10% 칸이 40px 보다 좁으면 20% 간격으로 적고, 매수 단계 지도는 휴대폰에서 처음·가운데·끝만 둡니다
    (휴대폰에서 '−10%−20%−30%'처럼 붙었음). 매수 단계 지도의 마지막 숫자는 막대 끝 안쪽에 붙였습니다.
  - 신호 실전 기록 표: 휴대폰에서 오른쪽 열이 잘려 보였습니다. 휴대폰에서는 그날 값·지금·지난 날 열을 빼고 종목 칸만 줄을 바꿉니다.
  - 점검: 1440·390px, 밝은·어두운 화면에서 JS 오류 0건, 가로 넘침 없음.
- **한글 표현 점검 (2026-11-27)**: 사용자 요청("3개 다 대시보드 한글 표현이 어느정도 수준인지 점검하고 부족한 부분은 채워줘"). 화면 글을 모두 뽑아 공통 규칙 3·4로 점검했습니다.
  - 만든 말: '아무 날이나 샀을 때'(카드의 과거 성적, 표시 읽는 법)를 '날마다 샀을 때'로, '반등을 살펴볼 자리입니다'를 '…종목이 놓입니다'로 바꿨습니다.
  - 문체: '바로 비교하지 마세요'를 '바로 견줄 수 없습니다'로, 신호 실전 기록 요약 줄('9건, 평균 −2.8%, 오른 비율 44% / …')을 문장으로 바꿨습니다.
    '세로 눈금은 같은 기간의 시장'은 막대 위 짧은 세로선이 무엇인지 알 수 있게 고쳤습니다. 브리핑 '먼저 볼 종목'의 괄호 속 기준 나열은 뒤 문장으로 뺐습니다.
  - 숫자: 카드 머리 증감 '▼ -20.78 (-22.02%)'를 '▼ −20.78 (−22%)'처럼 빼기 기호와 공통 규칙 4의 자릿수로 맞추고, 변화율은 표의 '오늘' 칸과 같은 값을 씁니다
    (따로 계산해 +4.6%와 +4.5%가 함께 보였음). 그래프 눈금은 쉼표를 두고(27600 → 27,600), 한 그림 안에서 같은 단위와 자릿수로 씁니다
    (1.16억 / 9,767.2만 → 1.16억 / 0.98억 / 0.79억).
  - 앞뒤가 맞지 않는 숫자: 목표주가 평균이 지금 값의 4배를 넘거나 5분의 1에 못 미치면(샌디스크 '지금보다 2641% 위') '자료 확인 필요'로 적습니다.
  - 그대로 둔 것: 맨 위 칸과 표의 'KOSPI' 같은 영문 지수 이름(칸 이름표로 쓰고 문장에서는 코스피), '1,742억원'처럼 숫자에 붙여 쓴 단위(맞춤법이 허용),
    출처와 날짜를 잇는 짧은 가운뎃점, 표의 소수 첫째 자리(여러 값을 나란히 놓는 목록이라 자릿수를 맞춤).
  - 점검: 1440·390px JS 오류 0건, 가로 넘침 없음. 수집 스크립트는 구문 검사와 메일 없는 시험 실행으로 확인했습니다.
- **내 계좌 한 줄 (2026-11-28)**: 사용자 요청("내 투자상황이나 부산 아파트를 매수한 상황에서 추천할만한 지표나 대시보드 가시성 개선할만한 부분")으로
  점검해 보니, 화면이 관심 종목과 시장 이야기만 하고 '내 계좌가 어떤가'는 중간의 접힌 칸을 열어야 보였습니다.
  - 맨 위 바로가기 아래, 시장 띠 위에 '내 계좌' 한 줄을 둡니다. 평가액, 직전 거래일 대비(원·%), 누적 손익(원·%), 그중 환율 몫,
    지금 단계까지 더 살 금액과 투자 가능 현금의 비교입니다. 보유를 넣은 브라우저에서만 보이고 공개 화면에서는 숨습니다. [내 보유 열기]로 내려갑니다.
  - 내 보유 칸에 '투자 가능 현금(원)'과 '달러 자산 평균 매수 환율(원)'을 더했습니다. 둘 다 넣지 않아도 되고, 같은 `stock-holdings-v1` 에
    그 브라우저에만 저장합니다. 매수 환율을 넣으면 원화 누적 손익에 환율이 들어가고 환율 몫을 따로 적습니다. 넣지 않으면 달러 종목은
    환율 효과를 뺀 값이라고 적습니다(원/달러가 1년 −9.4%라 달러 자산은 환율만으로 깎인 몫이 큼).
  - 분할 3단계가 7종목에 켜진 지금은 '얼마를 살 수 있나'가 먼저라, 더 살 금액이 투자 가능 현금보다 많으면 그 차이를 적습니다("…보다 2,200만 원 많음")
    (분양권 잔금처럼 쓸 곳이 정해진 돈은 빼고 넣는 칸).
  - 점검: 가상 보유(삼성전자·엔비디아·QLD)로 평가액, 직전 거래일 대비, 누적 손익, 환율 몫, 더 살 금액을 손으로 검산했습니다.
    1440·390px, 밝은·어두운 화면 JS 오류 0건, 가로 넘침 없음.
- **스페이스X 추가 (2026-11-28)**: 사용자 요청("주식대시보드에 스페이스엑스 종목 추가해줘"). SpaceX 는 2026-02 에 xAI 를 합병했고
  2026-06-12 나스닥에 상장했습니다(종목 코드 SPCX). 그록과 X 까지 한 회사라 빅테크·AI 묶음에 넣었습니다.
  - 시세(야후), 분기 실적과 목표주가(네이버 SPCX.O), 다음 실적 발표일(Nasdaq, 2027-01-19 추정)이 모두 받아집니다.
  - 상장 117거래일이라 20·60일선만 있고 120·180·200일선은 자료가 쌓이면 저절로 나옵니다. 연초 대비·1년 등락은 '–'입니다.
  - 분할 단계는 다른 개별 종목과 같은 기준(고점 대비 10·20·30%)입니다. 52주 고점 225.64달러가 상장 첫 주 고점이라,
    넣은 날(11/27 종가 133.59달러, 고점 대비 −40.8%)부터 3단계입니다.
  - 상장한 지 1년이 안 된 종목은 종목 코드 줄에 'SPCX · NASDAQ · 2026년 6월 상장'처럼 상장 달을 적습니다(이런 종목의 52주 고점은 곧 상장 뒤 고점).
  - 자료가 상장 첫날부터인 종목(스페이스X, 샌디스크)은 '최근 2년 중 가장 큰 하루 하락' 대신 '상장 뒤 가장 큰 하루 하락'이라고 씁니다.
    5개월 된 종목에 '최근 1년 중'은 틀린 말이었습니다. 상장일은 야후 `firstTradeDate` 입니다.
  - 신호 실전 기록부: 새로 넣은 날 이미 단계 안이던 종목은 기록 첫날처럼 '시작일' 신호로 적습니다. 그날 종가는 신호가 처음 켜진 날의 가격이 아니라
    '새로 켜진 신호' 성적에 섞으면 안 됩니다. 기록부 설명도 '기록을 시작한 날이나 종목을 새로 넣은 날'로 고쳤습니다.
  - 뉴스 번역: 'a SpaceX Share'를 'SpaceX 공유'로, 'Palantir shares technical analysis'를 '…를 공유합니다'로 옮긴 것처럼, 번역기가
    주식(shares)을 동사로 읽은 제목이 캐시 3,071건 중 5건 있었습니다. 번역에 '공유'가 있고 'shares'가 그 종목 이름이나 종목 코드 바로 뒤에 붙은
    제목만 'stock'으로 바꿔 한 번 더 번역합니다. 'Jensen Huang shares vision'(사람 뒤), 'to share data', 'Nvidia shares its plan'(뒤에 목적어)은 그대로 둡니다.
  - 같은 기사 두 줄: 반영 뒤 스페이스X 카드에 TradingView 와 Benzinga 가 함께 실은 같은 제목이 두 줄 나왔습니다. 카드 뉴스를 최신순으로 세운 뒤
    제목이 같으면 가장 최근 것 하나만 둡니다(자르기 전에 거르므로 기사 수는 그대로 4건). work-dashboard 는 이미 거르고 있었습니다.
  - 점검: 메일 없는 시험 실행 두 번(가지)과 반영 뒤 두 번, 1440·390px, 밝은·어두운 화면 JS 오류 0건, 가로 넘침 없음. 카드를 펼친 글까지 읽었습니다.
- **수익률과 그래프를 한눈에 (2026-11-28)**: 사용자 요청("주식 수익률이나 그래프 등 더 가시성을 좋게 만들수 있게 개선해줘 한눈에 딱 들어오게").
  점검해 보니 수익률 비교 그래프가 관련 지표와 내 보유 아래에 있었고, 그래프보다 종목 고르는 단추 15개가 먼저 보였습니다. 휴대폰에서는 선 끝에
  이름이 없어 어느 선이 어느 종목인지 알기 어려웠습니다. 카드 그래프는 높이가 116px(휴대폰 94px)로 작았고, 기간 단추를 바꿔도 그 기간 수익률이 나오지 않았습니다.
  - 수익률 비교를 한눈 요약 바로 아래로 올렸습니다(바로가기 순서도 같음).
  - 종목 고르는 단추를 '기간 수익률 순위 막대'로 바꿨습니다. 관심 종목과 시장 지수를 그 기간 수익률 순으로 세우고, 오르면 빨강, 내리면 파랑,
    시장 지수는 회색 막대입니다. 막대를 누르면 그래프에 그 종목 선을 켜고 끄고, 켠 종목 앞에는 그래프 선 색이 붙습니다. 넓은 화면에서는 막대와 그래프를 나란히 둡니다.
  - 맨 위 결론 한 줄: "3개월 동안 관심 종목이 모두 내렸습니다. 가장 적게 내린 종목은 마이크로소프트(−4.0%), 가장 많이 내린 종목은 샌디스크(−54%)입니다.
    같은 기간 시장 지수는 나스닥 −8.6%, S&P 500 −5.4%, KOSPI −28%입니다." 모두 내림, 모두 오름, 섞임에 따라 문장을 나누고, 자료가 기간보다 짧은 종목(*)은 뺍니다.
  - 그래프 세로 범위를 실제 값에 맞췄습니다. 전에는 눈금까지 범위를 넓혀 1년 그래프 아래에 값이 없는 −200% 칸이 생겼습니다.
  - 카드: 그래프를 150px(휴대폰 128px)로 키우고, 그래프 위에 그 기간 수익률('3개월 −54%')을 적습니다. [시장과 비교]를 켜면 같은 기간
    시장 수익률도 적고, 그래프 아래 설명에서는 같은 숫자를 빼고 점선이 무엇인지만 말합니다. 상장이 늦어 자료가 짧으면 '6/12부터 −17%'처럼 적습니다.
  - 카드 기간을 달력 기준으로 맞췄습니다. 전에는 1개월이 22거래일이라 표의 1개월(30일 전 종가 기준)과 값이 달랐습니다. 이제 30·91·182·365일 전
    그날 또는 그 전 마지막 거래일부터라 표, 수익률 비교, 카드가 같은 값을 냅니다(삼성전자 1개월 표 −26.0%, 카드 −26%).
  - 숫자 표기: 순위 막대는 표처럼 소수 첫째 자리, 결론 문장과 카드 기간 수익률은 공통 규칙 4(10% 이상 정수, 0.0%는 보합)입니다.
  - 그대로 둔 것: 한눈 요약 타일과 표(타일 색은 그 종목의 평소 등락 폭 대비 크기라 순위 막대와 하는 일이 다름), 메일(공통 파일인 mail_charts.py 를 두 저장소에서 함께 고쳐야 해서 이번에는 화면만).
  - 점검: 기간 7개와 원화 기준에서 결론 문장, 순위, 카드 기간 수익률을 단추를 눌러 뽑아 표 값과 맞춰 봤습니다. 1440·390px, 밝은·어두운 화면 JS 오류 0건, 가로 넘침 없음.
- **메일 08:00 도착 (2026-11-28)**: 사용자 요청("3개 대시보드는 매일 내가 설정한 이메일로 08시에 도착하게, 시간이 안맞는 것도 개선방안 검토").
  11/17~28 실제 발송은 11~14시, 이틀은 자정이었습니다. 예약 실행이 4~10시간 늦게 시작하고 '그날 첫 실행이 보낸다'였기 때문입니다.
  전날 저녁·밤 예약을 더하고, 03:00~07:30 에 시작한 실행은 07:30 까지 기다려 자료를 받은 뒤 08:00:00 에 보냅니다. 07:30 전 실행은 보내지 않습니다.
  주식 메일은 사용자 결정대로 화~토만 보냅니다(월·일 아침은 금요일 종가 반복). 바깥 예약 서비스(cron-job.org)는 가입과 토큰이 필요해 쓰지 않았습니다.
- **메일에도 수익률 순위 (2026-11-28)**: 사용자 요청("이어서 해줘", 위 기록에서 메일은 그대로 둔 것을 이어서).
  - 메일 '기간별 등락' 상자 맨 위에 화면 수익률 비교의 기본 화면(3개월)과 같은 결론 줄과 '3개월 수익률 순위' 그림을 넣었습니다.
    결론 줄은 수집 스크립트가 글로 만들어 그림을 못 만든 날에도 나갑니다. 그림은 `mail_charts.py` 가 `<!--MAIL_CHART_RETURNS-->` 자리에 끼웁니다.
  - 3개월 수익률은 생성 스크립트가 `perf.m3`(91일 전 그날 또는 그 전 마지막 종가 기준)으로 계산합니다. 화면의 순위 막대와 같은 계산입니다.
  - 반올림 한 번: 기간 수익률(perf)을 소수 둘째 자리로 먼저 줄여 저장해, 화면·메일이 첫째 자리로 다시 줄일 때 원래 값에서 바로 줄이는
    수익률 비교와 0.1씩 어긋났습니다(SK하이닉스 −32.8473% → 저장 −32.85 → 메일 −32.9%, 화면 −32.8%). 넷째 자리까지 저장합니다.
  - 메일 종목별 상세의 등락률: 따로 계산해 소수 둘째 자리로 적어 같은 메일에 기간별 등락 '+4.6%'와 '▲ 4.55%'가 함께 나왔습니다.
    표의 '오늘'과 같은 값을 공통 규칙 4로 적습니다('▲ 4.6%', 0.0%는 보합).
  - 순위 그림은 상자 폭(536px)으로 그립니다. 600px 로 그리면 상자 안에서 줄어 12px 글자가 11px 아래로 작아졌습니다(공통 규칙 6).
  - `mail_charts.py` 는 work-dashboard 와 같은 파일이라 두 저장소를 함께 고쳤습니다. 그림에 `marker` 를 적으면 공통 자리 대신 그 자리에 따로 들어가고,
    자리를 못 찾으면 첨부에서도 뺍니다. 업무 메일 그림 두 장은 전과 같게 들어가는 것을 확인했습니다.
  - 점검: 이 PC에서 수집 스크립트를 세 번 돌려 메일 본문을 만들고(44KB, 12px 미만 글자 없음) 그림을 끼워 찍어 봤습니다. 결론 줄은 화면과 글자까지 같습니다.
- **매수 단계 표현을 매매 용어로 (2026-11-28)**: 사용자 요청("가장 깊은 단계 << 이런 AI 스러운 표현들은 문맥에 맞춰 개선해줘 적극 매수 추천 이런 느낌으로").
  화면과 메일 글을 모두 뽑아 읽고, 단계마다 행동 이름을 붙였습니다: 1단계 1차 매수, 2단계 추가 매수, 3단계 적극 매수 구간, 단계 전 관망.
  - 매수 단계 지도(화면, 메일 그림): '가장 깊은 단계' → '적극 매수 구간', '단계 전' → '관망', '3단계까지 7.8%' → '3단계까지 −7.8%'(더 내려야 하는 폭),
    '깊이 내려온 순서' → '하락률이 큰 순서'. 메일 그림 아래에 단계별 행동 이름 줄을 더했습니다.
  - 카드 해설: '다음 매수 기준선은 현재가보다 8.1% 아래인 분할 매수 2단계 기준(고점 대비 −20%, 22,178.20)입니다' →
    '현재가보다 8.1% 아래인 22,178.20부터 추가 매수 구간(분할 2단계)입니다'. 이평선이면 '…120일선(가격)에 닿으면 1차 매수 구간(분할 1단계)입니다'.
  - 지금 주목할 점: '…로 분할 3단계 구간입니다' → '…로 적극 매수 구간입니다'(앞 표시가 분할 3단계), 새로 든 날은 '오늘 … 추가 매수 구간에 들어왔습니다'.
  - 브리핑: '분할 매수 단계에 든 종목은 3단계 8개, …' → '분할 매수 구간에 든 종목은 적극 매수(3단계) 8개, 추가 매수(2단계) 3개, 1차 매수(1단계) 3개입니다'.
    '먼저 볼 종목 … 점수로 정했습니다' → '우선 매수 후보 … 순입니다. 낙폭과 시장 대비 약세가 크고 같은 신호의 과거 성과가 좋을수록 앞에 둡니다'.
    한눈 요약 칸의 '먼저 ①'도 '우선 ①'.
  - 그림 '하락폭과 최근 흐름' → '낙폭과 최근 1개월 수익률', 네 칸 이름은 '낙폭 과대, 반등'·'낙폭 과대, 하락 지속'·'고점권, 상승'·'고점권, 조정'.
  - 메일 공포·탐욕 상자(그림을 못 만든 날): '전일 16 → 오늘 25 · 공포가 9p 풀리는 중' → '전일 16에서 오늘 25로 9p 올라 공포가 누그러졌습니다.'
  - 그대로 둔 것: 표시 '분할 N단계'(신호 실전 기록부, 과거 검증 성적, 메일 제목이 이 이름으로 묶임). '추천'이라는 말(화면과 메일이
    '본인 매매 기준을 그대로 적용한 표시이며 매매를 권하는 것이 아닙니다'라고 적고 있어 서로 어긋남).
  - 휴대폰 매수 단계 지도의 값 칸을 92px에서 104px로 넓혀 '3단계까지 −15.1%'가 한 줄에 들어갑니다.
  - 점검: 이 PC에서 수집 스크립트를 돌려 화면과 메일 글을 다시 뽑아 읽고, 1440·390px 화면과 메일 그림을 찍어 겹침·잘림이 없는지 봤습니다.

## Usage

Double-click `run.bat`, or:

```powershell
powershell -ExecutionPolicy Bypass -File Update-StockDashboard.ps1
```

### Adding a ticker

Add a line to `watchlist.json` — only `Symbol` is required, e.g.:

```json
{ "Symbol": "AAPL" }
```

Everything else (display name, market label, news search term, 실적/목표주가 source) is
auto-derived from the symbol: `.KS` → KOSPI, `.KQ` → KOSDAQ, `^` prefix → index, anything else
is assumed NASDAQ. Add an explicit `"DisplayName"`, `"NewsQuery"`, `"MarketLabel"`, or
`"FinanceCode"` in the same entry to override any of those. NYSE tickers need an explicit
`"FinanceCode": "SYMBOL.N"` since the auto-default assumes NASDAQ (`SYMBOL.O`).

갓 상장한 종목도 그대로 넣으면 됩니다(예: SPCX). 자료가 모자란 이평선과 기간 등락은 빈칸으로 두고, 상장 1년 안이면 카드에 상장 달을 적습니다.
넣은 날 이미 분할 단계 안이면 신호 실전 기록부에 '시작일' 신호로 남습니다.

### Price alerts (알림가)

Add `AlertBelow` and/or `AlertAbove` to an entry, in the ticker's own currency:

```json
{ "Symbol": "005930.KS", "AlertBelow": 280000, "AlertAbove": 320000 }
```

- The card shows `⚑ 알림가 이탈 / 돌파` while the latest close is past the level, and the overview
  table flags the row.
- The email subject carries it **only on the day it crosses** (`삼성전자 ₩280,000 이탈`); after
  that the row in the body keeps saying where it stands. A level sitting in every subject until
  the price recovers would stop being read.
- This repo is public, so these levels are too.

### Next earnings date (다음 실적 발표일)

US listings get their next report date from Nasdaq's public analyst endpoint (Zacks data):
`확정` when the company has announced it, `추정` when Zacks projects it from past reporting dates
(that one can move). Dates are US local. Within 3 days it goes into the email subject. Korean
listings have no free source for 잠정실적 dates, so they keep showing the next quarter only.
Yahoo's calendar endpoints were tried first and answer 401 without a session crumb.

The date is fetched **once a day** (the first run, KST) and cached in `earnings-cache.json` —
the endpoint takes 1–3 s per ticker, which was a quarter of a run, and a date moves every few
days at most. If the day's fetch fails, a cached date that has not passed yet is shown instead
of a blank.

Browser-side "add a ticker from the dashboard" isn't possible — Yahoo Finance and Naver's APIs
both block direct cross-origin requests from a browser (CORS), which is why this project fetches
data with a PowerShell script instead of client-side JS in the first place.

## Notes

- Requires only Windows PowerShell 5.1 — no Python/Node/npm.
- `.ps1` files must stay saved as **UTF-8 with BOM**, or Windows PowerShell 5.1 misreads the
  Korean text and the ₩ sign and fails to parse the script.
- **Two years of prices are fetched** (`range=2y`) although the longest view is 1Y. Moving
  averages are computed on the whole series and only the view is cut, so with one year of data
  the 180일선 started at the 180th trading day and covered just the last three months of the 1Y
  chart. The 1Y button cuts by date, not by count (252) — coins trade every day and would show
  only eight months. The 52주 range fallback uses the last year only.
- **English 호재/악재 keywords match whole words** (plus inflections: gains, dropped, losses,
  fallen). Substring matching turned `again`/`against` into gain, `commission` into miss and
  `heartbeat` into beat on every English article. Korean keywords stay substring matches because
  of particles (조사).
- **FX bar dates use the exchange's gmtoffset**, like stock bars. FX bars are stamped at London
  midnight (UTC 23:00), so `.ToLocalTime()` on the UTC runner dated them a day ahead.
- News fetches retry on 503/429 and parse `pubDate` with InvariantCulture; only items that fail
  to parse are dropped.
- JSON injected into the page `<script>` has `</` escaped as `<\/`. pwsh (the runner) doesn't
  escape `<`, so one headline containing `</script>` could blank the whole page. Headlines and
  links in the email are HTML-encoded for the same reason.
- Header text says `매일 아침 갱신(종가 기준)`, which is what it actually is — not real-time.
- **Run time (2026-09): 41 s → about 16 s locally; the Actions `Generate dashboard.html` step
  48 s → 25 s** (the day's later runs, measured 2026-09-26; request by request). Charts and
  news for every ticker are fetched **three at a time up front** (`Invoke-Prefetch`) instead of
  one by one with a 400 ms pause each, and earnings dates are cached per day (above). Whatever
  the concurrent pass fails to get (429/503 included) is simply not cached, so the original
  sequential path fetches it with its retries — the layer can only make a run slower, never
  emptier. The page itself was left alone: 83 KB compressed and about 80 ms to render on this
  laptop.
- Every web request without its own `-TimeoutSec` now gets **30 s** by default
  (`$PSDefaultParameterValues`). Eight calls here had none, i.e. no limit at all; in
  work-dashboard one such call held a CI run for 296 s.

## Email summary (GitHub Actions only)

The daily workflow (`.github/workflows/update-dashboard.yml`) emails `email-summary.html` to
`jhyupkim@unid.co.kr` via Gmail SMTP after each run. One-time setup, done outside this repo:

1. On the sending Gmail account, turn on 2-Step Verification, then generate an App Password at
   [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords).
2. In the repo: **Settings → Secrets and variables → Actions → New repository secret**, add:
   - `GMAIL_USERNAME` — the sending Gmail address
   - `GMAIL_APP_PASSWORD` — the 16-character app password from step 1
3. To change the recipient, edit the `to:` line in the workflow's "Send email summary" step.

Local runs (`run.bat`) still generate `email-summary.html` for preview but never send it — only
the Actions workflow has the secrets, and CI-only sending is intentional so testing locally
doesn't spam the inbox.

### Once a day, four slots

**2026-11-28: the mail now arrives at 08:00 KST (Tue–Sat).** Across 11/18–28 the scheduled runs started 4–10 hours
late (the 06:14 slot landed 11:11–14:18, the 13:43 slot after midnight), so "first run sends" meant mail at noon or
midnight. Evening and night slots (KST 16:23, 18:41, 20:23, 22:17, 00:23, 02:13) now aim to land between 03:00 and
07:30; such a run waits until 07:30 (`Hold early runs for the 08:00 mail`), builds, and holds the mail until 08:00:00
(`Wait until 08:00 KST`). Runs starting before 07:30 never mail. The morning slots below remain as fallbacks.

The schedule has four morning slots (KST 08:11 / 09:37 / 11:19 / 13:43, Tue–Sat) because GitHub
drops or delays scheduled runs under load — this repo's runs were drifting 2–5 hours. The first
slot that gets through sends; the rest only refresh the page.

`.last-digest` (committed back with the translation cache) holds the KST date of the last mail
that actually left SMTP, and the gate compares it to today. It is written **only after a
confirmed send**: the mail step is `continue-on-error`, so a failed send still leaves a
successful run, and judging by run history would silence every later slot that day.

Manual runs (**Actions → Update Stock Dashboard → Run workflow**) have two inputs:

- `send_email` (default on) — turn off to rebuild the page without mailing
- `force_email` — send even if today's mail already went out
