# Stock Dashboard

Local stock-summary dashboard. No backend, no build step — just PowerShell + a static HTML/JS template.

**Live:** https://jhkim0603.github.io/stockdashboard/ — republished daily by the GitHub Actions workflow.

## Files

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
  workflow so each run doesn't re-translate (and hit 429s) from an empty cache.
- `earnings-cache.json` — next earnings dates as fetched by the day's (KST) first run; later runs
  that day reuse them instead of asking Nasdaq again. Committed back by the workflow.
- `signal-log.json` — 신호 실전 기록부(신호가 켜진 날짜·종가·시장 지수 값, 분할 단계 구간). 스크립트가 쓰고 workflow 가 커밋합니다.
- `news-filter.ps1` — 뉴스 제목 거르기(`Test-SpamHeadline`). work-dashboard 와 같은 파일이며 워크플로가 서로 비교합니다.
- `target-cache.json` — 증권사 목표주가 평균의 날짜별 기록(종목마다 한 줄, 400일치). 전 기록과 비교해 바뀐 날을 알리는 데
  쓰므로 workflow 가 다른 캐시와 함께 커밋합니다. 로컬 실행 뒤에는 지우거나 `git checkout` 합니다.
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
- **Per card:** price and change, 1M/3M/6M/1Y chart with 20/60/180일 moving averages, 52주 범위 안의 위치 막대,
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
