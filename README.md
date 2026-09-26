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

- **한눈에 보기 (overview table)** above the cards: 종목 · 현재가 · 등락률 · 추세. Two columns on a
  wide screen (read top-to-bottom, left column first), one on narrow; on a phone the trend and
  ticker columns are hidden. Clicking the 등락률 header cycles 상승 큰 순 → 하락 큰 순 → original
  order; clicking a row scrolls to that card. Added because 13 cards took four screens to answer
  "what moved today".
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
- **Run time (2026-09): 41 s → about 16 s** (measured locally, request by request). Charts and
  news for every ticker are fetched **three at a time up front** (`Invoke-Prefetch`) instead of
  one by one with a 400 ms pause each, and earnings dates are cached per day (above). Whatever
  the concurrent pass fails to get (429/503 included) is simply not cached, so the original
  sequential path fetches it with its retries — the layer can only make a run slower, never
  emptier. The page itself was left alone: 83 KB compressed and about 80 ms to render on this
  laptop.

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
