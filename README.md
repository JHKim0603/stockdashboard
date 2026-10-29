# Stock Dashboard

Local stock-summary dashboard. No backend, no build step — just PowerShell + a static HTML/JS template.

**Live:** https://jhkim0603.github.io/stockdashboard/ — republished daily by the GitHub Actions workflow.

## Files

- `Update-StockDashboard.ps1` — fetches live quotes (Yahoo Finance chart API, no key), recent
  headlines (Google News RSS, no key), quarterly financials + analyst consensus (Naver Finance,
  no key) for the tickers listed in `watchlist.json`, then renders `template.html` into
  `dashboard.html`.
- `watchlist.json` — the ticker list. Only `"Symbol"` is required.
- `template.html` — the dashboard UI: per-card 1M/3M/6M/1Y range toggle + 20/60/180일 이동평균선
  with a plain-language trend comment (cross event, 정배열/역배열), sparkline with hover tooltip,
  a "최근 이슈" news list (real article titles/links, not AI-written summaries), 실적/목표주가
  popups. See "What's on the page" below.
- `translation-cache.json` — English headline → Korean translations, committed back by the
  workflow so each run doesn't re-translate (and hit 429s) from an empty cache.
- `earnings-cache.json` — next earnings dates as fetched by the day's (KST) first run; later runs
  that day reuse them instead of asking Nasdaq again. Committed back by the workflow.
- `run.bat` — double-click launcher (bypasses PowerShell execution-policy prompts).
- `dashboard.html` — generated output, opened automatically after each run. Not tracked in git.
- `email-summary.html` / `email-subject.txt` — generated daily email body/subject (price + top
  2 headlines per ticker, golden/dead cross tags). Written every run for local preview; actually
  *sending* it only happens in the GitHub Actions workflow. Not tracked in git.

## What's on the page

- **한눈 요약 (2026-10-28, work-dashboard 요약판을 옮겨 온 것)**: 카드 위 한 덩어리로 세 부분입니다.
  - **분야별 등락 지도** (Finviz 지도 방식): `watchlist.json` 의 `Group`(국내 반도체, 미국 반도체, 빅테크·AI, 시장 지수,
    코인; 없으면 시장으로 자동 분류)마다 한 줄, 종목마다 타일 하나. [오늘]·[1주]·[1개월]·[연초 대비]·[1년]으로 기간을 바꿔
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
  - **매수 기준 도달**: 닿았고, 5거래일 전 종가가 이평선 위 1% 밖에 있었던 경우(위에서 내려온 눌림목, `fromAboveOnly`).
    아래에서 올라와 닿은 경우는 카드에 '(아래에서 닿음)'으로만 적습니다.
  - **매수 대기**: 종가가 이평선 위 3% 안(`nearPct`).
  - 표시: 지금 주목할 점 맨 위([매수 기준], [매수 대기]), 등락 지도 타일의 '◎ 20일선 도달', 기간별 표의 '이평선' 칸, 카드 가격 줄
    배지와 '이평선과의 거리' 줄, 메일 종목 줄. 메일 제목에는 처음 닿은 날만 '샌디스크 180일선 도달'처럼 올립니다.
  - 그날 저가는 야후 일봉의 저가(장중이면 그때까지의 저가)입니다. 본인 매매 기준을 그대로 적용한 표시이며 매매를 권하는 것이 아닙니다.
- **다가오는 일정 (120일)**: 미국 종목 실적 발표일(Nasdaq/Zacks)과 `market-calendar.json` 의 시장 일정(FOMC, 미국 CPI,
  한국은행 금통위, 미국·한국 증시 휴장일)을 날짜순 한 목록으로 보여 줍니다. **`market-calendar.json` 은 매년 초에 그해 일정을
  더해야 합니다**(2027년 한국 증시 설 연휴는 한국거래소 발표 뒤 추가).
- **카드 구역과 바로가기**: 카드를 분야별 구역으로 나누고, 위에 [한눈 요약]·[일정]·분야별 바로가기가 따라옵니다.
- **차트 표시**: 카드 차트에 화면 기간 안의 20/60일선 교차 지점을 세로 점선(골든 빨강, 데드 파랑)으로, 알림가를 주황 가로선으로
  그립니다(마우스를 올리면 날짜와 값).
- **색**: 가격 방향은 국내 증권 앱처럼 **상승 빨강, 하락 파랑**입니다. `template.html` 맨 위 색 정의의 `--rise`/`--fall` 한곳에서
  정하므로, 미국식으로 되돌리려면 그 값을 `var(--good)`/`var(--bad)` 로 바꾸면 됩니다. 메일도 같은 색입니다.
- **글자와 문구**: 화면 글자는 12px 이상입니다. 화면·메일 문구는 사내 문서 문체(-습니다, 한 문장에 한 내용, 줄표·가운뎃점 나열
  없음)로 씁니다. 이동평균 추세 표시는 "골든크로스, 상승 전환", "정배열, 상승 추세", "단기 하락"처럼 짧게 적습니다.
- **화면 크기**: 1800px 이상에서는 페이지 최대 폭을 1,760px(2,300px 이상은 2,160px)로 넓힙니다.
- **Per card:** price and change, 1M/3M/6M/1Y chart with 20/60/180일 moving averages, 52주 범위,
  거래량 with `평균의 N배` (vs the prior 20 trading days' average, highlighted at 2× and over),
  target price, next earnings (US listings), alert-level flag, and the 최근 이슈 news list.
- **News tags:** `[호재]` / `[악재]` come from headline keywords only (not the article body).
  English headlines are machine-translated; the link always goes to the original.
- **Stale warning:** the 조회 시각 pill turns red with `N시간 전 데이터` once the data is over
  26 hours old. KST Sunday/Monday runs are skipped on purpose, so from Sunday until the Tuesday
  slots finish (14:00 KST) up to 80 hours counts as normal. Before this the pill was always green,
  so a stopped workflow looked like today's page.
- Long prices (₩1,862,000, BTC in won) drop one font size so the change pill stays on the same
  line; otherwise that card's chart sat lower than its neighbour's.

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
