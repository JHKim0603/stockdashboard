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
  popups.
- `run.bat` — double-click launcher (bypasses PowerShell execution-policy prompts).
- `dashboard.html` — generated output, opened automatically after each run. Not tracked in git.
- `email-summary.html` / `email-subject.txt` — generated daily email body/subject (price + top
  2 headlines per ticker, golden/dead cross tags). Written every run for local preview; actually
  *sending* it only happens in the GitHub Actions workflow. Not tracked in git.

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

Browser-side "add a ticker from the dashboard" isn't possible — Yahoo Finance and Naver's APIs
both block direct cross-origin requests from a browser (CORS), which is why this project fetches
data with a PowerShell script instead of client-side JS in the first place.

## Notes

- Requires only Windows PowerShell 5.1 — no Python/Node/npm.
- `.ps1` files must stay saved as **UTF-8 with BOM**, or Windows PowerShell 5.1 misreads the
  Korean text and the ₩ sign and fails to parse the script.

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
