<#
  Update-StockDashboard.ps1
  Fetches live quotes (Yahoo Finance) + recent headlines (Google News RSS) for the tickers below
  and regenerates dashboard.html.
  Run manually by double-clicking run.bat, or right-click > Run with PowerShell.
#>

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
# 제한 시간을 따로 적지 않은 요청의 기본값. 없으면 무기한이라, 응답 없는 서버 하나가 실행 전체를
# 몇 분씩 붙잡는다(work-dashboard 에서 SSE 한 건이 296초). -TimeoutSec 을 직접 적은 호출은 그 값이 우선한다.
$PSDefaultParameterValues['Invoke-RestMethod:TimeoutSec'] = 30
$PSDefaultParameterValues['Invoke-WebRequest:TimeoutSec'] = 30

# Tickers live in watchlist.json, not here — only "Symbol" is required, e.g. { "Symbol": "AAPL" }.
# Everything else (DisplayName, MarketLabel, NewsQuery, NewsLang, FinanceMode/Code) is optional and
# auto-derived from the symbol below; set any of them explicitly in watchlist.json to override.
#   Symbol suffix convention: ".KS" = KOSPI, ".KQ" = KOSDAQ, "^" prefix = index, "XXX-USD"/"XXX-KRW" = 코인
#   (-KRW 는 Yahoo 가 날짜별 환율로 환산한 원화 시세),
#   anything else = NASDAQ
#   (NYSE tickers need an explicit "FinanceCode": "SYMBOL.N" override — the auto-default assumes NASDAQ)
#   ETF 는 "FinanceMode": "none" 과 "MarketLabel", "PageUrl" 을 직접 적는다. 예: QLD(NYSE Arca).
function Resolve-TickerConfig {
    param($raw)

    $symbol = $raw.Symbol
    if (-not $symbol) { throw "watchlist.json 항목에 Symbol이 없습니다: $($raw | ConvertTo-Json -Compress)" }

    $isIndex = if ($null -ne $raw.IsIndex) { [bool]$raw.IsIndex } else { $symbol.StartsWith("^") }
    $isDomestic = $symbol.EndsWith(".KS") -or $symbol.EndsWith(".KQ")
    # 코인은 실적·목표주가가 없다. 판정하지 않으면 해외주식으로 떨어져 네이버에 "BTC-USD.O" 를
    # 묻고, 메일 링크도 존재하지 않는 BTC-USD:NASDAQ 페이지로 간다.
    $isCrypto = if ($null -ne $raw.IsCrypto) { [bool]$raw.IsCrypto } else { $symbol -match '^[A-Z0-9]+-(USD|KRW)$' }

    $marketLabel =
        if ($raw.MarketLabel) { $raw.MarketLabel }
        elseif ($isIndex) { "지수" }
        elseif ($isCrypto) { "코인" }
        elseif ($symbol.EndsWith(".KS")) { "KOSPI" }
        elseif ($symbol.EndsWith(".KQ")) { "KOSDAQ" }
        else { "NASDAQ" }

    $newsLang = if ($raw.NewsLang) { $raw.NewsLang } elseif ($isDomestic) { "ko" } else { "en" }

    # ETF 는 실적·목표주가가 없어 "FinanceMode": "none" 으로 끈다(지수와 코인처럼 네이버와 Nasdaq 실적 조회를 하지 않는다).
    $financeMode =
        if ($raw.FinanceMode -eq "none") { $null }
        elseif ($raw.FinanceMode) { $raw.FinanceMode }
        elseif ($isIndex -or $isCrypto) { $null }
        elseif ($isDomestic) { "domestic" }
        else { "overseas" }

    $financeCode =
        if ($raw.FinanceCode) { $raw.FinanceCode }
        elseif ($financeMode -eq "domestic") { $symbol -replace '\.KS$|\.KQ$', '' }
        elseif ($financeMode -eq "overseas") { "$symbol.O" }
        else { $null }

    # Optional price alerts, in the ticker's own currency: { "Symbol": "005930.KS", "AlertBelow": 280000 }.
    # This file is public, like the rest of the repo - only put levels here you are fine publishing.
    # 분야. 한눈 요약의 분야별 줄과 카드 구역을 나눈다. watchlist.json 에 "Group" 이 없으면 시장으로 정한다.
    $group =
        if ($raw.Group) { [string]$raw.Group }
        elseif ($isIndex) { "시장 지수" }
        elseif ($isCrypto) { "코인" }
        elseif ($isDomestic) { "국내 주식" }
        else { "미국 주식" }

    # 종목별로 다른 이평선을 보려면 watchlist.json 에 "BuyMA": [60, 120] 처럼 적는다.
    $buyMa = if ($raw.BuyMA) { @($raw.BuyMA | ForEach-Object { [int]$_ }) } else { $null }
    # 분할 매수 단계의 고점 대비 하락 기준(%)을 종목별로 바꾸려면 "DipSteps": [20, 40, 60] 처럼 적는다.
    $dipSteps = if ($raw.DipSteps) { @($raw.DipSteps | ForEach-Object { [double]$_ }) } else { $null }

    $alertBelow = if ($null -ne $raw.AlertBelow) { [double]$raw.AlertBelow } else { $null }
    $alertAbove = if ($null -ne $raw.AlertAbove) { [double]$raw.AlertAbove } else { $null }

    [PSCustomObject]@{
        Symbol      = $symbol
        DisplayName = $raw.DisplayName
        MarketLabel = $marketLabel
        NewsQuery   = $raw.NewsQuery
        NewsLang    = $newsLang
        IsIndex     = $isIndex
        IsCrypto    = $isCrypto
        FinanceMode = $financeMode
        FinanceCode = $financeCode
        AlertBelow  = $alertBelow
        AlertAbove  = $alertAbove
        Group       = $group
        IsDomestic  = $isDomestic
        BuyMA       = $buyMa
        DipSteps    = $dipSteps
        # 메일 가격 링크를 직접 정할 때(NYSE Arca 상장 ETF 처럼 아래 자동 규칙이 맞히지 못하는 경우).
        PageUrl     = $raw.PageUrl
    }
}

$watchlistRaw = Get-Content -Path (Join-Path $root "watchlist.json") -Raw -Encoding UTF8 | ConvertFrom-Json
# 이평선 도달 매수 기준. 사용자가 이평선에 닿았을 때 사는 방식이라, 종목·지수마다 이평선과의 거리를 매일 재서
# 닿으면 '매수 기준 도달', 가까우면 '매수 대기'로 알린다. 기준값은 buy-rules.json 에서 바꾼다.
$buyRules = [PSCustomObject]@{ maWindows = @(20, 60, 180); touchPct = 1.0; nearPct = 3.0; fromAboveOnly = $true
    # 분할 매수 단계(Get-DipSignal). 52주 고점 대비 하락률과 장기 이평선(120·200일선) 도달로 1~3단계를 정한다.
    dip = [PSCustomObject]@{ drawdownSteps = @(10.0, 20.0, 30.0); maSteps = @(120, 200) } }
$buyRulesPath = Join-Path $root "buy-rules.json"
if (Test-Path $buyRulesPath) {
    try {
        $br = Get-Content -Path $buyRulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($br.maWindows) { $buyRules.maWindows = @($br.maWindows | ForEach-Object { [int]$_ }) }
        if ($null -ne $br.touchPct) { $buyRules.touchPct = [double]$br.touchPct }
        if ($null -ne $br.nearPct) { $buyRules.nearPct = [double]$br.nearPct }
        if ($null -ne $br.fromAboveOnly) { $buyRules.fromAboveOnly = [bool]$br.fromAboveOnly }
        if ($br.dip) {
            if ($br.dip.drawdownSteps) { $buyRules.dip.drawdownSteps = @($br.dip.drawdownSteps | ForEach-Object { [double]$_ }) }
            if ($br.dip.maSteps) { $buyRules.dip.maSteps = @($br.dip.maSteps | ForEach-Object { [int]$_ }) }
        }
    } catch { Write-Warning "buy-rules.json 을 읽지 못해 기본값(20·60·180일선, 1%, 3%)을 씁니다: $($_.Exception.Message)" }
}

$tickers = @($watchlistRaw | ForEach-Object { Resolve-TickerConfig $_ })

$currencySymbols = @{ KRW = "₩"; USD = "$"; }
$newsLocales = @{
    ko = @{ hl = "ko";    gl = "KR"; ceid = "KR:ko" }
    en = @{ hl = "en-US"; gl = "US"; ceid = "US:en" }
}
$headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" }

# 같은 엔드포인트를 client 파라미터만 바꿔 순서대로 시도한다.
#
# 쿼터가 IP 하나로만 잡히는 게 아니라 client 값마다 따로 잡힌다. 실측으로, 같은 회선에서
# client=gtx 는 429 를 돌려주는 순간에도 client=dict-chrome-ex 는 10줄 배치를 정상 응답했다.
# 그래서 하나가 막히면 다음 것으로 넘어간다 — 같은 것을 더 조르는 재시도와는 다르다.
#
# dict-chrome-ex 를 앞에 둔 이유는 지금 살아 있는 쪽이기 때문이고, 응답 모양이 gtx 와 같아서
# 파서를 하나만 쓰면 된다.
$translateClients = @("dict-chrome-ex", "gtx")

function Get-KoreanTranslation {
    param($text)

    foreach ($client in $translateClients) {
        $uri = "https://translate.googleapis.com/translate_a/single?client=$client&sl=en&tl=ko&dt=t&q=" + [uri]::EscapeDataString($text)
        try {
            $resp = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 20
            $parsed = $resp.Content | ConvertFrom-Json
            # 입력이 길면 Google 이 $parsed[0] 아래 여러 세그먼트로 쪼개 돌려준다. 각 세그먼트의
            # 번역문이 [0] 이라, 이어 붙이면 원래 줄바꿈이 그대로 살아난다.
            return (($parsed[0] | ForEach-Object { $_[0] }) -join "").Trim()
        } catch {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "?" }
            Write-Warning "번역 실패 (client=$client, HTTP $status)"
        }
    }
    $null
}

# 번역 캐시. 한 번 번역한 제목은 다시 물어보지 않는다.
#
# 이게 핵심인 이유: 이 엔드포인트는 IP 단위 누적 요청 수로 막는데, GitHub Actions 러너는 수많은
# 워크플로가 공유하는 클라우드 IP를 쓴다. 집 IP 에서는 통과하던 요청량이 러너에서는 첫 요청부터
# 429 로 막힌다 — 실제로 한 주 내내 매 실행 40건 넘게 실패했고 페이지 제목의 82% 가 영문으로
# 나갔다. 그러니 "요청을 잘 나눠 보낸다"로는 풀리지 않고, 요청 자체를 없애야 한다.
#
# 캐시가 있으면 어제 번역한 제목은 오늘 네트워크를 타지 않는다. 뉴스 제목은 며칠씩 같은 것이
# 반복되므로, 하루 몇 건만 새로 물어보면 되고 그 몇 건이 429 로 실패해도 나머지는 한글로 남는다.
$translationCachePath = Join-Path $root "translation-cache.json"

function Import-TranslationCache {
    $cache = @{}
    if (-not (Test-Path $translationCachePath)) { return $cache }
    try {
        $raw = Get-Content -Path $translationCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) {
            $cache[$p.Name] = [PSCustomObject]@{ ko = $p.Value.ko; seen = $p.Value.seen }
        }
    } catch {
        Write-Warning "번역 캐시를 읽지 못해 빈 캐시로 시작합니다: $($_.Exception.Message)"
    }
    $cache
}

function Export-TranslationCache {
    param($cache, $today)
    # 오래 안 쓴 항목은 버린다. 안 그러면 파일이 무한정 자라고, 지난달 헤드라인은 다시 나오지 않는다.
    $cutoff = ([datetime]$today).AddDays(-60).ToString("yyyy-MM-dd")
    $out = [ordered]@{}
    foreach ($k in ($cache.Keys | Sort-Object)) {
        $v = $cache[$k]
        if ($v.ko -and $v.seen -ge $cutoff) { $out[$k] = @{ ko = $v.ko; seen = $v.seen } }
    }
    $json = ConvertTo-Json -InputObject $out -Depth 4
    [System.IO.File]::WriteAllText($translationCachePath, $json, (New-Object System.Text.UTF8Encoding $false))
    $out.Count
}

# 캐시에 없는 제목만, 여러 건을 줄바꿈으로 이어 한 요청에 보낸다.
#
# 실패했을 때 개별 번역으로 되돌리지 않는 것이 지난번과 달라진 점이다. 그 되돌림이 상황을 정확히
# 거꾸로 만들고 있었다 — 배치가 429 로 막히면 제목 4건을 각각 3회씩 다시 물어봐서, 이미 우리를
# 거절한 엔드포인트에 요청을 1건에서 13건으로 늘렸다. 거절당했을 때 할 일은 더 조르는 게 아니라
# 물러나는 것이다. 줄 수가 어긋난 경우(응답은 왔는데 대응이 깨진 경우)에만 그 묶음을 버린다.
function Invoke-TranslationBatch {
    param([string[]]$texts, $cache, $today)

    # 줄바꿈이 든 제목은 split 을 깨뜨리므로 묶지 않는다 — 그냥 번역하지 않고 원문으로 둔다.
    $batchable = @($texts | Where-Object { $_ -and $_ -notmatch "[`r`n]" })
    if ($batchable.Count -eq 0) { return 0 }

    $done = 0
    # 한 요청에 10줄씩. URL 길이(제목 10건이면 인코딩 후 2~3KB)와 정렬 실패 시 잃는 양 사이의 절충.
    for ($i = 0; $i -lt $batchable.Count; $i += 10) {
        $chunk = @($batchable[$i..([Math]::Min($i + 9, $batchable.Count - 1))])
        $result = Get-KoreanTranslation ($chunk -join "`n")
        if (-not $result) {
            # 429 이거나 응답이 없다. 다음 묶음도 같은 벽에 부딪힐 테니 이번 실행은 여기서 접는다.
            Write-Warning "번역 배치 실패 — 남은 $($batchable.Count - $i)건은 이번 실행에서 원문으로 둡니다."
            break
        }
        $lines = @($result -split "`r?`n")
        if ($lines.Count -ne $chunk.Count) {
            # 응답은 왔지만 줄 대응이 깨졌다. 엉뚱한 링크에 엉뚱한 한글 제목이 붙는 것보다
            # 번역이 안 되는 편이 낫다.
            Write-Warning "번역 배치 줄 수 불일치 ($($lines.Count)/$($chunk.Count)) — 이 묶음은 원문으로 둡니다."
            continue
        }
        for ($j = 0; $j -lt $chunk.Count; $j++) {
            $ko = $lines[$j].Trim()
            if ($ko) { $cache[$chunk[$j]] = [PSCustomObject]@{ ko = $ko; seen = $today }; $done++ }
        }
        Start-Sleep -Milliseconds 700
    }
    $done
}

# 호재/악재 판별 키워드. 기사 제목만 보고 판단하는 단순 규칙 기반 분류라 100% 정확하지 않음 —
# 대시보드/이메일에도 "참고용" 이라고 표기하고, 애매하면 굳이 한쪽으로 몰지 않고 중립으로 둔다.
# 영문 기사는 이미 한국어로 번역된 제목을 넘겨받으므로 한글 키워드만으로 대부분 커버되지만,
# 번역이 실패했을 때를 대비해 영문 키워드도 같이 둔다.
$sentimentKeywords = @{
    good = @(
        "급등", "상승", "강세", "훈풍", "호조", "호실적", "최고가", "신고가", "사상 최대", "사상 최고",
        "수주", "계약 체결", "공급 계약", "흑자", "개선", "성장", "확대", "돌파", "반등", "회복",
        "기대감", "목표가 상향", "상향 조정", "매수", "투자 확대", "수혜", "선정", "인수",
        "surge", "soar", "jump", "rally", "beat", "record high", "upgrade", "outperform", "gain"
    )
    bad = @(
        "급락", "하락", "약세", "폭락", "부진", "적자", "감소", "축소", "우려", "리스크", "악재",
        "하향 조정", "목표가 하향", "매도", "손실", "리콜", "결함", "제재", "과징금", "소송", "고발",
        "파업", "중단", "지연", "철수", "구조조정", "위기", "경고", "논란", "조사", "압수수색",
        "plunge", "slump", "tumble", "drop", "fall", "miss", "downgrade", "underperform", "loss", "probe"
    )
}

# 영문 키워드는 단어 단위로만 센다. 부분일치로 두면 again·against 가 gain(호재)으로,
# mission·commission 이 miss(악재)로, heartbeat 가 beat 로 잡힌다 — 번역이 붙어도 원문 제목을
# 같이 판별하므로 영문 기사 전부가 이 오탐을 탄다. 활용형(gains, dropped, losses, fallen)은
# 원래 부분일치가 잡던 것이라 접미사로 살려 둔다. 한글은 조사가 붙으므로 부분일치 그대로다.
function Test-SentimentKeyword {
    param($title, $keyword)
    if ($keyword -match '^[\x00-\x7F]+$') {
        return $title -match ('\b' + [regex]::Escape($keyword) + '(?:s|es|d|ed|en|ing|ped|ping)?\b')
    }
    $title -like "*$keyword*"
}

function Get-NewsSentiment {
    # 제목에 등장한 호재/악재 키워드 수를 세어 더 많은 쪽으로 분류. 동점이거나 하나도 없으면 중립.
    param($title)
    if (-not $title) { return "neutral" }
    $goodHits = @($sentimentKeywords.good | Where-Object { Test-SentimentKeyword $title $_ }).Count
    $badHits  = @($sentimentKeywords.bad  | Where-Object { Test-SentimentKeyword $title $_ }).Count
    if ($goodHits -gt $badHits) { return "good" }
    if ($badHits -gt $goodHits) { return "bad" }
    return "neutral"
}

# --- 동시 선조회 ------------------------------------------------------------------------
# 종목마다 차트·뉴스를 하나씩 받고 400ms 씩 쉬던 것을, 주소를 미리 알 수 있는 것(차트, 뉴스)은
# 몇 건씩 동시에 받아 두는 것으로 바꿨다. 아래 함수들은 받아 둔 것이 있으면 그것을 쓰고, 동시
# 조회에서 실패한 주소(429/503 포함)는 받아 두지 않으므로 원래의 순차 경로가 재시도와 함께
# 처리한다 - 이 층이 망가져도 느려질 뿐 결과가 비지는 않는다. work-dashboard 와 같은 구현이다.
Add-Type -AssemblyName System.Net.Http
$script:prefetched = @{}

function Invoke-Prefetch {
    param([string[]]$urls, [int]$concurrency = 3, [int]$timeoutSec = 25, [int]$pauseMs = 300)
    $urls = @($urls | Where-Object { $_ } | Select-Object -Unique)
    if ($urls.Count -eq 0) { return }
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($timeoutSec)
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", $headers["User-Agent"])
    $got = 0
    try {
        for ($i = 0; $i -lt $urls.Count; $i += $concurrency) {
            $batch = @($urls[$i..([Math]::Min($i + $concurrency, $urls.Count) - 1)])
            $tasks = @(foreach ($u in $batch) { $client.GetAsync($u) })
            # 하나라도 실패하면 WaitAll 이 던진다. 개별 상태를 아래에서 보므로 여기서는 삼킨다.
            try { [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks) } catch { }
            for ($j = 0; $j -lt $batch.Count; $j++) {
                $t = $tasks[$j]
                if ($t.Status -ne [System.Threading.Tasks.TaskStatus]::RanToCompletion) { continue }
                if (-not $t.Result.IsSuccessStatusCode) { continue }
                $script:prefetched[$batch[$j]] = $t.Result.Content.ReadAsStringAsync().Result
                $got++
            }
            if ($i + $concurrency -lt $urls.Count) { Start-Sleep -Milliseconds $pauseMs }
        }
    } finally {
        $client.Dispose()
    }
    Write-Host "  동시 조회 $got/$($urls.Count)건 (나머지는 순차 조회로 재시도)"
}

function Get-Prefetched {
    param([string]$url)
    if (-not $script:prefetched.ContainsKey($url)) { return $null }
    $content = $script:prefetched[$url]
    $script:prefetched.Remove($url)
    $content
}

function Get-NewsUri {
    # $withinDays 는 두 호출부(Invoke-Prefetch 용 URI 목록, Get-NewsHeadlines)가 같은 기본값을
    # 써야 한다 - URI 가 곧 선수집 캐시의 키라, 한쪽만 바꾸면 캐시가 매번 빗나가 전부 다시 받는다.
    param($query, $lang, $withinDays = 21)
    $loc = $newsLocales[$lang]
    $scoped = if ($withinDays -gt 0) { "$query when:${withinDays}d" } else { $query }
    "https://news.google.com/rss/search?q=" + [uri]::EscapeDataString($scoped) + "&hl=$($loc.hl)&gl=$($loc.gl)&ceid=$($loc.ceid)"
}

function Get-ChartUri {
    # 2y, not 1y: the chart's longest view is one year, but a 180-day average needs 180 sessions
    # before its first point. With exactly a year fetched, the 1년 chart drew the 180일선 over
    # only its last three months. The page slices the display back to a year.
    param($symbol)
    "https://query1.finance.yahoo.com/v8/finance/chart/$($symbol)?interval=1d&range=2y"
}

# 도박 스팸 기사 거르기. work-dashboard 의 newsBlocklist 와 같은 방식(단어와 출처 두 가지)이다. 2026-10-29 에 QLD 를
# 'QLD 레버리지 ETF' 로 찾자 'Calgary Roughnecks' 라는 출처의 카지노 광고 글이 최근 이슈에 섞였다.
# work-dashboard 목록에서 '베팅', '배팅', '도박'은 뺐다. 주식 기사에서는 '3배 레버리지 베팅', '거세질 역외 베팅'처럼
# 정상 기사에 흔히 나온다. 목록은 정규식이다(대소문자 무시). 다른 낱말 안에 우연히 들어가는 단어는 앞뒤 글자를 보고 맞춘다:
# '포커'는 '[마켓포커스]'와 '포커스온경제', '토토'는 '포토토크', '야동'은 '분야동향', '머니상'은 '머니상승'에 걸린다.
# 단어를 아예 빼면 안 된다. 2026-10-29 실제 스팸 제목은 '토토 hydra 보너스 기능', '토트넘 뉴캐슬 토토 진행 구조'처럼
# '토토' 하나만 들어 있었다.
$spamKeywords = @("카지노", "casino", "바카라", "baccarat", "슬롯머신", "(?<!포)토토", "벳365", "bet365", "먹튀", "홀덤",
    "포커(?!스)", "사설놀이터", "머니상(?!승)", "성인용품", "(?<!분)야동", "비아그라")
$spamSources = @("Calgary Roughnecks", "icaremn\.com", "Spazio Aperto Salento", "Platea Magazine", "plateamagazine", "casinotoki")
$script:spamBlocked = 0
function Test-SpamHeadline {
    param([string]$title, [string]$source)
    $haystack = "$title $source"
    $hit = @($spamKeywords | Where-Object { $haystack -match $_ }) + @($spamSources | Where-Object { $source -and $source -match $_ })
    if (-not $hit.Count) { return $false }
    # 걸러낸 제목을 실행 기록에 남긴다. 정상 기사가 잘못 걸리면 여기서 보인다.
    $script:spamBlocked++
    Write-Host "    (스팸 차단 '$($hit[0])': $source | $title)"
    return $true
}

function Get-NewsHeadlines {
    # Google News RSS 는 관련도순이고 기간을 묻지 않으면 기간을 따지지 않는다. 그래서 앞에서
    # N건을 자르면 "역대 가장 잘 맞는 기사"가 나온다 - work-dashboard 에서 322일, 1,569일 전
    # 기사가 "최근 이슈"로 올라온 원인이 이것이었다. 이 저장소는 인기 종목뿐이라 아직 드러나지
    # 않았을 뿐 같은 구조였다. 기간을 걸어 묻고, 받은 뒤 날짜로 거르고 최신순으로 자른다.
    param($query, $lang, $max = 4, $withinDays = 21)

    $uri = Get-NewsUri -query $query -lang $lang -withinDays $withinDays
    # Google sheds load on the runner's shared IP with 503/429 in bursts. work-dashboard lost
    # every query to it twice on 2026-09-10 and got a retry; this copy of the fetch never did, so
    # one bounce emptied a ticker's news for the day. Retry only throttling - other errors will
    # not improve by asking again.
    $content = Get-Prefetched $uri
    for ($try = 1; $try -le 3 -and -not $content; $try++) {
        try {
            $content = (Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 25).Content
        } catch {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if (($status -ne 503 -and $status -ne 429) -or $try -eq 3) {
                Write-Warning "News fetch failed for '$query' (HTTP $status): $($_.Exception.Message)"
                return @()
            }
            Start-Sleep -Seconds ($try * 4)
        }
    }
    try {
        [xml]$rss = $content
        $items = @($rss.rss.channel.item)
        $cutoff = (Get-Date).ToUniversalTime().AddDays(-$withinDays)

        # Titles are cleaned up first, so this query's headlines can be translated as one batch
        # below rather than one request each.
        $parsed = @(foreach ($it in $items) {
            $title = $it.title
            $source = $null
            # Google News sometimes appends the outlet name twice (native + romanized), e.g. "... - 조선비즈 - Chosunbiz"
            for ($k = 0; $k -lt 2; $k++) {
                if ($title -match '^(.*) - ([^-]{1,40})$') {
                    $title = $matches[1].Trim(); $source = $matches[2].Trim()
                } else { break }
            }
            # RFC-822 with English day/month names; parsed under the machine's culture it can fail
            # on a Korean Windows, and a throw here loses the whole feed rather than one item.
            # Same fix work-dashboard carries. Skip the one item instead.
            $pubDate = $null
            try {
                $pubDate = [System.DateTimeOffset]::Parse($it.pubDate, [System.Globalization.CultureInfo]::InvariantCulture)
            } catch {
                Write-Warning "  (pubDate 파싱 실패, 기사 생략: '$($it.pubDate)')"
                continue
            }
            # 날짜를 확인할 수 없거나 기간 밖이면 버린다 - 이 목록의 존재 이유가 최신성이다.
            if ($pubDate.UtcDateTime -lt $cutoff) { continue }
            # 자르기 전에 거른다. 자른 뒤에 거르면 스팸이 빠진 만큼 기사 수가 줄어든다.
            if (Test-SpamHeadline -title $title -source $source) { continue }
            [PSCustomObject]@{
                title   = $title
                source  = $source
                pubDate = $pubDate
                link    = $it.link
            }
        })
        $parsed = @($parsed | Sort-Object { $_.pubDate.UtcDateTime } -Descending | Select-Object -First $max)
        if ($parsed.Count -eq 0) { Write-Host "    (최근 ${withinDays}일 내 '$query' 기사 없음)" }

        # 여기서는 번역하지 않는다. 종목마다 요청을 내면 20회가 되고, 그 20회가 러너 IP 에서
        # 전부 429 로 막히고 있었다. 전 종목 수집이 끝난 뒤 Resolve-NewsTranslations 가
        # 캐시에 없는 제목만 모아 한 번에 처리한다.
        @(foreach ($p in $parsed) {
            [PSCustomObject]@{
                title         = $p.title
                titleOriginal = $null
                needsKo       = ($lang -eq "en")
                source        = $p.source
                date          = $p.pubDate.ToString("yyyy-MM-dd")
                link          = $p.link
                # 번역 전이라 원문 기준으로 한 번 잡아두고, 번역이 붙으면 아래에서 다시 판별한다.
                sentiment     = Get-NewsSentiment $p.title
            }
        })
    } catch {
        Write-Warning "News fetch failed for '$query': $($_.Exception.Message)"
        @()
    }
}

function Get-FinanceSnapshot {
    param($mode, $code)

    if (-not $mode -or -not $code) { return $null }

    try {
        # Quarterly, not annual: annual periods are ~1 year apart and stale for most of the
        # year; quarterly gives 5-6 recent reporting periods, which is what's actually useful here.
        if ($mode -eq "domestic") {
            $uri = "https://m.stock.naver.com/api/stock/$code/finance/quarter"
            $resp = Invoke-RestMethod -Uri $uri -Headers $headers
            $fi = $resp.financeInfo
            if (-not $fi -or -not $fi.trTitleList -or $fi.trTitleList.Count -eq 0) { return $null }
            $periods = $fi.trTitleList
            $rows = $fi.rowList
            $summaryParts = @($resp.corporationSummary.comment1, $resp.corporationSummary.comment2) | Where-Object { $_ }
            $summary = if ($summaryParts) { $summaryParts -join " " } else { $null }
            $unit = "억원"
        } else {
            $uri = "https://api.stock.naver.com/stock/$code/finance/quarter"
            $resp = Invoke-RestMethod -Uri $uri -Headers $headers
            if (-not $resp.trTitleList -or $resp.trTitleList.Count -eq 0) { return $null }
            $periods = $resp.trTitleList
            $rows = $resp.rowList
            $summary = $null
            $unit = $resp.unit
        }

        $wantedTitles = @("매출액", "영업이익", "EBIT", "당기순이익", "EPS")
        $orderedPeriods = @($periods | Sort-Object key)
        $today = Get-Date

        $rowsOut = foreach ($rowTitle in $wantedTitles) {
            $row = $rows | Where-Object { $_.title -eq $rowTitle } | Select-Object -First 1
            if (-not $row) { continue }
            [PSCustomObject]@{
                title  = if ($rowTitle -eq "EBIT") { "영업이익(EBIT)" } else { $rowTitle }
                values = @(foreach ($p in $orderedPeriods) {
                    $col = $row.columns.($p.key)
                    if ($col -and $col.value) { $col.value } else { "-" }
                })
            }
        }
        if (-not $rowsOut) { return $null }

        $periodsOut = foreach ($p in $orderedPeriods) {
            $isEstimate = $false
            if ($mode -eq "domestic") {
                # Domestic quarters flag consensus (not-yet-reported) periods explicitly and reliably.
                $isEstimate = ($p.isConsensus -eq "Y")
            } else {
                # Overseas quarters don't set isConsensus reliably; a period whose end date hasn't
                # happened yet is necessarily a forecast, so fall back to a date comparison.
                [DateTime]$parsedEnd = Get-Date
                if ([DateTime]::TryParse($p.key, [ref]$parsedEnd)) { $isEstimate = $parsedEnd -gt $today }
            }
            [PSCustomObject]@{ label = $p.title; isEstimate = $isEstimate }
        }

        $nextEstimateLabel = ($periodsOut | Where-Object { $_.isEstimate } | Select-Object -Last 1).label

        # Valuation band (PER/PBR trend + min/avg/max over the same quarters already fetched
        # above — no extra request). Naver's overseas quarterly data only has PBR, not PER.
        $valuation = foreach ($metric in @("PER", "PBR")) {
            $row = $rows | Where-Object { $_.title -eq $metric } | Select-Object -First 1
            if (-not $row) { continue }
            $points = for ($i = 0; $i -lt $orderedPeriods.Count; $i++) {
                $p = $orderedPeriods[$i]
                $col = $row.columns.($p.key)
                $val = if ($col -and $col.value -and $col.value -ne "-") { [double]($col.value -replace ',', '') } else { $null }
                [PSCustomObject]@{ label = $p.title; isEstimate = $periodsOut[$i].isEstimate; value = $val }
            }
            $actualValues = @($points | Where-Object { -not $_.isEstimate -and $null -ne $_.value } | ForEach-Object { $_.value })
            if ($actualValues.Count -lt 2) { continue }  # not enough history for a meaningful band
            [PSCustomObject]@{
                metric = $metric
                points = @($points)
                min    = ($actualValues | Measure-Object -Minimum).Minimum
                max    = ($actualValues | Measure-Object -Maximum).Maximum
                avg    = [math]::Round((($actualValues | Measure-Object -Average).Average), 2)
            }
        }

        $valuation = @($valuation)
        if ($mode -eq "overseas" -and -not ($valuation | Where-Object { $_.metric -eq "PER" })) {
            $annualPer = Get-AnnualPerFallback -code $code
            if ($annualPer) { $valuation = @($annualPer) + $valuation }
        }

        [PSCustomObject]@{
            unit              = $unit
            periods           = @($periodsOut)
            rows              = @($rowsOut)
            summary           = $summary
            nextEstimateLabel = $nextEstimateLabel
            valuation         = $valuation
        }
    } catch {
        Write-Warning "Finance fetch failed for '$code' ($mode): $($_.Exception.Message)"
        $null
    }
}

function Get-AnnualPerFallback {
    # Naver's overseas *quarterly* finance data never includes a PER row (only PBR) — but PER is
    # sometimes present in the *annual* data for the same ticker (e.g. Micron), just with fewer,
    # sparser points (some fiscal years are missing entirely when earnings were negative/undefined
    # that year, which is also why some tickers like SanDisk have no usable PER anywhere at all).
    param($code)

    try {
        $uri = "https://api.stock.naver.com/stock/$code/finance/annual"
        $resp = Invoke-RestMethod -Uri $uri -Headers $headers
        if (-not $resp.trTitleList -or $resp.trTitleList.Count -eq 0) { return $null }
        $row = $resp.rowList | Where-Object { $_.title -eq "PER" } | Select-Object -First 1
        if (-not $row) { return $null }

        $orderedPeriods = @($resp.trTitleList | Sort-Object key)
        $today = Get-Date
        $points = foreach ($p in $orderedPeriods) {
            $col = $row.columns.($p.key)
            $val = if ($col -and $col.value -and $col.value -ne "-") { [double]($col.value -replace ',', '') } else { $null }
            [DateTime]$parsedEnd = Get-Date
            $isEstimate = if ([DateTime]::TryParse($p.key, [ref]$parsedEnd)) { $parsedEnd -gt $today } else { $false }
            [PSCustomObject]@{ label = $p.title; isEstimate = $isEstimate; value = $val }
        }
        $actualValues = @($points | Where-Object { -not $_.isEstimate -and $null -ne $_.value } | ForEach-Object { $_.value })
        if ($actualValues.Count -lt 2) { return $null }

        [PSCustomObject]@{
            metric   = "PER"
            points   = @($points)
            min      = ($actualValues | Measure-Object -Minimum).Minimum
            max      = ($actualValues | Measure-Object -Maximum).Maximum
            avg      = [math]::Round((($actualValues | Measure-Object -Average).Average), 2)
            isAnnual = $true
        }
    } catch {
        Write-Warning "Annual PER fallback failed for '$code': $($_.Exception.Message)"
        $null
    }
}

function Get-ConsensusSnapshot {
    param($mode, $code)

    if (-not $mode -or -not $code) { return $null }

    try {
        $uri = if ($mode -eq "domestic") { "https://m.stock.naver.com/api/stock/$code/integration" } else { "https://api.stock.naver.com/stock/$code/integration" }
        $resp = Invoke-RestMethod -Uri $uri -Headers $headers
        $ci = $resp.consensusInfo
        if (-not $ci -or -not $ci.priceTargetMean) { return $null }

        # No free source publishes each brokerage's individual target price (that's paywalled
        # FnGuide/WiseFn data) — the best available breakdown is the underlying report list
        # (broker name + title + date) behind the consensus average. Domestic-only: Korean
        # brokerages don't publish research on foreign-listed names like MU/SNDK.
        $reports = $null
        if ($mode -eq "domestic") {
            try {
                $researchUri = "https://m.stock.naver.com/api/research/stock/$code"
                $researchResp = Invoke-RestMethod -Uri $researchUri -Headers $headers
                $reports = @($researchResp | Select-Object -First 6 | ForEach-Object {
                    [PSCustomObject]@{
                        broker = $_.brokerName
                        title  = $_.title
                        date   = $_.writeDate
                        link   = "https://finance.naver.com/research/company_read.naver?nid=$($_.researchId)"
                    }
                })
            } catch {
                Write-Warning "Research list fetch failed for '$code': $($_.Exception.Message)"
            }
        }

        # 외국인/기관/개인 순매수 동향 — a KRX-only concept (no equivalent field in the overseas
        # integration response), and it's already sitting in the same response as consensusInfo,
        # so this is free once we're already calling this endpoint for the target price.
        $flowTrend = $null
        if ($mode -eq "domestic" -and $resp.dealTrendInfos) {
            $flowTrend = @($resp.dealTrendInfos | ForEach-Object {
                [PSCustomObject]@{
                    date        = $_.bizdate -replace '^(\d{4})(\d{2})(\d{2})$', '$1-$2-$3'
                    foreigner   = [long]($_.foreignerPureBuyQuant -replace '[+,]', '')
                    institution = [long]($_.organPureBuyQuant -replace '[+,]', '')
                    individual  = [long]($_.individualPureBuyQuant -replace '[+,]', '')
                }
            } | Sort-Object date)
            $latestHoldRatio = $resp.dealTrendInfos[0].foreignerHoldRatio
        }

        [PSCustomObject]@{
            targetPrice      = [double]($ci.priceTargetMean -replace ',', '')
            targetHigh       = if ($ci.priceTargetHigh) { [double]($ci.priceTargetHigh -replace ',', '') } else { $null }
            targetLow        = if ($ci.priceTargetLow)  { [double]($ci.priceTargetLow  -replace ',', '') } else { $null }
            recommScore      = if ($ci.recommMean) { [double]$ci.recommMean } else { $null }
            asOf             = $ci.createDate
            reports          = $reports
            flowTrend        = $flowTrend
            foreignHoldRatio = $latestHoldRatio
        }
    } catch {
        Write-Warning "Consensus fetch failed for '$code' ($mode): $($_.Exception.Message)"
        $null
    }
}

# Next earnings date for US listings, from Nasdaq's public analyst endpoint (Zacks data). Yahoo's
# calendar endpoints now answer 401 without a session crumb, so they are not an option for a
# scheduled script. The response distinguishes a date the company has announced ("is expected")
# from one Zacks projects off past reporting dates ("is estimated ... derived from an algorithm"),
# and the page keeps that difference visible - an estimate can move by weeks.
#
# Korean listings have no free equivalent: 잠정실적 dates are not published ahead of the filing,
# so those cards keep showing the next quarter only.
function Get-EarningsDate {
    # 실패하면 던진다 - 아래 캐시가 '발표일 없음'과 '조회 실패'를 구분해야 해서다.
    param($symbol)
    $nasdaqHeaders = @{
        "User-Agent"      = $headers["User-Agent"]
        "Accept"          = "application/json, text/plain, */*"
        "Accept-Language" = "en-US,en;q=0.9"
    }
    $resp = Invoke-RestMethod -Uri "https://api.nasdaq.com/api/analyst/$([uri]::EscapeDataString($symbol))/earnings-date" -Headers $nasdaqHeaders -TimeoutSec 15
    $text = [string]$resp.data.reportText
    $m = [regex]::Match($text, 'on\s+(\d{2})/(\d{2})/(\d{4})')
    if (-not $m.Success) { return $null }
    $timing = if ($text -match 'after market close') { "장 마감 후" } elseif ($text -match 'before market open') { "장 시작 전" } else { $null }
    [PSCustomObject]@{
        date      = "$($m.Groups[3].Value)-$($m.Groups[1].Value)-$($m.Groups[2].Value)"
        confirmed = ($text -match 'is expected')
        timing    = $timing
    }
}

# 실적 발표일은 하루 한 번만 묻는다. 종목당 1~3초인 이 엔드포인트가 실행 시간의 4분의 1 이었는데,
# 발표일은 며칠에 한 번 바뀔 뿐이고 실행은 아침마다 네 번이다. 그날(KST) 첫 실행이 받아
# earnings-cache.json 에 두고(워크플로가 커밋) 나머지 실행은 그것을 쓴다. 조회가 실패한 날에는
# 아직 지나지 않은 예전 발표일을 그대로 보여 준다 - 빈칸보다 하루 묵은 날짜가 낫다.
$earningsCachePath = Join-Path $root "earnings-cache.json"
$todayKstStr = (Get-Date).ToUniversalTime().AddHours(9).ToString("yyyy-MM-dd")
$script:earningsCache = @{}
if (Test-Path $earningsCachePath) {
    try {
        $rawEc = Get-Content -Path $earningsCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $rawEc.PSObject.Properties) { $script:earningsCache[$p.Name] = $p.Value }
    } catch {
        Write-Warning "earnings-cache.json 을 읽지 못해 발표일을 새로 받습니다: $($_.Exception.Message)"
    }
}
$script:earningsCacheOriginal = if (Test-Path $earningsCachePath) { [System.IO.File]::ReadAllText($earningsCachePath) } else { "" }

function Get-EarningsDateCached {
    param($symbol)
    $hit = $script:earningsCache[$symbol]
    if ($hit -and $hit.fetched -eq $todayKstStr) { return $hit.data }
    try {
        $data = Get-EarningsDate -symbol $symbol
        $script:earningsCache[$symbol] = [PSCustomObject]@{ fetched = $todayKstStr; data = $data }
        return $data
    } catch {
        Write-Warning "Earnings date fetch failed for '$symbol': $($_.Exception.Message)"
        if ($hit -and $hit.data -and [string]$hit.data.date -ge $todayKstStr) { return $hit.data }
        return $null
    }
}

function Save-EarningsCache {
    # 관심종목에서 빠진 종목은 버리고, 내용이 같으면 쓰지 않는다(같은 날 뒤 실행이 커밋을 만들지 않게).
    param($symbols)
    $ordered = [ordered]@{}
    foreach ($s in ($symbols | Sort-Object -Unique)) {
        if ($script:earningsCache.ContainsKey($s)) { $ordered[$s] = $script:earningsCache[$s] }
    }
    $json = ConvertTo-Json -InputObject $ordered -Depth 4
    if ($json -ne $script:earningsCacheOriginal) {
        [System.IO.File]::WriteAllText($earningsCachePath, $json, (New-Object System.Text.UTF8Encoding $false))
    }
}

function Get-StockSnapshot {
    param($cfg)

    $uri = Get-ChartUri $cfg.Symbol
    $prefetchedChart = Get-Prefetched $uri
    # 호출한 루프가 Yahoo 사이 쉬는 시간을 건너뛸 수 있게, 네트워크를 탔는지 남겨 둔다.
    $script:chartFromPrefetch = [bool]$prefetchedChart
    $resp = if ($prefetchedChart) { $prefetchedChart | ConvertFrom-Json } else { Invoke-RestMethod -Uri $uri -Headers $headers }
    $result = $resp.chart.result[0]
    $meta = $result.meta
    $closes = $result.indicators.quote[0].close
    $timestamps = $result.timestamp

    # 봉 날짜는 거래소 현지시각으로 정한다. 예전에는 .ToLocalTime() 이었는데, 그건 이 스크립트가
    # 어느 기계에서 도느냐에 따라 답이 달라진다 — 러너는 UTC, 내 PC 는 KST 다. 장중 봉(미국 13:30
    # UTC)은 어느 쪽에서도 같은 날짜로 떨어져서 여태 티가 안 났지만, 종가 시각(20:00 UTC)은 KST
    # 에서 자정을 넘어가 하루가 밀린다. 아래 meta 보정이 바로 그 시각을 쓰므로 여기서 바로잡는다.
    $exOffset = [TimeSpan]::FromSeconds([int]$meta.gmtoffset)
    function ConvertTo-ExchangeDate($unix) {
        [DateTimeOffset]::FromUnixTimeSeconds($unix).ToOffset($exOffset).ToString("yyyy-MM-dd")
    }

    $lowsArr = $result.indicators.quote[0].low
    $pairs = @(for ($i = 0; $i -lt $closes.Count; $i++) {
        if ($null -ne $closes[$i]) {
            [PSCustomObject]@{
                Date  = ConvertTo-ExchangeDate $timestamps[$i]
                Close = [math]::Round([double]$closes[$i], 2)
                Low   = if ($lowsArr -and $null -ne $lowsArr[$i]) { [math]::Round([double]$lowsArr[$i], 2) } else { [math]::Round([double]$closes[$i], 2) }
            }
        }
    })

    # Yahoo 는 개별종목의 일봉을 지수보다 늦게 확정한다. 미국장 마감 5시간 뒤인 09-10 01:14 UTC
    # 실행에서 지수는 09-09 봉을 받았는데 MU·NVDA 등은 09-08 이 마지막이었고, 그 상태로 메일이
    # 나가 전날 주가가 실린 대시보드가 배달됐다. 같은 코드가 그날 12:56 UTC 에는 09-09 를 정상
    # 수신했으니 코드가 아니라 시점 문제였다.
    #
    # 그런데 meta.regularMarketPrice 에는 그 시점에도 09-09 종가가 들어 있었다. 일봉 배열이
    # 아직 못 따라온 구간에서는 meta 가 유일하게 최신값을 갖고 있으므로, 마지막 봉보다 새로우면
    # 그 값을 한 점 덧붙인다. 실행 시각을 뒤로 미루는 것보다 낫다 — 아침에 받는 메일은 그대로 두고
    # 값만 최신이 된다.
    if ($meta.regularMarketPrice -and $meta.regularMarketTime) {
        $metaDate = ConvertTo-ExchangeDate $meta.regularMarketTime
        if ($pairs.Count -eq 0 -or $metaDate -gt $pairs[-1].Date) {
            $metaLow = if ($meta.regularMarketDayLow -and [double]$meta.regularMarketDayLow -gt 0) { [math]::Round([double]$meta.regularMarketDayLow, 2) } else { [math]::Round([double]$meta.regularMarketPrice, 2) }
            $pairs += [PSCustomObject]@{ Date = $metaDate; Close = [math]::Round([double]$meta.regularMarketPrice, 2); Low = $metaLow }
        }
    }

    $fullSeries = @($pairs.Close)
    $fullLows   = @($pairs.Low)
    $fullDates  = @($pairs.Date)

    # Today's volume against the stock's own 20-session average, from the volume array this same
    # response already carries. The average excludes the latest session by date, since the
    # latest may be the meta point appended above rather than a bar in the array.
    $volumeRatio = $null
    $volumes = $result.indicators.quote[0].volume
    if ($meta.regularMarketVolume -and $volumes) {
        $latestDate = $fullDates[-1]
        $priorVols = @(for ($i = 0; $i -lt $timestamps.Count; $i++) {
            $v = $volumes[$i]
            if ($null -eq $v -or $v -le 0) { continue }
            if ((ConvertTo-ExchangeDate $timestamps[$i]) -lt $latestDate) { [double]$v }
        }) | Select-Object -Last 20
        if (@($priorVols).Count -ge 10) {
            $avgVol = ($priorVols | Measure-Object -Average).Average
            if ($avgVol -gt 0) { $volumeRatio = [math]::Round([double]$meta.regularMarketVolume / $avgVol, 2) }
        }
    }

    # Yahoo's meta.fiftyTwoWeekHigh/Low occasionally comes back as 0 for some tickers;
    # fall back to the min/max of the last year so we never divide by zero. The series itself
    # is two years long now, so it has to be cut to 52 weeks first.
    $yearAgo = ([datetime]$fullDates[-1]).AddYears(-1).ToString("yyyy-MM-dd")
    $lastYear = @($pairs | Where-Object { $_.Date -gt $yearAgo } | ForEach-Object { $_.Close })
    $rangeHigh = if ($meta.fiftyTwoWeekHigh -and $meta.fiftyTwoWeekHigh -gt 0) { $meta.fiftyTwoWeekHigh } else { ($lastYear | Measure-Object -Maximum).Maximum }
    $rangeLow  = if ($meta.fiftyTwoWeekLow  -and $meta.fiftyTwoWeekLow  -gt 0) { $meta.fiftyTwoWeekLow }  else { ($lastYear | Measure-Object -Minimum).Minimum }

    # trailing-20-session stats for the auto-summary sentence (independent of the chart's own zoom range)
    $recent = $pairs | Select-Object -Last 20
    $rSeries = @($recent.Close)
    $first = $rSeries[0]
    $lastVal = $rSeries[-1]
    $periodPct = (($lastVal - $first) / $first) * 100

    $upDays = 0; $downDays = 0
    for ($i = 1; $i -lt $rSeries.Count; $i++) {
        if ($rSeries[$i] -gt $rSeries[$i - 1]) { $upDays++ }
        elseif ($rSeries[$i] -lt $rSeries[$i - 1]) { $downDays++ }
    }

    $pctFromHigh = (($lastVal - $rangeHigh) / $rangeHigh) * 100
    $pctFromLow  = (($lastVal - $rangeLow)  / $rangeLow)  * 100

    # 한 문장에 한 내용. 예전 문구는 가운뎃점과 쉼표로 네 가지를 한 줄에 이어 붙여 읽기 어려웠다.
    $periodWord = if ($periodPct -ge 0) { "높습니다" } else { "낮습니다" }
    $highPart = if ([math]::Abs($pctFromHigh) -lt 0.05) { "52주 고점과 같고" } else { "52주 고점보다 {0:N1}% 낮고" -f [math]::Abs($pctFromHigh) }
    $summary = "최근 {0}거래일 중 {1}일 올랐고 {2}일 내렸습니다. {0}거래일 전보다 {3:N1}% {4}. {5}, 52주 저점보다 {6:N1}% 높습니다." -f `
        $rSeries.Count, $upDays, $downDays, [math]::Abs($periodPct), $periodWord, $highPart, $pctFromLow

    $name = if ($cfg.DisplayName) { $cfg.DisplayName } else { $meta.longName }
    if ($cfg.IsIndex) {
        $currency = ""
        $market = $cfg.MarketLabel
    } else {
        $currency = $currencySymbols[$meta.currency]
        if (-not $currency) { $currency = "$($meta.currency) " }
        $market = $meta.currency
    }

    $newsQuery = if ($cfg.NewsQuery) { $cfg.NewsQuery } else { $name }
    $news = Get-NewsHeadlines -query $newsQuery -lang $cfg.NewsLang
    $finance = Get-FinanceSnapshot -mode $cfg.FinanceMode -code $cfg.FinanceCode
    $consensus = Get-ConsensusSnapshot -mode $cfg.FinanceMode -code $cfg.FinanceCode
    $pageUrl = Get-StockPageUrl -cfg $cfg
    $earnings = if ($cfg.FinanceMode -eq "overseas") { Get-EarningsDateCached -symbol $cfg.Symbol } else { $null }

    [PSCustomObject]@{
        name      = $name
        symbol    = $cfg.Symbol
        ticker    = "$($cfg.Symbol) · $($cfg.MarketLabel)"
        market    = $market
        currency  = $currency
        pageUrl   = $pageUrl
        series    = $fullSeries
        dates     = $fullDates
        volume    = $meta.regularMarketVolume
        volumeRatio = $volumeRatio
        # 거래소 자체 이름. 시세 지연 점검에서 같은 장끼리만 비교하려면 이게 필요하다 —
        # MarketLabel 로는 KOSPI 지수와 나스닥 지수가 똑같이 "지수" 라 한 그룹이 돼버린다.
        exchangeTz = $meta.exchangeTimezoneName
        rangeLow  = $rangeLow
        rangeHigh = $rangeHigh
        # 추세 판정은 여기서 한 번만 하고 페이지는 이 결과를 그대로 쓴다. 전에는 같은 판정이
        # 이 스크립트(메일)와 template.html(페이지)에 한 줄씩 복제돼 있어서, 한쪽만 고치면
        # 메일과 페이지가 같은 종목을 두고 다른 말을 하게 되는 구조였다.
        cross     = Get-CrossSignal -series $fullSeries
        maTrend   = Get-MaTrendComment -series $fullSeries
        maLevels  = Get-MaLevels -series $fullSeries -lows $fullLows -windows $(if ($cfg.BuyMA) { $cfg.BuyMA } else { $buyRules.maWindows })
        dip       = Get-DipSignal -series $fullSeries -lows $fullLows -high $rangeHigh -steps $(if ($cfg.DipSteps) { $cfg.DipSteps } else { $buyRules.dip.drawdownSteps })
        summary   = $summary
        news      = $news
        finance   = $finance
        consensus = $consensus
        earnings  = $earnings
        alertBelow = $cfg.AlertBelow
        alertAbove = $cfg.AlertAbove
        group      = $cfg.Group
        kind       = $(if ($cfg.IsIndex) { "index" } elseif ($cfg.IsCrypto) { "crypto" } elseif ($cfg.IsDomestic) { "kr" } else { "us" })
    }
}

# Korea has no DST, so UTC+9 is always correct — avoids TimeZoneInfo id mismatches between
# Windows PowerShell 5.1 locally ("Korea Standard Time") and pwsh on the Linux Actions runner
# ("Asia/Seoul"), which previously left $fetchedAt on raw runner-local time (UTC in CI).
$nowKst = (Get-Date).ToUniversalTime().AddHours(9)

function Get-MovingAverage {
    param($series, $window)
    $out = New-Object 'object[]' $series.Count
    $sum = 0.0
    for ($i = 0; $i -lt $series.Count; $i++) {
        $sum += $series[$i]
        if ($i -ge $window) { $sum -= $series[$i - $window] }
        $out[$i] = if ($i -ge $window - 1) { $sum / $window } else { $null }
    }
    $out
}

function Get-CrossSignal {
    # The only implementation of this check - the page reads the result (cross) from the stock's
    # JSON instead of re-deriving it. 5-day lookback for an actual sign-flip event, not just "which MA is on top now".
    param($series, $lookback = 5)
    $ma20 = Get-MovingAverage -series $series -window 20
    $ma60 = Get-MovingAverage -series $series -window 60
    $diffs = [System.Collections.ArrayList]@()
    for ($i = $series.Count - 1; $i -ge 0 -and $diffs.Count -lt ($lookback + 1); $i--) {
        if ($null -eq $ma20[$i] -or $null -eq $ma60[$i]) { break }
        [void]$diffs.Insert(0, ($ma20[$i] - $ma60[$i]))
    }
    for ($i = 1; $i -lt $diffs.Count; $i++) {
        if ($diffs[$i - 1] -le 0 -and $diffs[$i] -gt 0) { return "golden" }
        if ($diffs[$i - 1] -ge 0 -and $diffs[$i] -lt 0) { return "dead" }
    }
    return $null
}

function Get-MaTrendComment {
    # The only implementation - page and mail both show this result (maTrend). Priority order
    # (recent cross first, then 20/60/180 stacking), same terse "-임" phrasing. Unlike the
    # cross badge alone, this always returns *something* once there's 20/60 days of history,
    # so every row gets a read, not just the rare days an actual cross happens.
    param($series)
    $ma20 = Get-MovingAverage -series $series -window 20
    $ma60 = Get-MovingAverage -series $series -window 60
    $ma180 = Get-MovingAverage -series $series -window 180
    $i = $series.Count - 1
    $last = $series[$i]
    $a = $ma20[$i]; $b = $ma60[$i]; $c = $ma180[$i]

    $cross = Get-CrossSignal -series $series
    if ($cross -eq "golden") { return @{ text = "골든크로스, 상승 전환"; tone = "up" } }
    if ($cross -eq "dead")   { return @{ text = "데드크로스, 하락 전환"; tone = "down" } }

    if ($null -eq $a -or $null -eq $b) { return $null }  # not enough history yet for even the 20/60 pair

    if ($null -ne $c) {
        if ($last -gt $a -and $a -gt $b -and $b -gt $c) { return @{ text = "정배열, 상승 추세"; tone = "up" } }
        if ($last -lt $a -and $a -lt $b -and $b -lt $c) { return @{ text = "역배열, 하락 추세"; tone = "down" } }
    }

    if ($a -gt $b) { return @{ text = "단기 상승"; tone = "up" } }
    if ($a -lt $b) { return @{ text = "단기 하락"; tone = "down" } }
    return @{ text = "뚜렷한 추세 없음"; tone = $null }
}

function Get-MaLevels {
    # 이평선마다 지금 주가의 위치. 닿음(touch): 그날 저가가 이평선 위 touchPct% 안까지 내려왔고 종가가 이평선 아래
    # touchPct% 보다 높게 끝남. 근접(near): 종가가 이평선 위 nearPct% 안. 아래(below): 종가가 이평선 아래 touchPct% 밖.
    # fromAbove: 5거래일 전 종가가 이평선 위에 있었음(위에서 내려와 닿은 눌림목). buySignal: 닿음이면서(설정에 따라) 위에서 내려옴.
    param($series, $lows, $windows)
    $n = @($series).Count
    $i = $n - 1
    $t = [double]$buyRules.touchPct / 100
    @(foreach ($w in @($windows)) {
        if ($n -lt $w + 6) { continue }
        $ma = Get-MovingAverage -series $series -window $w
        if ($null -eq $ma[$i] -or $null -eq $ma[$i - 1]) { continue }
        $m = [double]$ma[$i]
        $close = [double]$series[$i]
        $gap = ($close / $m - 1) * 100
        $touchAt = {
            param([int]$k)
            if ($null -eq $ma[$k]) { return $false }
            ([double]$lows[$k] -le [double]$ma[$k] * (1 + $t)) -and ([double]$series[$k] -ge [double]$ma[$k] * (1 - $t))
        }
        $touch = & $touchAt $i
        $touchPrev = & $touchAt ($i - 1)
        $k5 = $i - 5
        $fromAbove = ($null -ne $ma[$k5]) -and ([double]$series[$k5] -gt [double]$ma[$k5] * (1 + $t))
        $slopeUp = ($null -ne $ma[$k5]) -and ($m -gt [double]$ma[$k5])
        $state = if ($touch) { "touch" } elseif ($close -lt $m * (1 - $t)) { "below" } elseif ($gap -le [double]$buyRules.nearPct) { "near" } else { "above" }
        $signal = $touch -and ($fromAbove -or -not $buyRules.fromAboveOnly)
        [PSCustomObject]@{
            window     = [int]$w
            value      = [math]::Round($m, 2)
            gapPct     = [math]::Round($gap, 2)
            state      = $state
            fromAbove  = [bool]$fromAbove
            slopeUp    = [bool]$slopeUp
            buySignal  = [bool]$signal
            firstTouch = [bool]($signal -and -not $touchPrev)
            # 장중 저가로만 닿고 종가는 이평선 위로 멀리(touchPct 밖) 끝난 경우
            intraday   = [bool]($touch -and $gap -gt [double]$buyRules.touchPct)
        }
    })
}

function Get-DipSignal {
    # 분할 매수 단계. "120일선에 닿으면 사고 200일선에 닿으면 더 산다. 고점 대비 -10%, -20%, -30%마다 더 줍는다"는
    # QLD 적립식 매수법을 종목마다 그대로 적용한다. 두 기준 중 높은 쪽이 그날의 단계다.
    #   1 매수 추천: 52주 고점보다 steps[0]% 이상 낮거나 maSteps[0]일선에 닿음
    #   2 추가 매수 추천: steps[1]% 이상 낮거나 maSteps[1]일선에 닿음
    #   3 매수 적극추천: steps[2]% 이상 낮음
    # '닿음'은 이평선 도달 매수 기준과 같은 touchPct 를 쓴다. 그날 저가가 선 위 touchPct% 안까지 내려왔거나 선 아래에 있으면
    # 닿은 것으로 본다. 고점은 페이지의 '52주 고점보다 N% 낮고' 문장과 같은 값(야후 52주 고가)이다.
    #
    # 드문 알림이 아니라 '오늘 얼마나 살 구간인가'를 말하는 표시라, 그 구간에 머무는 동안 계속 켜져 있다. 메일 제목에는 단계가
    # 오른 날만 싣는다. 2026-10-29 에 5년치로 돌려 보니 3단계가 켜진 날이 S&P 500 은 0%, 나스닥은 3% 였지만 샌디스크는 31%,
    # 이더리움은 54% 였다. 기준 숫자가 2배 레버리지 QLD 에서 나온 것이라 변동성이 큰 종목일수록 자주 켜진다. 그런 종목은
    # watchlist.json 에 "DipSteps": [20, 40, 60] 처럼 단계를 넓게 적는다.
    param($series, $lows, $high, $steps)
    $s = [double[]]@($series)
    $lw = [double[]]@($lows)
    $n = $s.Length
    if ($n -lt 2 -or $lw.Length -ne $n -or -not $high -or [double]$high -le 0) { return $null }
    $st = @(@($steps | ForEach-Object { [double]$_ }) | Sort-Object)
    $maW = @($buyRules.dip.maSteps | ForEach-Object { [int]$_ })
    $t = [double]$buyRules.touchPct / 100
    $hi = [double]$high
    $mas = @{}
    foreach ($w in $maW) { $mas[$w] = Get-MovingAverage -series $s -window $w }

    $evalAt = {
        param([int]$k)
        $dd = [math]::Max(0.0, (1 - $s[$k] / $hi) * 100)
        $ddTier = @($st | Where-Object { $dd -ge $_ }).Count
        $maTier = 0
        for ($m = 0; $m -lt $maW.Count; $m++) {
            $ma = $mas[$maW[$m]][$k]
            if ($null -ne $ma -and $lw[$k] -le [double]$ma * (1 + $t)) { $maTier = $m + 1 }
        }
        [PSCustomObject]@{ dd = $dd; ddTier = [int]$ddTier; maTier = [int]$maTier; level = [int][math]::Min(3, [math]::Max($ddTier, $maTier)) }
    }
    $today = & $evalAt ($n - 1)
    $prev = & $evalAt ($n - 2)
    $level = $today.level
    $i = $n - 1

    $maLines = @(for ($m = 0; $m -lt $maW.Count; $m++) {
        $ma = $mas[$maW[$m]][$i]
        if ($null -eq $ma) { continue }
        [PSCustomObject]@{ window = $maW[$m]; gapPct = [math]::Round(($s[$i] / [double]$ma - 1) * 100, 1); reached = [bool]($lw[$i] -le [double]$ma * (1 + $t)) }
    })
    $ddVal = [math]::Round([double]$today.dd, 1)
    $ddTxt = if ($ddVal -lt 0.05) { "52주 고점" } else { "52주 고점 대비 −$($ddVal.ToString('0.0'))%" }
    if ($today.ddTier -ge 1) { $ddTxt += "($($today.ddTier)단계 기준 −$($st[$today.ddTier - 1].ToString('0.#'))%)" }
    $detail = (@($ddTxt) + @($maLines | ForEach-Object {
        # 종가는 선 위 touchPct 밖에서 끝나고 장중 저가만 닿았으면, 이평선 도달 매수 기준처럼 '장중 도달'로 구분한다.
        $mark = if (-not $_.reached) { "" } elseif ([double]$_.gapPct -gt [double]$buyRules.touchPct) { "(장중 도달)" } else { "(도달)" }
        "$($_.window)일선 $(if ($_.gapPct -gt 0) { '+' } elseif ($_.gapPct -lt 0) { '−' })$(([math]::Abs([double]$_.gapPct)).ToString('0.0'))%$mark"
    })) -join ", "

    # 오늘 단계를 만든 기준. 고점 대비 하락과 이평선이 같은 단계를 함께 만들면 둘 다 적는다.
    $byDrawdown = [bool]($level -ge 1 -and $today.ddTier -ge $level)
    $byMa = if ($level -ge 1 -and $level -le $maW.Count -and $today.maTier -ge $level) { $maW[$level - 1] } else { 0 }
    $why = @()
    if ($byDrawdown) { $why += "고점 대비 −$($ddVal.ToString('0.0'))%" }
    if ($byMa) { $why += "${byMa}일선 도달" }

    [PSCustomObject]@{
        level      = $level
        label      = $(switch ($level) { 3 { "매수 적극추천" } 2 { "추가 매수 추천" } 1 { "매수 추천" } default { $null } })
        # 단계가 오늘 오른 날. 지금 주목할 점에 한 줄씩 올리고, 2단계 이상이면 메일 제목에도 싣는다.
        firstDay   = [bool]($level -ge 1 -and $prev.level -lt $level)
        dd         = $ddVal
        byDrawdown = $byDrawdown
        byMa       = [int]$byMa
        why        = ($why -join ", ")
        detail     = $detail
        steps      = $st
        # 페이지 범례가 기본 기준을 적을 때 쓴다(buy-rules.json 을 바꾸면 범례도 따라 바뀌게).
        defSteps   = @($buyRules.dip.drawdownSteps | ForEach-Object { [double]$_ })
        maSteps    = $maW
    }
}

function Get-StockPageUrl {
    # Where the email's price link should go — a real per-ticker page to read more, the same
    # way news links already go to their source article.
    param($cfg)
    if ($cfg.PageUrl) { return [string]$cfg.PageUrl }
    if ($cfg.IsIndex) {
        switch ($cfg.Symbol) {
            "^IXIC" { return "https://www.google.com/finance/quote/.IXIC:INDEXNASDAQ" }
            "^GSPC" { return "https://www.google.com/finance/quote/.INX:INDEXSP" }
            "^KS11" { return "https://finance.naver.com/sise/sise_index.naver?code=KOSPI" }
            default { return $null }
        }
    }
    if ($cfg.IsCrypto) {
        return "https://www.google.com/finance/quote/$($cfg.Symbol)"
    }
    if ($cfg.FinanceMode -eq "domestic" -and $cfg.FinanceCode) {
        return "https://finance.naver.com/item/main.naver?code=$($cfg.FinanceCode)"
    }
    if ($cfg.FinanceMode -eq "overseas" -and $cfg.FinanceCode) {
        $exchange = if ($cfg.FinanceCode.EndsWith(".N")) { "NYSE" } else { "NASDAQ" }
        $sym = $cfg.FinanceCode -replace '\.[ON]$', ''
        return "https://www.google.com/finance/quote/${sym}:${exchange}"
    }
    return $null
}

Write-Host "Fetching USD/KRW exchange rate..."
$usdKrw = $null
$usdKrwSeries = $null
try {
    # 1y range doubles as history for the FX trend chart, not just the topbar's latest value.
    $fxResp = Invoke-RestMethod -Uri "https://query1.finance.yahoo.com/v8/finance/chart/KRW=X?interval=1d&range=1y" -Headers $headers
    $fxResult = $fxResp.chart.result[0]
    $usdKrw = [math]::Round([double]$fxResult.meta.regularMarketPrice, 2)

    $fxCloses = $fxResult.indicators.quote[0].close
    $fxTimestamps = $fxResult.timestamp
    # Exchange-local date, same as the stock bars in Get-StockSnapshot. .ToLocalTime() made the
    # date depend on the machine: FX bars stamp around midnight London, which is the previous
    # day in UTC (the runner) and the same day in KST (a local run).
    $fxOffset = [TimeSpan]::FromSeconds([int]$fxResult.meta.gmtoffset)
    $fxPairs = for ($i = 0; $i -lt $fxCloses.Count; $i++) {
        if ($null -ne $fxCloses[$i]) {
            [PSCustomObject]@{
                Date  = [DateTimeOffset]::FromUnixTimeSeconds($fxTimestamps[$i]).ToOffset($fxOffset).ToString("yyyy-MM-dd")
                Close = [math]::Round([double]$fxCloses[$i], 2)
            }
        }
    }
    $usdKrwSeries = [PSCustomObject]@{
        series = @($fxPairs.Close)
        dates  = @($fxPairs.Date)
    }
} catch {
    Write-Warning "Exchange rate fetch failed: $($_.Exception.Message)"
}

function Get-FearGreedBand {
    # CNN's own published band boundaries for the 0-100 score.
    param([double]$score)
    if ($score -lt 25) { return @{ en = "extreme fear";  ko = "극단적 공포" } }
    if ($score -lt 45) { return @{ en = "fear";          ko = "공포" } }
    if ($score -lt 56) { return @{ en = "neutral";       ko = "중립" } }
    if ($score -lt 76) { return @{ en = "greed";         ko = "탐욕" } }
    return @{ en = "extreme greed"; ko = "극단적 탐욕" }
}

function Get-FearGreedAction {
    # "공포에 사고 탐욕에 팔라"는 역발상 원칙을 밴드에 그대로 얹은 것. template.html 의 FG_BANDS
    # 와 같은 문구를 써야 페이지와 메일이 서로 다른 말을 하지 않는다 — 한쪽을 고치면 다른 쪽도
    # 같이 고칠 것.
    #
    # 이건 매매 신호가 아니라 "원칙상 지금이 어느 구간인가"를 말해주는 참고 문구다. 극단적 공포는
    # 바닥 직전에도 나오지만 하락이 더 이어지는 구간에도 나오고, 공포가 깊어질수록 매수를 키우는
    # 건 하락장에서는 물타기와 같은 동작이 된다. 그래서 문구 옆에 항상 근거(지수와 전일 대비
    # 방향)를 같이 붙여서, 숫자를 보지 않고 문구만 따라가지 않도록 한다.
    param([string]$rating)
    switch ($rating) {
        "extreme fear"  { return @{ text = "적극 매수"; tone = "buy-strong" } }
        "fear"          { return @{ text = "매수 고려"; tone = "buy" } }
        "neutral"       { return @{ text = "관망";      tone = "hold" } }
        "greed"         { return @{ text = "매도 고려"; tone = "sell" } }
        "extreme greed" { return @{ text = "적극 매도"; tone = "sell-strong" } }
        default         { return $null }
    }
}

Write-Host "Fetching CNN Fear & Greed Index..."
$fearGreed = $null
try {
    # Unofficial endpoint behind CNN's own fear-and-greed page, fronted by Akamai bot detection —
    # needs a full browser-like header set (bare User-Agent + Referer isn't always enough), and
    # even then occasionally 418s, so retry once after a short pause before giving up.
    $fgHeaders = @{
        "User-Agent"      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        "Referer"         = "https://edition.cnn.com/markets/fear-and-greed"
        "Accept"          = "application/json, text/plain, */*"
        "Accept-Language" = "en-US,en;q=0.9"
    }
    $fgResp = $null
    for ($attempt = 1; $attempt -le 2 -and -not $fgResp; $attempt++) {
        try {
            $fgResp = Invoke-RestMethod -Uri "https://production.dataviz.cnn.io/index/fearandgreed/graphdata" -Headers $fgHeaders
        } catch {
            if ($attempt -eq 2) { throw }
            Start-Sleep -Seconds 2
        }
    }
    $fg = $fgResp.fear_and_greed
    $ratingKo = switch ($fg.rating) {
        "extreme fear"  { "극단적 공포" }
        "fear"          { "공포" }
        "neutral"       { "중립" }
        "greed"         { "탐욕" }
        "extreme greed" { "극단적 탐욕" }
        default         { $fg.rating }
    }

    function New-FgPoint($label, $score) {
        $band = Get-FearGreedBand -score $score
        [PSCustomObject]@{
            label  = $label
            score  = [math]::Round([double]$score, 0)
            rating = $band.en
            ratingKo = $band.ko
        }
    }

    $fearGreed = [PSCustomObject]@{
        score    = [math]::Round([double]$fg.score, 0)
        rating   = $fg.rating
        ratingKo = $ratingKo
        history  = @(
            New-FgPoint "전일"    $fg.previous_close
            New-FgPoint "1주 전"  $fg.previous_1_week
            New-FgPoint "1개월 전" $fg.previous_1_month
            New-FgPoint "1년 전"  $fg.previous_1_year
        )
    }
} catch {
    Write-Warning "Fear & Greed index fetch failed: $($_.Exception.Message)"
}

Write-Host "Fetching live quotes and headlines..."
# 차트와 뉴스는 주소를 미리 알 수 있으니 먼저 동시에 받아 둔다. 뉴스 검색어를 Yahoo 응답의 회사명
# 으로 정하는 종목(NewsQuery 도 DisplayName 도 없는 경우)만 루프 안에서 따로 받는다.
Invoke-Prefetch -urls @(
    foreach ($t in $tickers) { Get-ChartUri $t.Symbol }
    foreach ($t in $tickers) {
        $q = if ($t.NewsQuery) { $t.NewsQuery } else { $t.DisplayName }
        if ($q) { Get-NewsUri -query $q -lang $t.NewsLang }
    }
)
$stocks = foreach ($t in $tickers) {
    Write-Host "  - $($t.Symbol)"
    $script:chartFromPrefetch = $false
    try {
        Get-StockSnapshot $t
    } catch {
        # One flaky ticker (Yahoo's unofficial endpoint is occasionally unreliable) must not take
        # down the whole run — skip it and keep going, so the rest of the dashboard/email still ships.
        Write-Warning "Skipping $($t.Symbol) - snapshot fetch failed: $($_.Exception.Message)"
    }
    # be gentle with Yahoo's unofficial endpoint across the tickers. 차트를 미리 받아 둔 종목은
    # 이 루프에서 Yahoo 를 타지 않으므로, 남은 네이버·Nasdaq 요청 사이만 짧게 띄운다.
    if ($script:chartFromPrefetch) { Start-Sleep -Milliseconds 150 } else { Start-Sleep -Milliseconds 400 }
}

Save-EarningsCache -symbols @($tickers | Where-Object { $_.FinanceMode -eq "overseas" } | ForEach-Object { $_.Symbol })

# Skipping a flaky ticker is fine; ending up with *nothing* is not. Without this the run would
# cheerfully publish an empty dashboard and mail out an empty table, all with a green checkmark.
$stocks = @($stocks)

function Resolve-NewsTranslations {
    # 전 종목의 영문 제목을 한자리에 모아 캐시를 먼저 적용하고, 남은 것만 네트워크로 보낸다.
    # 종목별로 부르던 때는 실행당 20요청이었고 전부 429 였다. 이제 캐시 적중분은 0요청이고,
    # 새 제목은 10건씩 묶여 보통 1~2요청이면 끝난다.
    param($stocks)

    $today = (Get-Date).ToString("yyyy-MM-dd")
    $cache = Import-TranslationCache
    $items = @(foreach ($s in $stocks) { foreach ($n in @($s.news)) { if ($n.needsKo) { $n } } })
    if ($items.Count -eq 0) { return }

    $titles = @($items | ForEach-Object { $_.title } | Select-Object -Unique)
    $missing = @($titles | Where-Object { -not $cache.ContainsKey($_) })
    $fetched = 0
    if ($missing.Count -gt 0) { $fetched = Invoke-TranslationBatch -texts $missing -cache $cache -today $today }

    $applied = 0
    foreach ($n in $items) {
        $hit = $cache[$n.title]
        if ($hit -and $hit.ko -and $hit.ko -ne $n.title) {
            $hit.seen = $today          # 계속 쓰이는 제목은 정리 대상에서 살아남는다
            $n.titleOriginal = $n.title
            $n.title = $hit.ko
            # 번역본과 원문 둘 다에서 키워드를 찾도록 합쳐서 판별 (번역이 키워드를 흐리는 경우 대비)
            $n.sentiment = Get-NewsSentiment "$($n.title) $($n.titleOriginal)"
            $applied++
        }
    }

    # 작업용 표시라 페이지 JSON 까지 따라갈 이유가 없다.
    foreach ($n in $items) { $n.PSObject.Properties.Remove("needsKo") }

    $kept = Export-TranslationCache -cache $cache -today $today
    $pct = if ($titles.Count) { [math]::Round($applied * 100 / $items.Count) } else { 100 }
    # $applied건 처럼 쓰면 안 된다 — PowerShell 은 한글도 변수명 글자로 받아서 $applied건 이라는
    # 없는 변수를 읽고 빈 칸을 찍는다. 실제로 그렇게 찍혀서 잡았다.
    Write-Host "번역: 영문 $($items.Count)건 중 $($applied)건 한글화 ($pct%) · 신규 조회 $($fetched)건 · 캐시 $($kept)건"

    # 조용히 나빠지지 않게 한다. 지난주 이 실패는 아무 신호 없이 한 주를 갔고, 그동안 메일과
    # 페이지에는 영문 제목이 그대로 나갔다.
    if ($env:CI -and $items.Count -ge 5 -and $pct -lt 50) {
        Write-Host "::warning::영문 제목 $($items.Count)건 중 $($applied)건만 번역됨($pct%) - 번역 엔드포인트가 러너 IP를 막고 있을 수 있습니다."
    }
}

Resolve-NewsTranslations -stocks $stocks

# 시세가 뒤처진 채로 조용히 메일이 나가지 않게 한다. 오늘 아침이 정확히 그랬다 — 지수는 09-09,
# 개별종목은 09-08 인데 아무 신호 없이 발송됐고, 받는 쪽에서 전날 주가라는 걸 알 방법이 없었다.
#
# 실행을 실패시키지는 않는다. 시세가 하루 뒤처진 대시보드도 뉴스와 나머지 종목은 쓸모가 있고,
# 여기서 던지면 그날은 아무것도 못 받는다. 대신 러너 로그에 경고를 남겨 눈에 띄게 한다.
# 한국장과 미국장은 마지막 거래일이 원래 다르므로, 같은 거래소끼리만 비교해야 의미가 있다.
foreach ($grp in ($stocks | Where-Object { $_.exchangeTz } | Group-Object exchangeTz)) {
    $ds = @($grp.Group | ForEach-Object { @($_.dates)[-1] } | Where-Object { $_ })
    if ($ds.Count -lt 2) { continue }
    $newest = ($ds | Sort-Object -Descending)[0]
    $lagging = @($grp.Group | Where-Object { @($_.dates)[-1] -and @($_.dates)[-1] -lt $newest })
    if ($lagging.Count -gt 0) {
        $names = ($lagging | ForEach-Object { "$($_.name)($(@($_.dates)[-1]))" }) -join ", "
        $msg = "$($grp.Name) 최신 거래일은 $newest 인데 뒤처진 종목: $names"
        Write-Warning $msg
        if ($env:CI) { Write-Host "::warning::$msg" }
    }
}

if ($stocks.Count -eq 0) {
    if ($env:CI) { Write-Host "::error::All $($tickers.Count) tickers failed to fetch - refusing to publish an empty dashboard." }
    throw "All $($tickers.Count) tickers failed to fetch (Yahoo rate limit or outage?) - aborting so the previous good dashboard/email stays in place."
}
if ($stocks.Count -lt $tickers.Count) {
    $missing = $tickers.Count - $stocks.Count
    if ($env:CI) { Write-Host "::warning::$missing of $($tickers.Count) tickers failed to fetch - dashboard published without them." }
}

# --- 맨 위 시장 띠 ---------------------------------------------------------------------------
# 토스증권·구글 금융처럼 지수·환율·코인을 페이지 맨 위에 한 줄로 먼저 보여 준다. 관심 종목에 이미 있는 것은 그 값을
# 쓰고, 없는 것(코스닥, 필라델피아 반도체, VIX)만 3개월치를 따로 받는다. 따로 받은 것은 카드를 만들지 않는다.
# dp 는 소수 자릿수, prefix·suffix 는 값 앞뒤에 붙는 단위다.
$stripDefs = @(
    @{ sym = "^KS11";   name = "KOSPI";             dp = 2 }
    @{ sym = "^KQ11";   name = "KOSDAQ";            dp = 2 }
    @{ sym = "^IXIC";   name = "나스닥";            dp = 2 }
    @{ sym = "^GSPC";   name = "S&P 500";           dp = 2 }
    @{ sym = "^SOX";    name = "필라델피아 반도체"; dp = 2 }
    @{ sym = "^VIX";    name = "VIX(변동성)";       dp = 2 }
    @{ sym = "KRW=X";   name = "원/달러 환율";      dp = 2; suffix = "원" }
    @{ sym = "BTC-KRW"; name = "비트코인";          dp = 0; prefix = "₩" }
)
function Get-StripSeries {
    param($sym)
    try {
        $r = (Invoke-RestMethod -Uri "https://query1.finance.yahoo.com/v8/finance/chart/$([uri]::EscapeDataString($sym))?interval=1d&range=3mo" -Headers $headers).chart.result[0]
        $off = [TimeSpan]::FromSeconds([int]$r.meta.gmtoffset)
        $cl = $r.indicators.quote[0].close
        $ts = $r.timestamp
        $pairs = @(for ($i = 0; $i -lt $cl.Count; $i++) {
            if ($null -ne $cl[$i]) {
                [PSCustomObject]@{ Date = [DateTimeOffset]::FromUnixTimeSeconds($ts[$i]).ToOffset($off).ToString("yyyy-MM-dd"); Close = [math]::Round([double]$cl[$i], 2) }
            }
        })
        # 일봉이 아직 오늘 봉을 못 받았으면 meta 값을 한 점 덧붙인다(Get-StockSnapshot 과 같은 이유).
        if ($r.meta.regularMarketPrice -and $r.meta.regularMarketTime) {
            $md = [DateTimeOffset]::FromUnixTimeSeconds($r.meta.regularMarketTime).ToOffset($off).ToString("yyyy-MM-dd")
            if ($pairs.Count -eq 0 -or $md -gt $pairs[-1].Date) { $pairs += [PSCustomObject]@{ Date = $md; Close = [math]::Round([double]$r.meta.regularMarketPrice, 2) } }
        }
        [PSCustomObject]@{ dates = @($pairs.Date); series = @($pairs.Close) }
    } catch {
        Write-Warning "시장 띠 '$sym' 을 받지 못했습니다: $($_.Exception.Message)"
        $null
    }
}
$marketStrip = @(foreach ($d in $stripDefs) {
    $inWatch = @($stocks | Where-Object { $_.symbol -eq $d.sym })[0]
    $src = if ($inWatch) { [PSCustomObject]@{ dates = $inWatch.dates; series = $inWatch.series } }
        elseif ($d.sym -eq "KRW=X") { $usdKrwSeries }
        else { Get-StripSeries $d.sym }
    if (-not $src -or @($src.series).Count -lt 2) { continue }
    $sr = @($src.series | ForEach-Object { [double]$_ })
    $ds = @($src.dates)
    $n = $sr.Count
    # 작은 그래프는 최근 1개월. 코인은 주말에도 거래하므로 개수가 아니라 날짜로 자른다.
    $cut = [datetime]::ParseExact([string]$ds[-1], "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture).AddMonths(-1).ToString("yyyy-MM-dd")
    $k = $n - 1
    while ($k -gt 0 -and [string]$ds[$k - 1] -ge $cut) { $k-- }
    $k = [math]::Max(0, $k - 1)
    [PSCustomObject]@{
        symbol = $d.sym
        name   = $d.name
        dp     = [int]$d.dp
        prefix = [string]$d.prefix
        suffix = [string]$d.suffix
        last   = $sr[$n - 1]
        chg    = [math]::Round($sr[$n - 1] - $sr[$n - 2], 2)
        d1     = [math]::Round(($sr[$n - 1] / $sr[$n - 2] - 1) * 100, 2)
        date   = [string]$ds[-1]
        spark  = @($sr[$k..($n - 1)])
        card   = [bool]$inWatch
    }
})
Write-Host "시장 띠 $($marketStrip.Count)/$($stripDefs.Count)개"

# ConvertTo-Json on $null returns $null (not the string "null"), and String.Replace() coerces a
# $null replacement to "" — which would emit `const fearGreed = ;` into the page, a hard
# SyntaxError that stops the whole script block and renders a completely blank dashboard.
# Any optional value that can legitimately be missing must go through this.
#
# The JSON lands inside a <script> block, where the HTML parser ends the block at the first
# "</script>" no matter that it sits in a JS string. Windows PowerShell escapes < on its own; pwsh
# on the runner does not, so one headline carrying that text would blank the page. "<\/" is the
# same string to JSON and never closes a tag.
function ConvertTo-JsonOrNull {
    param($InputObject, $Depth = 4)
    if ($null -eq $InputObject) { return "null" }
    $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth
    if ($null -eq $json -or $json -eq "") { return "null" }
    return $json.Replace("</", "<\/")
}

# --- 기간별 등락·시장 대비·지금 주목할 점·다가오는 일정 ------------------------------------------
# work-dashboard 요약판과 같은 방식: 오늘·1주·1개월·연초 대비·1년 변화를 내고, 평소 변동폭(같은 기간 수익률의
# 표준편차)보다 크게 움직인 칸을 색칠할 수 있게 기준폭도 함께 넘긴다.
function Get-PerfStats {
    param($dates, $series)
    $n = @($series).Count
    if ($n -lt 3) { return $null }
    $ci = [Globalization.CultureInfo]::InvariantCulture
    $ds = @($dates | ForEach-Object { [DateTime]::ParseExact([string]$_, "yyyy-MM-dd", $ci) })
    $vals = @($series | ForEach-Object { [double]$_ })
    $li = $n - 1
    $pctFrom = {
        param([int]$j)
        if ($j -lt 0 -or $vals[$j] -eq 0) { return $null }
        [math]::Round(($vals[$li] / $vals[$j] - 1) * 100, 2)
    }
    $idxBefore = {
        param([DateTime]$cut)
        $k = $li
        while ($k -ge 0 -and $ds[$k] -gt $cut) { $k-- }
        $k
    }
    $stdOf = {
        param([double]$h)
        $rs = New-Object System.Collections.Generic.List[double]
        $j = 0
        for ($i = 1; $i -le $li; $i++) {
            $cut = $ds[$i].AddDays(-$h)
            while ($j + 1 -lt $i -and $ds[$j + 1] -le $cut) { $j++ }
            if ($ds[$j] -le $cut -and $vals[$j] -ne 0) { $rs.Add(($vals[$i] / $vals[$j] - 1) * 100) }
        }
        if ($rs.Count -lt 20) { return $null }
        $mean = ($rs | Measure-Object -Average).Average
        [math]::Round([math]::Sqrt((($rs | ForEach-Object { ($_ - $mean) * ($_ - $mean) }) | Measure-Object -Sum).Sum / ($rs.Count - 1)), 2)
    }
    $sdD = & $stdOf 1
    $sdW = & $stdOf 7
    $sdM = & $stdOf 30
    $daysYtd = [math]::Max(1, ($ds[$li] - [DateTime]::new($ds[$li].Year, 1, 1)).TotalDays)
    [PSCustomObject]@{
        d1  = & $pctFrom ($li - 1)
        w1  = & $pctFrom (& $idxBefore $ds[$li].AddDays(-7))
        m1  = & $pctFrom (& $idxBefore $ds[$li].AddDays(-30))
        ytd = & $pctFrom (& $idxBefore ([DateTime]::new($ds[$li].Year - 1, 12, 31)))
        y1  = & $pctFrom (& $idxBefore $ds[$li].AddDays(-365))
        thr = [PSCustomObject]@{
            d1  = $sdD; w1 = $sdW; m1 = $sdM
            ytd = $(if ($sdM) { [math]::Round($sdM * [math]::Sqrt($daysYtd / 30), 2) } else { $null })
            y1  = $(if ($sdM) { [math]::Round($sdM * [math]::Sqrt(365 / 30), 2) } else { $null })
        }
    }
}
foreach ($st in $stocks) {
    $st | Add-Member -NotePropertyName perf -NotePropertyValue (Get-PerfStats $st.dates $st.series) -Force
}
# 시장 대비: 국내 종목은 코스피, 미국 종목은 나스닥과 최근 1개월 수익률 차이(%p).
$benchOf = @{ kr = @{ sym = "^KS11"; name = "코스피" }; us = @{ sym = "^IXIC"; name = "나스닥" } }
foreach ($st in $stocks) {
    $rel = $null; $relBase = ""
    $b = $benchOf[[string]$st.kind]
    if ($b -and $st.perf -and $null -ne $st.perf.m1) {
        $bs = @($stocks | Where-Object { $_.symbol -eq $b.sym })[0]
        if ($bs -and $bs.perf -and $null -ne $bs.perf.m1) { $rel = [math]::Round($st.perf.m1 - $bs.perf.m1, 1); $relBase = $b.name }
    }
    $st | Add-Member -NotePropertyName relM1 -NotePropertyValue $rel -Force
    $st | Add-Member -NotePropertyName relBase -NotePropertyValue $relBase -Force
}

# 목표주가 변화. 토스증권의 '한 줄 요약'처럼 증권사 목표주가 평균이 바뀐 날을 알린다. 네이버는 그날 평균만 주므로
# 날마다 target-cache.json 에 적어 두고(봇이 커밋) 전 기록과 비교한다. 같은 날 여러 번 돌면 그날 값만 고쳐 쓴다.
# 1% 이상 바뀐 가장 최근 날을 targetChange 로 남기고, 그날이 오늘이면 지금 주목할 점에 올린다. 기록은 400일치만 둔다.
$targetCachePath = Join-Path $root "target-cache.json"
$targetCacheOriginal = if (Test-Path $targetCachePath) { [System.IO.File]::ReadAllText($targetCachePath) } else { "" }
$targetCache = @{}
if ($targetCacheOriginal) {
    try {
        ($targetCacheOriginal | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $targetCache[$_.Name] = @($_.Value) }
    } catch { Write-Warning "target-cache.json 을 읽지 못해 새로 기록합니다: $($_.Exception.Message)" }
}
foreach ($st in $stocks) {
    $tp = if ($st.consensus -and $st.consensus.targetPrice) { [double]$st.consensus.targetPrice } else { 0 }
    if ($tp -le 0) { continue }
    $hist = @(@($targetCache[$st.symbol]) | Where-Object { $_ -and $_.d -and [string]$_.d -ne $todayKstStr })
    $hist += [PSCustomObject]@{ d = $todayKstStr; v = $tp }
    $hist = @($hist | Select-Object -Last 400)
    $targetCache[$st.symbol] = $hist
    $chg = $null
    for ($j = $hist.Count - 1; $j -ge 1; $j--) {
        $from = [double]$hist[$j - 1].v
        if ($from -le 0) { continue }
        $pctT = ([double]$hist[$j].v / $from - 1) * 100
        if ([math]::Abs($pctT) -ge 1) {
            $older = @($hist[0..($j - 1)] | ForEach-Object { [double]$_.v })
            $chg = [PSCustomObject]@{
                date = [string]$hist[$j].d
                from = $from
                to   = [double]$hist[$j].v
                pct  = [math]::Round($pctT, 1)
                # 기록이 60일 넘게 쌓인 뒤에만 '가장 높은 값'을 말한다. 기록 첫 주에는 무엇이든 최고가 된다.
                recordDays = $hist.Count
                isHigh = [bool]($pctT -gt 0 -and $hist.Count -ge 60 -and [double]$hist[$j].v -gt ($older | Measure-Object -Maximum).Maximum)
            }
            break
        }
    }
    # 카드에는 2주 안에 바뀐 것만 적는다.
    if ($chg -and $chg.date -lt $nowKst.Date.AddDays(-14).ToString("yyyy-MM-dd")) { $chg = $null }
    $st | Add-Member -NotePropertyName targetChange -NotePropertyValue $chg -Force
}
# 관심종목에서 빠진 종목은 버리고, 내용이 같으면 쓰지 않는다. 종목마다 한 줄로 적어 파일이 길어지지 않게 한다.
$tcLines = @(foreach ($k in ($targetCache.Keys | Sort-Object)) {
    if (@($tickers | ForEach-Object { $_.Symbol }) -notcontains $k) { continue }
    $arr = @($targetCache[$k] | ForEach-Object { [PSCustomObject]@{ d = [string]$_.d; v = [double]$_.v } })
    "  $(ConvertTo-Json -InputObject ([string]$k) -Compress): $(ConvertTo-Json -InputObject $arr -Compress)"
})
$tcJson = "{`n" + ($tcLines -join ",`n") + "`n}`n"
if ($tcLines.Count -and $tcJson -ne $targetCacheOriginal) {
    [System.IO.File]::WriteAllText($targetCachePath, $tcJson, (New-Object System.Text.UTF8Encoding $false))
}

# 받침 유무로 조사를 고른다. 영문·숫자로 끝나면 읽는 소리로 판단한다.
function Get-Josa {
    param([string]$word, [string]$withFinal, [string]$withoutFinal)
    $w = ($word -replace '[\s\)\]]+$', '')
    if (-not $w) { return $withoutFinal }
    $ch = $w[$w.Length - 1]
    $code = [int]$ch
    if ($code -ge 0xAC00 -and $code -le 0xD7A3) {
        if ((($code - 0xAC00) % 28) -ne 0) { return $withFinal } else { return $withoutFinal }
    }
    if ("LMNRlmnr0136783".Contains([string]$ch)) { return $withFinal }
    $withoutFinal
}
function Format-Price {
    param($v, $ccy)
    if ($ccy -eq "₩") { "{0:N0}" -f [double]$v } else { "{0:N2}" -f [double]$v }
}
# 종목 한 줄 해설(카드 가격 아래, 메일 종목 칸). 증권 앱의 AI 종목 요약처럼 '지금 어떤 흐름이고 다음 매수 기준선이
# 어디인지'를 문장으로 적는다. AI 를 부르지 않고 이 스크립트가 계산한 값으로 만든다. 문장: 추세, 매수 신호(있을 때),
# 아래로 가장 가까운 매수 기준선(이평선·분할 매수 기준 중 현재가 바로 아래 값).
function Get-StockComment {
    param($st)
    $out = @()
    $out += switch -Wildcard ([string]$st.maTrend.text) {
        "골든크로스*" { "20일선이 60일선을 넘어 상승으로 돌아섰습니다." }
        "데드크로스*" { "20일선이 60일선 아래로 내려가 하락으로 돌아섰습니다." }
        "정배열*"     { "이평선이 정배열이라 상승 추세입니다." }
        "역배열*"     { "이평선이 역배열이라 하락 추세입니다." }
        "단기 상승"   { "단기적으로 오르는 흐름입니다." }
        "단기 하락"   { "단기적으로 내리는 흐름입니다." }
        default       { "뚜렷한 추세는 없습니다." }
    }
    $series = @($st.series | ForEach-Object { [double]$_ })
    if ($series.Count -lt 2) { return ($out -join " ") }
    $last = $series[-1]
    $ccy = [string]$st.currency
    $dip = $st.dip
    $hit = @($st.maLevels | Where-Object { $_ -and $_.buySignal })
    if ($dip -and [int]$dip.level -ge 1) {
        if ($dip.byDrawdown) { $out += "52주 고점보다 $(([double]$dip.dd).ToString('0.0'))% 낮아 $($dip.label) 구간입니다." }
        elseif ($dip.byMa) { $out += "$($dip.byMa)일선에 닿아 $($dip.label) 구간입니다." }
    } elseif ($hit.Count) {
        $out += "$($hit[0].window)일선에 닿아 이평선 도달 매수 기준에 해당합니다."
    }
    # 아래로 가장 가까운 매수 기준선. 이평선(20·60·180, 분할 매수의 120·200)과 분할 매수 하락 기준을 모아 현재가 바로 아래 값을 고른다.
    $cands = New-Object System.Collections.ArrayList
    foreach ($l in @($st.maLevels | Where-Object { $_ })) { [void]$cands.Add([PSCustomObject]@{ name = "$($l.window)일선"; v = [double]$l.value; note = "" }) }
    if ($dip) {
        foreach ($w in @($dip.maSteps)) {
            if (@($cands | Where-Object { $_.name -eq "${w}일선" }).Count) { continue }
            $ma = Get-MovingAverage -series $series -window ([int]$w)
            if ($null -ne $ma[-1]) { [void]$cands.Add([PSCustomObject]@{ name = "${w}일선"; v = [double]$ma[-1]; note = "" }) }
        }
        if ($st.rangeHigh) {
            $k = 0
            foreach ($stp in @($dip.steps | Select-Object -First 3)) {
                $k++
                [void]$cands.Add([PSCustomObject]@{ name = "분할 매수 ${k}단계 기준"; v = [double]$st.rangeHigh * (1 - [double]$stp / 100); note = "고점 대비 −$(([double]$stp).ToString('0.#'))%, " })
            }
        }
    }
    # 이미 닿아 있는 선(현재가 1% 안)은 '다음' 기준선이 아니다.
    $below = @($cands | Where-Object { $_.v -lt $last * 0.99 } | Sort-Object v -Descending)
    if ($below.Count) {
        $b = $below[0]
        $gap = (1 - $b.v / $last) * 100
        # 값 뒤에 조사를 붙이지 않는다(숫자 끝자리에 따라 '로/으로'가 바뀐다).
        $out += "다음 매수 기준선은 현재가보다 $($gap.ToString('0.0'))% 아래인 $($b.name)($($b.note)$ccy$(Format-Price $b.v $ccy))입니다."
    } elseif ($cands.Count) {
        $out += "아래에 남은 매수 기준선은 없습니다."
    }
    $out -join " "
}
foreach ($st in $stocks) {
    $st | Add-Member -NotePropertyName comment -NotePropertyValue (Get-StockComment $st) -Force
}

# 지금 주목할 점(페이지 맨 위, 메일 맨 위). 실적 발표 임박, 52주 신고가·신저가, 이동평균 교차, 거래량 급증,
# 평소보다 큰 하루 등락, 알림가 돌파·이탈, 시장보다 크게 강하거나 약한 종목을 문장으로 모은다.
$pageHighlights = New-Object System.Collections.ArrayList
function Add-Highlight {
    # kind 는 메일이 고를 때 쓴다. 'dipGroup'(단계별로 묶은 줄)은 메일의 '오늘의 매수 단계' 상자와 겹쳐 메일에서는 뺀다.
    param([string]$tag, [string]$text, [double]$priority, [string]$symbol, [string]$kind = "")
    [void]$pageHighlights.Add([PSCustomObject]@{ tag = $tag; text = $text; priority = $priority; symbol = $symbol; kind = $kind })
}
foreach ($st in $stocks) {
    $nm = [string]$st.name
    $topic = "$nm$(Get-Josa $nm '은' '는')"
    $lastV = [double]$st.series[-1]
    $prevV = [double]$st.series[-2]
    if ($st.earnings -and $st.earnings.date) {
        $eDate = [datetime]::ParseExact($st.earnings.date, "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
        $dLeft = ($eDate - $nowKst.Date).Days
        if ($dLeft -ge 0 -and $dLeft -le 3) {
            $when = if ($dLeft -eq 0) { "오늘" } elseif ($dLeft -eq 1) { "내일" } else { "${dLeft}일 뒤" }
            $timing = if ($st.earnings.timing) { " $($st.earnings.timing)" } else { "" }
            Add-Highlight "실적" "$topic $when($($eDate.Month)/$($eDate.Day)$timing, 현지 기준) 실적을 발표합니다." (90 - $dLeft) $st.symbol
        }
    }
    if ($st.rangeHigh -and $lastV -ge [double]$st.rangeHigh * 0.999) {
        Add-Highlight "신고가" "$topic 52주 신고가를 기록했습니다." 95 $st.symbol
    } elseif ($st.rangeLow -and $lastV -le [double]$st.rangeLow * 1.001) {
        Add-Highlight "신저가" "$topic 52주 신저가를 기록했습니다." 95 $st.symbol
    } elseif ($st.rangeHigh -and $lastV -ge [double]$st.rangeHigh * 0.97) {
        $gapHi = ([double]$st.rangeHigh / $lastV - 1) * 100
        Add-Highlight "신고가" "$topic 52주 고점까지 $($gapHi.ToString('0.0'))% 남았습니다." 55 $st.symbol
    }
    if ($st.cross -eq "golden") { Add-Highlight "추세" "$($nm)에서 골든크로스가 나왔습니다(20일선이 60일선 위로)." 80 $st.symbol }
    elseif ($st.cross -eq "dead") { Add-Highlight "추세" "$($nm)에서 데드크로스가 나왔습니다(20일선이 60일선 아래로)." 80 $st.symbol }
    if ($st.volumeRatio -and [double]$st.volumeRatio -ge 2) {
        Add-Highlight "거래량" "$($nm) 거래량이 최근 20거래일 평균의 $(([double]$st.volumeRatio).ToString('0.0'))배입니다." 70 $st.symbol
    }
    if ($st.perf -and $null -ne $st.perf.d1) {
        $d1 = [double]$st.perf.d1
        $big = [math]::Max(5, $(if ($st.perf.thr.d1) { 2 * [double]$st.perf.thr.d1 } else { 5 }))
        if ([math]::Abs($d1) -ge $big) {
            $tagMv = if ($d1 -ge 0) { "급등" } else { "급락" }
            $verbMv = if ($d1 -ge 0) { "올랐습니다" } else { "내렸습니다" }
            Add-Highlight $tagMv "$topic 하루 사이 $([math]::Abs($d1).ToString('0.0'))% $verbMv." (85 + [math]::Abs($d1) / 10) $st.symbol
        }
    }
    if ($null -ne $st.alertBelow -and $lastV -le [double]$st.alertBelow -and $prevV -gt [double]$st.alertBelow) {
        Add-Highlight "알림가" "$topic 알림가 $($st.currency)$(Format-Price $st.alertBelow $st.currency) 아래로 내려갔습니다." 110 $st.symbol
    }
    if ($null -ne $st.alertAbove -and $lastV -ge [double]$st.alertAbove -and $prevV -lt [double]$st.alertAbove) {
        Add-Highlight "알림가" "$topic 알림가 $($st.currency)$(Format-Price $st.alertAbove $st.currency) 위로 올라갔습니다." 110 $st.symbol
    }
    # 이평선 도달 매수 기준
    $lv = @($st.maLevels | Where-Object { $_ })
    $hit = @($lv | Where-Object { $_.buySignal })
    if ($hit.Count) {
        $names = ($hit | ForEach-Object { "$($_.window)일선" }) -join "과 "
        $first = $hit[0]
        $priceTxt = "$($st.currency)$(Format-Price $first.value $st.currency)"
        $slopeTxt = if ($first.slopeUp) { "오르는 중인" } else { "내려가는 중인" }
        $hitTxt = if ($first.intraday) { "장중 $slopeTxt $names($priceTxt)까지 내려왔다가 $(([double]$first.gapPct).ToString('0.0'))% 위에서 마감했습니다" } else { "$slopeTxt $names($priceTxt)에 닿았습니다" }
        Add-Highlight "매수 기준" "$topic $hitTxt. 이평선 도달 매수 기준에 해당합니다." (105 + $(if ($first.firstTouch) { 3 } else { 0 })) $st.symbol
    } else {
        $near = @($lv | Where-Object { $_.state -eq "near" } | Sort-Object gapPct | Select-Object -First 1)
        if ($near.Count) {
            Add-Highlight "매수 대기" "$topic $($near[0].window)일선까지 $(([double]$near[0].gapPct).ToString('0.0'))% 남았습니다." (62 - [double]$near[0].gapPct) $st.symbol
        }
    }
    # 분할 매수 단계가 오늘 오른 종목은 한 줄씩 올린다. 이미 그 단계에 있던 종목은 아래 루프 뒤에서 단계별로 묶는다.
    $dip = $st.dip
    if ($dip -and $dip.level -ge 1 -and $dip.firstDay) {
        $ddPart = "52주 고점보다 $(([double]$dip.dd).ToString('0.0'))%"
        $how = if ($dip.byDrawdown -and $dip.byMa) { "$ddPart 내려오고 $($dip.byMa)일선에 닿아" }
            elseif ($dip.byMa) { "$($dip.byMa)일선에 닿아" } else { "$ddPart 내려와" }
        $prio = switch ([int]$dip.level) { 3 { 118 } 2 { 108 } default { 92 } }
        Add-Highlight $dip.label "$topic 오늘 $how $($dip.label) 구간에 들어왔습니다." $prio $st.symbol
    }
    $tc = $st.targetChange
    if ($tc -and $tc.date -eq $todayKstStr) {
        $tcWord = if ($tc.pct -gt 0) { "올랐습니다" } else { "내렸습니다" }
        $tcHigh = if ($tc.isHigh) { " 기록을 모은 $($tc.recordDays)일 중 가장 높습니다." } else { "" }
        Add-Highlight "목표주가" "$($nm) 증권사 목표주가 평균이 $([math]::Abs([double]$tc.pct).ToString('0.0'))% ${tcWord}($($st.currency)$(Format-Price $tc.from $st.currency)에서 $($st.currency)$(Format-Price $tc.to $st.currency)).$tcHigh" (72 + [math]::Min(10, [math]::Abs([double]$tc.pct))) $st.symbol
    }
    if ($null -ne $st.relM1 -and [math]::Abs([double]$st.relM1) -ge 15) {
        $relWord = if ($st.relM1 -ge 0) { "강했습니다" } else { "약했습니다" }
        Add-Highlight "시장 대비" "$topic 최근 1개월 $($st.relBase)보다 $([math]::Abs([double]$st.relM1).ToString('0.0'))%p $relWord." (40 + [math]::Abs([double]$st.relM1) / 10) $st.symbol
    }
}
# 이미 2단계 이상에 있던 종목은 단계별로 한 줄에 묶는다. 하락장에서는 여러 종목이 한꺼번에 같은 단계에 머물러서, 한 종목씩
# 올리면 지금 주목할 점이 이 표시로 가득 찬다. 1단계는 흔해서 오른 날에만 올린다.
foreach ($lvl in 3, 2) {
    $grp = @($stocks | Where-Object { $_.dip -and [int]$_.dip.level -eq $lvl -and -not $_.dip.firstDay } | Sort-Object { [double]$_.dip.dd } -Descending)
    if (-not $grp.Count) { continue }
    $grpLabel = $grp[0].dip.label
    $prioGrp = if ($lvl -eq 3) { 100 } else { 94 }
    if (-not @($grp | Where-Object { $_.dip.byMa }).Count) {
        # 모두 고점 대비 하락으로 이 단계가 된 경우: '52주 고점 대비 A −48.9%, B −41.2%로'처럼 기준을 한 번만 적는다.
        $items = @($grp | ForEach-Object { "$($_.name) −$(([double]$_.dip.dd).ToString('0.0'))%" })
        Add-Highlight $grpLabel "52주 고점 대비 $($items -join ', ')로 $grpLabel 구간입니다." $prioGrp $grp[0].symbol "dipGroup"
    } else {
        $items = @($grp | ForEach-Object { "$($_.name)($($_.dip.why))" })
        Add-Highlight $grpLabel "$($items -join ', ')$(Get-Josa $items[-1] '이' '가') $grpLabel 구간입니다." $prioGrp $grp[0].symbol "dipGroup"
    }
}
# 왜 움직였나. Perplexity·구글 금융의 시장 요약처럼 숫자 옆에 이유를 둔다. 종목마다 가장 위에 오는 한 줄에만
# 그 종목의 최근 3일 안 기사 제목을 하나 붙인다. 이미 받아 둔 뉴스(번역 끝난 제목)를 쓰므로 AI 를 부르지 않는다.
# 여러 종목을 묶은 줄(dipGroup)과 일정을 알리는 실적 줄에는 붙이지 않는다.
$newsCut = $nowKst.Date.AddDays(-3).ToString("yyyy-MM-dd")
$newsSeen = @{}
foreach ($h in @($pageHighlights | Sort-Object priority -Descending)) {
    if (-not $h.symbol -or $h.kind -eq "dipGroup" -or $h.tag -eq "실적" -or $newsSeen.ContainsKey($h.symbol)) { continue }
    $newsSeen[$h.symbol] = $true
    $stH = @($stocks | Where-Object { $_.symbol -eq $h.symbol })[0]
    if (-not $stH) { continue }
    $nw = @($stH.news | Where-Object { $_ -and $_.title -and [string]$_.date -ge $newsCut })[0]
    if ($nw) {
        $h | Add-Member -NotePropertyName news -NotePropertyValue ([PSCustomObject]@{ title = [string]$nw.title; link = [string]$nw.link; source = [string]$nw.source; date = [string]$nw.date }) -Force
    }
}
# 메일은 묶음 줄을 빼고 다시 고르므로 자르기 전 목록을 남겨 둔다.
$allHighlights = @($pageHighlights)
$pageHighlights = @($pageHighlights | Sort-Object priority -Descending | Select-Object -First 8)
if ($pageHighlights.Count -eq 0) {
    $pageHighlights = @([PSCustomObject]@{ tag = "전체"; text = "평소보다 크게 움직인 종목이나 가까운 실적 발표는 없습니다."; priority = 0; symbol = "" })
}

# 다가오는 일정(120일): market-calendar.json 의 시장 일정(FOMC, CPI, 금통위, 휴장일)에 미국 종목 실적 발표일을 더한다.
$scheduleItems = New-Object System.Collections.ArrayList
$calPath = Join-Path $root "market-calendar.json"
$horizonEnd = $nowKst.Date.AddDays(120)
if (Test-Path $calPath) {
    try {
        $cal = Get-Content -Path $calPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($ev in @($cal.events)) {
            if (-not $ev.date -or -not $ev.title) { continue }
            $evStart = [datetime]::ParseExact([string]$ev.date, "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
            $evEnd = if ($ev.end) { [datetime]::ParseExact([string]$ev.end, "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture) } else { $evStart }
            if ($evEnd -lt $nowKst.Date -or $evStart -gt $horizonEnd) { continue }
            [void]$scheduleItems.Add([PSCustomObject]@{ date = [string]$ev.date; end = $evEnd.ToString("yyyy-MM-dd"); kind = [string]$ev.kind
                market = [string]$ev.market; title = [string]$ev.title; note = [string]$ev.note })
        }
    } catch { Write-Warning "market-calendar.json 을 읽지 못했습니다: $($_.Exception.Message)" }
}
foreach ($st in $stocks) {
    if (-not $st.earnings -or -not $st.earnings.date) { continue }
    $eDate = [datetime]::ParseExact($st.earnings.date, "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
    if ($eDate -lt $nowKst.Date -or $eDate -gt $horizonEnd) { continue }
    $noteParts = @()
    if ($st.earnings.timing) { $noteParts += $st.earnings.timing }
    $noteParts += $(if ($st.earnings.confirmed) { "확정" } else { "추정(바뀔 수 있음)" })
    $noteParts += "현지 날짜"
    [void]$scheduleItems.Add([PSCustomObject]@{ date = [string]$st.earnings.date; end = [string]$st.earnings.date; kind = "실적"
        market = "미국"; title = "$($st.name) 실적 발표"; note = ($noteParts -join ", "); symbol = $st.symbol })
}
$scheduleItems = @($scheduleItems | Sort-Object date)

# 오늘의 브리핑(페이지 한눈 요약 맨 위, 메일 맨 위). 증권 앱의 AI 시장 요약처럼 오늘 상황을 항목별로 한두 문장씩 정리한다.
# AI 를 부르지 않고 이 스크립트가 계산한 값으로 문장을 만든다(같은 데이터면 늘 같은 문장이고 숫자가 틀릴 일이 없다).
# 항목: 시장(코스피·나스닥), 관심 종목(오른 수·내린 수, 가장 크게 움직인 종목), 매수 신호(분할 매수 단계, 이평선 도달),
# 심리·일정(공포·탐욕지수, 3일 안 일정). 한 문장에 한 내용.
$brief = New-Object System.Collections.ArrayList
function Add-Brief { param([string]$label, [string]$text) if ($text) { [void]$brief.Add([PSCustomObject]@{ label = $label; text = $text }) } }
$mvMid = { param([double]$p) if ([math]::Abs($p) -lt 0.05) { "보합이었고" } elseif ($p -gt 0) { "$([math]::Abs($p).ToString('0.0'))% 올랐고" } else { "$([math]::Abs($p).ToString('0.0'))% 내렸고" } }
$mvEnd = { param([double]$p) if ([math]::Abs($p) -lt 0.05) { "보합이었습니다." } elseif ($p -gt 0) { "$([math]::Abs($p).ToString('0.0'))% 올랐습니다." } else { "$([math]::Abs($p).ToString('0.0'))% 내렸습니다." } }
$stripBy = @{}
foreach ($x in @($marketStrip)) { $stripBy[[string]$x.symbol] = $x }
$mkParts = @()
if ($stripBy.ContainsKey("^KS11")) { $mkParts += , @("코스피는", [double]$stripBy["^KS11"].d1) }
if ($stripBy.ContainsKey("^IXIC")) { $mkParts += , @("나스닥은", [double]$stripBy["^IXIC"].d1) }
if ($mkParts.Count -eq 2) { Add-Brief "시장" "$($mkParts[0][0]) $(& $mvMid $mkParts[0][1]) $($mkParts[1][0]) $(& $mvEnd $mkParts[1][1])" }
elseif ($mkParts.Count -eq 1) { Add-Brief "시장" "$($mkParts[0][0]) $(& $mvEnd $mkParts[0][1])" }
if ($brief.Count -and $stripBy.ContainsKey("^VIX") -and [double]$stripBy["^VIX"].last -ge 25) {
    $brief[$brief.Count - 1].text += " 미국 증시 불안 지수(VIX)가 $(([double]$stripBy['^VIX'].last).ToString('0.0'))로 높습니다."
}
$members = @($stocks | Where-Object { $_.kind -ne "index" -and $_.perf -and $null -ne $_.perf.d1 })
if ($members.Count) {
    $nUp = @($members | Where-Object { [double]$_.perf.d1 -ge 0.05 }).Count
    $nDn = @($members | Where-Object { [double]$_.perf.d1 -le -0.05 }).Count
    $top = @($members | Sort-Object { [math]::Abs([double]$_.perf.d1) } -Descending)[0]
    $topD = [double]$top.perf.d1
    $txt = if ($nDn -eq $members.Count) { "관심 종목 $($members.Count)개가 모두 내렸습니다." }
        elseif ($nUp -eq $members.Count) { "관심 종목 $($members.Count)개가 모두 올랐습니다." }
        else { "관심 종목 $($members.Count)개 중 오른 종목은 ${nUp}개, 내린 종목은 ${nDn}개입니다." }
    if ([math]::Abs($topD) -ge 0.05) { $txt += " 가장 크게 움직인 종목은 $($top.name)$(Get-Josa ([string]$top.name) '으로' '로') 하루 사이 $(& $mvEnd $topD)" }
    Add-Brief "관심 종목" $txt
}
$sig = @()
$lv3 = @($stocks | Where-Object { $_.dip -and [int]$_.dip.level -eq 3 })
$lv2 = @($stocks | Where-Object { $_.dip -and [int]$_.dip.level -eq 2 })
$lv1 = @($stocks | Where-Object { $_.dip -and [int]$_.dip.level -eq 1 })
$cnt = @()
if ($lv3.Count) { $cnt += "매수 적극추천 $($lv3.Count)개" }
if ($lv2.Count) { $cnt += "추가 매수 추천 $($lv2.Count)개" }
if ($lv1.Count) { $cnt += "매수 추천 $($lv1.Count)개" }
if ($cnt.Count) { $sig += "분할 매수 단계에 든 종목은 $($cnt -join ', ')입니다." }
$newDip = @($stocks | Where-Object { $_.dip -and [int]$_.dip.level -ge 1 -and $_.dip.firstDay })
if ($newDip.Count) { $sig += "오늘 새로 단계에 든 종목은 $(($newDip | ForEach-Object { "$($_.name)($($_.dip.label))" }) -join ', ')입니다." }
$maHit = @($stocks | Where-Object { @($_.maLevels | Where-Object { $_ -and $_.buySignal }).Count })
if ($maHit.Count) {
    $sig += "이평선에 닿아 매수 기준에 해당하는 종목은 $(($maHit | ForEach-Object { $w = @($_.maLevels | Where-Object { $_ -and $_.buySignal })[0].window; "$($_.name)(${w}일선)" }) -join ', ')입니다."
}
if (-not $sig.Count) { $sig += "분할 매수 단계나 이평선 도달 매수 기준에 해당하는 종목은 없습니다." }
Add-Brief "매수 신호" ($sig -join " ")
$mood = @()
if ($fearGreed) { $mood += "공포·탐욕지수는 $($fearGreed.score)로 $($fearGreed.ratingKo) 구간입니다." }
$soonEnd = $nowKst.Date.AddDays(3).ToString("yyyy-MM-dd")
$soon = @($scheduleItems | Where-Object { [string]$_.date -le $soonEnd -and [string]$_.end -ge $nowKst.Date.ToString("yyyy-MM-dd") } | Select-Object -First 3)
if ($soon.Count) {
    $dowKo = "일월화수목금토"
    $soonTxt = @($soon | ForEach-Object {
        $d = [datetime]::ParseExact([string]$_.date, "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
        "$($d.Month)/$($d.Day)($($dowKo[[int]$d.DayOfWeek])) $($_.title)"
    })
    $mood += "3일 안 일정은 $($soonTxt -join ', ')입니다."
}
Add-Brief "심리·일정" ($mood -join " ")
$briefJson = ConvertTo-Json -InputObject @($brief) -Depth 3 -Compress
if (-not $briefJson -or $briefJson -eq "null") { $briefJson = "[]" }
$briefJson = $briefJson.Replace("</", "<\/")

$highlightsJson = ConvertTo-Json -InputObject @($pageHighlights) -Depth 3 -Compress
if (-not $highlightsJson -or $highlightsJson -eq "null") { $highlightsJson = "[]" }
$scheduleJson = ConvertTo-Json -InputObject @($scheduleItems) -Depth 3 -Compress
if (-not $scheduleJson -or $scheduleJson -eq "null") { $scheduleJson = "[]" }
$highlightsJson = $highlightsJson.Replace("</", "<\/")
$scheduleJson = $scheduleJson.Replace("</", "<\/")

$stocksJson = ConvertTo-JsonOrNull -InputObject @($stocks) -Depth 8
$usdKrwJson = ConvertTo-JsonOrNull -InputObject $usdKrw
$usdKrwSeriesJson = ConvertTo-JsonOrNull -InputObject $usdKrwSeries -Depth 4
$fearGreedJson = ConvertTo-JsonOrNull -InputObject $fearGreed
$stripJson = ConvertTo-JsonOrNull -InputObject @($marketStrip) -Depth 4
$fetchedAt = $nowKst.ToString("yyyy-MM-ddTHH:mm:ss") + "+09:00"  # $nowKst's DateTimeKind is still Utc after the manual +9h shift, so "zzz" would report +00:00 — append the known-fixed KST offset literally instead.

$template = Get-Content -Path (Join-Path $root "template.html") -Raw -Encoding UTF8
$output = $template.Replace("__STOCKS_JSON__", $stocksJson).Replace("__USDKRW_JSON__", $usdKrwJson).Replace("__USDKRW_SERIES_JSON__", $usdKrwSeriesJson).Replace("__FEARGREED_JSON__", $fearGreedJson).Replace("__FETCHED_AT__", $fetchedAt).Replace("__HIGHLIGHTS_JSON__", $highlightsJson).Replace("__SCHEDULE_JSON__", $scheduleJson).Replace("__STRIP_JSON__", $stripJson).Replace("__BRIEF_JSON__", $briefJson)

$outPath = Join-Path $root "dashboard.html"
Set-Content -Path $outPath -Value $output -Encoding UTF8

Write-Host "Dashboard updated: $outPath"
if (-not $env:CI) {
    Start-Process $outPath
}

# --- Email summary -----------------------------------------------------------------
# Generates email-summary.html + email-subject.txt every run (harmless, useful for local
# preview) — actually SENDING the email is a separate step, done only by the GitHub Actions
# workflow, so testing locally never spams the inbox.
Write-Host "Building email summary..."

$dayNames = @("일", "월", "화", "수", "목", "금", "토")
$emailDateStr = "{0}년 {1}월 {2}일 ({3})" -f $nowKst.Year, $nowKst.Month, $nowKst.Day, $dayNames[[int]$nowKst.DayOfWeek]

# Notable-condition scan for the subject line — 공포·탐욕지수 already covers the market-wide
# mood there, but a per-stock event (big move, fresh cross, 52-week extreme) can still get lost
# inside the body's per-row list. This pulls the loudest ones up to the subject, same spot the
# Fear & Greed suffix already lives, so the inbox list alone says whether today needs a look.
# Priority: 52-week extreme > fresh cross > plain move (biggest move first within that tier).
$MOVE_THRESHOLD_PCT = 7
$highlights = New-Object System.Collections.ArrayList

# 메일 표 칸. 칸마다 style 을 반복하면 표가 금세 커져서(Gmail 은 102KB 가 넘으면 메일을 자른다) work-dashboard 처럼
# 여백은 표의 cellpadding, 색은 bgcolor 와 font 속성으로 준다.
function Get-MailPctText {
    param($v)
    if ($null -eq $v) { return "–" }
    $d = [double]$v
    $digits = if ([math]::Abs($d) -ge 100) { "0" } else { "0.0" }
    "$(if ($d -gt 0) { '+' } elseif ($d -lt 0) { '−' })$([math]::Abs($d).ToString($digits))%"
}
function Get-MailPctCell {
    # 페이지 기간별 표와 같은 규칙: 그 종목의 평소 등락 폭(같은 기간 수익률의 표준편차)보다 크면 옅게, 2배 이상이면 진하게.
    param($v, $thr)
    if ($null -eq $v) { return "<td align=right nowrap><font color=#898781>–</font></td>" }
    $d = [double]$v
    $fc = if ($d -gt 0.005) { "#c62828" } elseif ($d -lt -0.005) { "#1f5fcc" } else { "#52514e" }
    $bg = ""
    if ($thr -and [double]$thr -gt 0) {
        $r = [math]::Abs($d) / [double]$thr
        if ($r -ge 2) { $bg = if ($d -gt 0) { " bgcolor=#f6caca" } else { " bgcolor=#cfdcf6" } }
        elseif ($r -ge 1) { $bg = if ($d -gt 0) { " bgcolor=#fbe6e6" } else { " bgcolor=#e7eefb" } }
    }
    "<td align=right nowrap$bg><font color=$fc>$(Get-MailPctText $d)</font></td>"
}
function Get-MailSignal {
    # 기간별 표의 종목 이름 아래 한 줄. 페이지 '이평선' 칸과 같은 순서로 하나만 고른다:
    # 분할 매수 2단계 이상, 이평선 도달(매수 기준), 분할 매수 1단계, 매수 대기.
    param($stk)
    $dp = $stk.dip
    if ($dp -and [int]$dp.level -ge 2) { return "<font color=#2a78d6><b>▼ $($dp.label)</b></font>" }
    $touched = @($stk.maLevels | Where-Object { $_ -and $_.buySignal })
    if ($touched.Count) { return "<font color=#2a78d6><b>◎ $(($touched | ForEach-Object { "$($_.window)일선" }) -join ', ') 도달</b></font>" }
    if ($dp -and [int]$dp.level -eq 1) { return "<font color=#2a78d6>$($dp.label)</font>" }
    $nearest = @($stk.maLevels | Where-Object { $_ -and $_.state -eq "near" } | Sort-Object gapPct | Select-Object -First 1)
    if ($nearest.Count) { return "<font color=#2a78d6>$($nearest[0].window)일선까지 $(([double]$nearest[0].gapPct).ToString('0.0'))%</font>" }
    return ""
}
# 메일도 페이지처럼 분야(watchlist.json 의 Group)별로 묶는다. 순서는 관심 종목 목록에 처음 나온 순서다.
function Get-GroupName { param($stk) if ($stk.group) { [string]$stk.group } else { "기타" } }
$groupOrder = @($stocks | ForEach-Object { Get-GroupName $_ } | Select-Object -Unique)
$inv = [Globalization.CultureInfo]::InvariantCulture

$rowsHtml = foreach ($s in $stocks) {
    $last = $s.series[-1]
    $prev = $s.series[-2]
    $diff = $last - $prev
    $pct = if ($prev -ne 0) { ($diff / $prev) * 100 } else { 0 }
    $up = $diff -ge 0
    $sign = if ($up) { "+" } else { "" }
    # 국내 증권 앱과 같은 색: 상승 빨강, 하락 파랑
    $color = if ($up) { "#c62828" } else { "#1f5fcc" }
    $arrow = if ($up) { "▲" } else { "▼" }
    $priceFmt = if ($s.currency -eq "₩") { "{0:N0}" -f $last } else { "{0:N2}" -f $last }

    if ([math]::Abs($pct) -ge $MOVE_THRESHOLD_PCT) {
        $dir = if ($up) { "급등" } else { "급락" }
        [void]$highlights.Add([PSCustomObject]@{ text = "$($s.name) $dir $sign$($pct.ToString('N1'))%"; priority = [math]::Abs($pct) })
    }
    $cross = $s.cross
    if ($cross -eq "golden") { [void]$highlights.Add([PSCustomObject]@{ text = "$($s.name) 골든크로스"; priority = 80 }) }
    elseif ($cross -eq "dead") { [void]$highlights.Add([PSCustomObject]@{ text = "$($s.name) 데드크로스"; priority = 80 }) }
    if ($last -ge ($s.rangeHigh * 0.999)) { [void]$highlights.Add([PSCustomObject]@{ text = "$($s.name) 52주 신고가"; priority = 100 }) }
    elseif ($last -le ($s.rangeLow * 1.001)) { [void]$highlights.Add([PSCustomObject]@{ text = "$($s.name) 52주 신저가"; priority = 100 }) }

    # Watchlist alert levels. The subject only carries the day the level is crossed - a price that
    # stays under its level would otherwise sit in every subject until it recovers, and a constant
    # warning is one nobody reads. The row below says where it stands every day.
    $alertNotes = @()
    if ($null -ne $s.alertBelow) {
        $lv = if ($s.currency -eq "₩") { "{0:N0}" -f $s.alertBelow } else { "{0:N2}" -f $s.alertBelow }
        if ($last -le $s.alertBelow) {
            $alertNotes += "알림가 $($s.currency)$lv 아래"
            if ($prev -gt $s.alertBelow) { [void]$highlights.Add([PSCustomObject]@{ text = "$($s.name) $($s.currency)$lv 이탈"; priority = 110 }) }
        }
    }
    if ($null -ne $s.alertAbove) {
        $lv = if ($s.currency -eq "₩") { "{0:N0}" -f $s.alertAbove } else { "{0:N2}" -f $s.alertAbove }
        if ($last -ge $s.alertAbove) {
            $alertNotes += "알림가 $($s.currency)$lv 위"
            if ($prev -lt $s.alertAbove) { [void]$highlights.Add([PSCustomObject]@{ text = "$($s.name) $($s.currency)$lv 돌파"; priority = 110 }) }
        }
    }

    # Earnings within two weeks go on the row; within three days, in the subject too - a report
    # moves the price more than anything else this mail tracks, and it is scheduled.
    $earnHtml = ""
    if ($s.earnings -and $s.earnings.date) {
        $eDate = [datetime]::ParseExact($s.earnings.date, "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
        $dLeft = ($eDate - $nowKst.Date).Days
        if ($dLeft -ge 0 -and $dLeft -le 14) {
            $kind = if ($s.earnings.confirmed) { "확정" } else { "추정" }
            $when = "$($eDate.Month)/$($eDate.Day)" + $(if ($s.earnings.timing) { " $($s.earnings.timing)" } else { "" })
            $dText = if ($dLeft -eq 0) { "D-day" } else { "D-$dLeft" }
            $earnHtml = "<div style='font-size:11.5px;font-weight:600;color:#7a4a00;margin-top:3px;'>실적 발표 $when($kind, 현지 기준), $dText</div>"
            if ($dLeft -le 3) { [void]$highlights.Add([PSCustomObject]@{ text = "$($s.name) 실적 $dText"; priority = 75 }) }
        }
    }
    $alertHtml = if ($alertNotes.Count) { "<div style='font-size:11.5px;font-weight:700;color:#8f5200;margin-top:3px;'>⚑ $($alertNotes -join ', ')</div>" } else { "" }

    # 이평선 도달(매수 기준). 제목에는 처음 닿은 날만 올린다(이평선 근처에 며칠 머물면 매일 제목을 차지하므로).
    $maHtml = ""
    $hitLv = @($s.maLevels | Where-Object { $_ -and $_.buySignal })
    if ($hitLv.Count) {
        $maHtml = "<div style='font-size:11.5px;font-weight:700;color:#2a78d6;margin-top:3px;'>◎ $(($hitLv | ForEach-Object { "$($_.window)일선" }) -join ', ') 도달(매수 기준)</div>"
        if (@($hitLv | Where-Object { $_.firstTouch }).Count) {
            [void]$highlights.Add([PSCustomObject]@{ text = "$($s.name) $($hitLv[0].window)일선 도달"; priority = 105 })
        }
    } else {
        $nearLv = @($s.maLevels | Where-Object { $_ -and $_.state -eq "near" } | Sort-Object gapPct | Select-Object -First 1)
        if ($nearLv.Count) { $maHtml = "<div style='font-size:11.5px;color:#2a78d6;margin-top:3px;'>$($nearLv[0].window)일선까지 $(([double]$nearLv[0].gapPct).ToString('0.0'))%(매수 대기)</div>" }
    }

    # 분할 매수 단계. 적극추천은 색을 채운 표시로 눈에 띄게 하고, 제목에는 2단계 이상으로 오른 날만 올린다.
    $dipHtml = ""
    $dp = $s.dip
    if ($dp -and $dp.level -ge 1) {
        $dipLabel = if ($dp.level -ge 3) {
            "<span style='background:#2a78d6;color:#ffffff;font-weight:700;padding:1px 6px;border-radius:4px;'>▼ $($dp.label)</span>"
        } elseif ($dp.level -eq 2) { "<b>▼ $($dp.label)</b>:" } else { "$($dp.label):" }
        $dipHtml = "<div style='font-size:11.5px;color:#2a78d6;margin-top:4px;'>${dipLabel} $($dp.detail)</div>"
        if ($dp.firstDay -and $dp.level -ge 2) {
            [void]$highlights.Add([PSCustomObject]@{ text = "$($s.name) $($dp.label)"; priority = $(if ($dp.level -ge 3) { 115 } else { 104 }) })
        }
    }

    $trend = $s.maTrend
    $trendHtml = ""
    if ($trend) {
        $trendColor = if ($trend.tone -eq "up") { "#c62828" } elseif ($trend.tone -eq "down") { "#1f5fcc" } else { "#898781" }
        $trendHtml = "<div style='font-size:11.5px;font-weight:600;color:$trendColor;margin-top:4px;'>$($trend.text)</div>"
    }

    $commentHtml = if ($s.comment) { "<div style='font-size:12px;color:#3d3b37;line-height:1.55;margin-top:4px;'>$([System.Net.WebUtility]::HtmlEncode([string]$s.comment))</div>" } else { "" }

    $newsHtml = ""
    if ($s.news -and $s.news.Count -gt 0) {
        $newsLines = foreach ($n in ($s.news | Select-Object -First 2)) {
            $tag = switch ($n.sentiment) {
                "good" { "<span style='color:#c62828;font-weight:700;'>[호재]</span> " }
                "bad"  { "<span style='color:#1f5fcc;font-weight:700;'>[악재]</span> " }
                default { "" }
            }
            # Headlines come from arbitrary outlets: an & or < in one is markup here, and a quote
            # in a link would end the href early.
            $nTitle = [System.Net.WebUtility]::HtmlEncode([string]$n.title)
            $nLink = [System.Net.WebUtility]::HtmlEncode([string]$n.link)
            "<div style='font-size:12px;color:#52514e;margin-top:3px;'>· $tag<a href='$nLink' style='color:#2a78d6;text-decoration:none;'>$nTitle</a></div>"
        }
        $newsHtml = $newsLines -join ""
    }

    # 1개월 등락은 위 기간별 표로 옮겼다(이 칸에는 오늘 값만 둔다).
    $priceInner = @"
<div style="font-weight:650;font-size:14px;color:#0b0b0b;">$($s.currency)$priceFmt</div>
    <div style="font-size:12px;font-weight:600;color:$color;">$arrow $([math]::Abs($pct).ToString("N2"))%</div>
"@
    $priceHtml = if ($s.pageUrl) { "<a href='$($s.pageUrl)' style='text-decoration:none;display:block;'>$priceInner</a>" } else { $priceInner }

    $rowHtml = @"
<tr>
  <td style="padding:10px 12px;border-bottom:1px solid #e1e0d9;width:auto;">
    <div style="font-weight:600;font-size:13px;color:#0b0b0b;">$($s.name)</div>
    <div style="font-size:11px;color:#898781;">$($s.ticker)</div>
    $trendHtml
    $commentHtml
    $maHtml
    $dipHtml
    $alertHtml
    $earnHtml
    $newsHtml
  </td>
  <td width="112" style="padding:10px 12px;border-bottom:1px solid #e1e0d9;text-align:right;white-space:nowrap;vertical-align:top;width:112px;max-width:112px;">
    $priceHtml
  </td>
</tr>
"@
    [PSCustomObject]@{ group = (Get-GroupName $s); html = $rowHtml }
}

# --- 메일 본문 덩어리. 순서는 페이지와 같다: 지금 주목할 점, 매수 단계, 공포·탐욕지수, 기간별 표, 일정, 종목별 상세.

# 지금 주목할 점. 단계별로 묶은 매수 단계 줄은 아래 '오늘의 매수 단계' 상자와 겹쳐서 빼고 다시 8개를 고른다.
$mailHighlights = @($allHighlights | Where-Object { $_.kind -ne "dipGroup" } | Sort-Object priority -Descending | Select-Object -First 8)
$mailHlLines = if ($mailHighlights.Count) {
    @($mailHighlights | ForEach-Object {
        $tagColor = if ($_.tag -match '^(매수 (기준|추천|적극추천)|추가 매수 추천)$') { "#2a78d6" } else { "#6e6c66" }
        $hlItem = $_
        $hlNews = ""
        if ($hlItem.news) {
            $nd = [string]$hlItem.news.date
            $ndTxt = if ($nd -match '^\d{4}-(\d{2})-(\d{2})$') { "$([int]$matches[1])/$([int]$matches[2])" } else { "" }
            $nMeta = (@([string]$hlItem.news.source, $ndTxt) | Where-Object { $_ }) -join ", "
            $hlNews = "<br>&nbsp;&nbsp;&nbsp;<font size=2 color=#6e6c66>관련 기사: <a href='$([System.Net.WebUtility]::HtmlEncode([string]$hlItem.news.link))' style='color:#52514e;'>$([System.Net.WebUtility]::HtmlEncode([string]$hlItem.news.title))</a> ($([System.Net.WebUtility]::HtmlEncode($nMeta)))</font>"
        }
        "· <font color=$tagColor>[$($hlItem.tag)]</font> $([System.Net.WebUtility]::HtmlEncode([string]$hlItem.text))$hlNews"
    })
} else { @("· 평소보다 크게 움직인 종목이나 가까운 실적 발표는 없습니다.") }
$briefRows = @($brief | ForEach-Object {
    "<tr><td valign=top nowrap style='padding:3px 10px 3px 0;font-size:12px;font-weight:700;color:#2a78d6;'>$([System.Net.WebUtility]::HtmlEncode([string]$_.label))</td><td style='padding:3px 0;font-size:12.5px;color:#0b0b0b;line-height:1.6;'>$([System.Net.WebUtility]::HtmlEncode([string]$_.text))</td></tr>"
})
$mailBriefHtml = if ($briefRows.Count) { "<div style='margin:0 0 12px;padding:12px 15px;background:#eef4fc;border-radius:6px;'><div style='font-size:12px;font-weight:700;color:#0b0b0b;margin-bottom:4px;'>오늘의 브리핑</div><table cellpadding=0 cellspacing=0 style='border-collapse:collapse;'>$($briefRows -join '')</table></div>" } else { "" }
$mailHlHtml = "<div style='margin:0 0 16px;padding:12px 15px;background:#ffffff;border:1px solid #e1e0d9;border-radius:6px;'><div style='font-size:12px;font-weight:700;color:#0b0b0b;margin-bottom:4px;'>지금 주목할 점</div><div style='font-size:12.5px;color:#0b0b0b;line-height:1.65;'>$($mailHlLines -join '<br>')</div></div>"

# 오늘의 매수 단계. 분할 매수 3, 2, 1단계와 이평선 도달(매수 기준) 종목을 한 상자에 모은다. 페이지에서는 카드와 표에
# 흩어져 있는 표시라, 메일에서는 오늘 살 구간인 종목을 한눈에 보이게 한다.
$ladderLines = @(foreach ($lvl in 3, 2, 1) {
    $grp = @($stocks | Where-Object { $_.dip -and [int]$_.dip.level -eq $lvl } | Sort-Object { [double]$_.dip.dd } -Descending)
    if (-not $grp.Count) { continue }
    $lab = $grp[0].dip.label
    $tag = if ($lvl -ge 3) { "<span style='background:#2a78d6;color:#ffffff;font-weight:700;padding:1px 6px;border-radius:4px;'>▼ $lab</span>" }
        elseif ($lvl -eq 2) { "<font color=#2a78d6><b>▼ $lab</b></font>" } else { "<font color=#2a78d6><b>$lab</b></font>" }
    # 종목 사이와 이유 사이가 모두 쉼표면 어디서 종목이 바뀌는지 안 보여서, 이유는 종목 이름 뒤 괄호에 넣는다.
    # 괄호 안 % 는 52주 고점 대비 하락률이다(아래 설명 줄에 적는다).
    $items = @($grp | ForEach-Object { "$($_.name)<font color=#6e6c66>($($_.dip.why -replace '고점 대비 ', ''))</font>$(if ($_.dip.firstDay) { ' <font color=#c62828><b>오늘 진입</b></font>' })" })
    "<tr><td valign=top nowrap>$tag</td><td>$($items -join ', ')</td></tr>"
})
$touchItems = @(foreach ($stk in $stocks) {
    $touched = @($stk.maLevels | Where-Object { $_ -and $_.buySignal })
    if ($touched.Count) { "$($stk.name)<font color=#6e6c66>($(($touched | ForEach-Object { "$($_.window)일선$(if ($_.intraday) { ' 장중' })" }) -join ', '))</font>" }
})
if ($touchItems.Count) { $ladderLines += "<tr><td valign=top nowrap><font color=#2a78d6><b>◎ 이평선 도달</b></font></td><td>$($touchItems -join ', ')</td></tr>" }
$ddStepsM = @($buyRules.dip.drawdownSteps)
$maStepsM = @($buyRules.dip.maSteps)
$stepNames = @("1단계 매수 추천", "2단계 추가 매수 추천", "3단계 매수 적극추천")
$ruleParts = @(for ($i = 0; $i -lt [math]::Min(3, $ddStepsM.Count); $i++) {
    "$(if ($i -eq 0) { '52주 고점보다 ' })$($ddStepsM[$i])% 낮$(if ($i -lt $maStepsM.Count) { "거나 $($maStepsM[$i])일선에 닿으면" } else { '으면' }) $($stepNames[$i])"
})
$ladderBody = if ($ladderLines.Count) {
    "<table width=100% cellpadding=4 cellspacing=0 style='margin-top:4px;font-size:12.5px;color:#0b0b0b;line-height:1.5;'>$($ladderLines -join '')</table>"
} else { "<div style='font-size:12.5px;color:#52514e;margin-top:4px;'>오늘은 매수 단계에 든 종목이 없습니다.</div>" }
$ladderHtml = @"
<div style="margin:0 0 16px;padding:12px 15px;background:#ffffff;border:1px solid #e1e0d9;border-left:4px solid #2a78d6;border-radius:6px;">
  <div style="font-size:12px;font-weight:700;color:#0b0b0b;">오늘의 매수 단계</div>
  $ladderBody
  <div style="font-size:10.5px;color:#898781;margin-top:6px;line-height:1.5;">괄호 안 %는 52주 고점 대비 하락률입니다. $($ruleParts -join ', ')입니다. 종목별로 기준을 따로 정한 종목은 대시보드 카드에 그 기준이 적힙니다. 본인 매매 기준을 그대로 적용한 표시이며 매매를 권하는 것이 아닙니다.</div>
</div>
"@

# 기간별 등락. 페이지 한눈 요약의 기간별 표와 분야별 등락 지도를 합친 모양이다(분야 소제목에 오늘 상승과 하락 종목 수).
$perfRows = @(foreach ($g in $groupOrder) {
    $members = @($stocks | Where-Object { (Get-GroupName $_) -eq $g })
    if (-not $members.Count) { continue }
    $d1s = @($members | ForEach-Object { if ($_.perf) { $_.perf.d1 } } | Where-Object { $null -ne $_ })
    $nUp = @($d1s | Where-Object { [double]$_ -gt 0 }).Count
    $nDown = @($d1s | Where-Object { [double]$_ -lt 0 }).Count
    $dirColor = if ($nUp -gt $nDown) { "#c62828" } elseif ($nDown -gt $nUp) { "#1f5fcc" } else { "#898781" }
    $dirArrow = if ($nUp -gt $nDown) { "▲ " } elseif ($nDown -gt $nUp) { "▼ " } else { "" }
    $dirTxt = (@($(if ($nUp) { "상승 $nUp" }), $(if ($nDown) { "하락 $nDown" })) | Where-Object { $_ }) -join ", "
    if (-not $dirTxt) { $dirTxt = "보합" }
    "<tr><td colspan=6 style='padding-top:10px;border-bottom:1px solid #e1e0d9;'><font size=1 color=#6e6c66><b>$g</b></font> <font size=1 color=$dirColor><b>$dirArrow$dirTxt</b></font></td></tr>"
    foreach ($stk in $members) {
        $trendM = $stk.maTrend
        $tc = if ($trendM -and $trendM.tone -eq "up") { "#c62828" } elseif ($trendM -and $trendM.tone -eq "down") { "#1f5fcc" } else { "#898781" }
        $sig = Get-MailSignal $stk
        $pf = $stk.perf
        $thr = if ($pf) { $pf.thr } else { $null }
        $valTxt = "$($stk.currency)$(Format-Price ([double]$stk.series[-1]) $stk.currency)"
        "<tr><td><b>$($stk.name)</b>$(if ($trendM) { " <font size=1 color=$tc>$($trendM.text)</font>" })$(if ($sig) { "<br><font size=1>$sig</font>" })</td><td align=right nowrap>$valTxt</td>$(Get-MailPctCell $pf.d1 $thr.d1)$(Get-MailPctCell $pf.w1 $thr.w1)$(Get-MailPctCell $pf.m1 $thr.m1)$(Get-MailPctCell $pf.y1 $thr.y1)</tr>"
    }
})
$perfHtml = @"
<div style="margin:0 0 16px;padding:12px 15px;background:#ffffff;border:1px solid #e1e0d9;border-radius:6px;">
  <div style="font-size:12px;font-weight:700;color:#0b0b0b;">기간별 등락</div>
  <table width="100%" cellpadding=4 cellspacing=0 style="margin-top:2px;font-size:12.5px;color:#0b0b0b;">
    <tr style="font-size:10.5px;color:#898781;"><td>종목 (최근 흐름)</td><td align=right>현재가</td><td align=right>오늘</td><td align=right>1주</td><td align=right>1개월</td><td align=right>1년</td></tr>
    $($perfRows -join "")
  </table>
  <div style="font-size:10.5px;color:#898781;margin-top:8px;line-height:1.5;">빨강은 상승, 파랑은 하락입니다. 칸 배경은 그 종목의 평소 등락 폭보다 크게 움직인 칸이고, 2배 이상이면 진하게 칠합니다.</div>
</div>
"@

# 다가오는 일정(14일). 페이지 '다가오는 일정'(120일)에서 가까운 것만 싣는다(실적 발표, FOMC, CPI, 금통위, 휴장).
$schedLines = @(foreach ($ev in $scheduleItems) {
    $d0 = [datetime]::ParseExact([string]$ev.date, "yyyy-MM-dd", $inv)
    $dEnd = [datetime]::ParseExact([string]$ev.end, "yyyy-MM-dd", $inv)
    $left = ($d0 - $nowKst.Date).Days
    if ($left -gt 14) { continue }
    $dTxt = if ($left -lt 0) { "진행 중" } elseif ($left -eq 0) { "오늘" } else { "D-$left" }
    $when = "$($d0.Month)/$($d0.Day)($($dayNames[[int]$d0.DayOfWeek]))$(if ($dEnd -gt $d0) { "~$($dEnd.Month)/$($dEnd.Day)" })"
    $evNote = if ($ev.note) { " <font size=1 color=#898781>$([System.Net.WebUtility]::HtmlEncode([string]$ev.note))</font>" } else { "" }
    "<tr><td nowrap valign=top>$when</td><td nowrap valign=top><font color=#6e6c66>$dTxt</font></td><td><font color=#6e6c66>[$($ev.kind)]</font> $([System.Net.WebUtility]::HtmlEncode([string]$ev.title))$evNote</td></tr>"
})
$scheduleMailHtml = if ($schedLines.Count) { @"
<div style="margin:0 0 16px;padding:12px 15px;background:#ffffff;border:1px solid #e1e0d9;border-radius:6px;">
  <div style="font-size:12px;font-weight:700;color:#0b0b0b;">다가오는 일정 (14일)</div>
  <table width="100%" cellpadding=3 cellspacing=0 style="margin-top:4px;font-size:12.5px;color:#0b0b0b;">
    $($schedLines -join "")
  </table>
</div>
"@ } else { "" }

# 종목별 상세. 분야마다 소제목과 표를 따로 둔다(페이지 카드 구역과 같다).
$detailHtml = (@(foreach ($g in $groupOrder) {
    $rows = @($rowsHtml | Where-Object { $_.group -eq $g } | ForEach-Object { $_.html })
    if (-not $rows.Count) { continue }
    @"
<div style="margin:18px 0 6px;font-size:11.5px;font-weight:700;color:#6e6c66;letter-spacing:0.6px;">$g</div>
  <table style="width:100%;border-collapse:collapse;background:#ffffff;border:1px solid #e1e0d9;">
    $($rows -join "`n")
  </table>
"@
})) -join "`n"

$fxLine = if ($usdKrw) { " · USD/KRW $($usdKrw.ToString('N2'))" } else { "" }
$fgLine = if ($fearGreed) { " · 공포·탐욕지수 $($fearGreed.score)($($fearGreed.ratingKo))" } else { "" }

# 공포·탐욕지수 안내 블록. 지금까지 메일에는 제목줄에 점수와 밴드만 붙어 있었는데, 이 숫자 하나로
# 매수 시점을 잡는다면 판단에 필요한 절반이 빠져 있는 셈이었다 — 원칙상 어느 구간인지가 없었다.
#
# 방향을 같이 싣는 이유: 같은 "공포 40" 이라도 어제 52 에서 내려온 40 과 어제 28 에서 올라온 40 은
# 역발상 전략에서 다른 뜻이다. 전자는 공포가 깊어지는 중이고 후자는 풀리는 중이다. 숫자 하나만
# 던져두면 그 차이가 안 보인다.
$fgBlockHtml = ""
if ($fearGreed) {
    $act = Get-FearGreedAction -rating $fearGreed.rating
    if ($act) {
        # 메일은 라이트 전용이라 페이지 토큰 대신 고정 hex 를 쓴다. 매수 구간은 초록, 매도 구간은
        # 빨강 — 밴드 색(공포=빨강)이 아니라 '행동' 색이다. 공포 구간이 빨간 배경에 "매수"라고
        # 적혀 있으면 한눈에 반대로 읽힌다.
        $pal = switch ($act.tone) {
            "buy-strong"  { @{ fg = "#0a6b0a"; bg = "#eaf4ea"; br = "#bcd9bc"; edge = "#0a6b0a" } }
            "buy"         { @{ fg = "#0a6b0a"; bg = "#f1f6f1"; br = "#cfe3cf"; edge = "#5ba25b" } }
            "hold"        { @{ fg = "#52514e"; bg = "#f5f5f3"; br = "#e1e0d9"; edge = "#a3a199" } }
            "sell"        { @{ fg = "#b3221f"; bg = "#fdeeee"; br = "#f3caca"; edge = "#d97a78" } }
            "sell-strong" { @{ fg = "#b3221f"; bg = "#fbe3e3"; br = "#eebbbb"; edge = "#b3221f" } }
        }

        $prev = @($fearGreed.history | Where-Object { $_.label -eq "전일" })[0]
        $trendHtml = ""
        if ($prev) {
            $delta = $fearGreed.score - $prev.score
            $trendHtml = if ($delta -lt 0) {
                "전일 $($prev.score) → 오늘 $($fearGreed.score) · <b>공포가 $([math]::Abs($delta))p 깊어지는 중</b>"
            } elseif ($delta -gt 0) {
                "전일 $($prev.score) → 오늘 $($fearGreed.score) · <b>공포가 ${delta}p 풀리는 중</b>"
            } else {
                "전일과 같은 $($fearGreed.score)"
            }
        }
        $trendRow = if ($trendHtml) { "<div style='font-size:12px;color:#52514e;margin-top:6px;'>$trendHtml</div>" } else { "" }

        $fgBlockHtml = @"
<div style="margin:0 0 16px;padding:13px 15px;background:$($pal.bg);border:1px solid $($pal.br);border-left:4px solid $($pal.edge);border-radius:6px;">
  <div style="font-size:11px;font-weight:bold;color:#898781;letter-spacing:0.04em;">공포·탐욕지수 기준 참고 구간</div>
  <div style="margin-top:5px;">
    <span style="font-size:26px;font-weight:bold;color:#0b0b0b;vertical-align:middle;">$($fearGreed.score)</span>
    <span style="font-size:13px;color:#52514e;vertical-align:middle;">$($fearGreed.ratingKo)</span>
    <span style="font-size:14px;font-weight:bold;color:$($pal.fg);vertical-align:middle;margin-left:6px;">$($act.text)</span>
  </div>
  $trendRow
  <div style="font-size:11px;color:#898781;margin-top:7px;line-height:1.5;">
    "공포에 사고 탐욕에 팔라"는 원칙을 CNN 구간에 붙인 참고 문구이며 매매 신호가 아닙니다.
    극단적 공포는 바닥 직전에도 나오지만 하락이 더 이어지는 구간에도 나옵니다.
  </div>
</div>
"@
    }
} else {
    # CNN 이 끝내 응답하지 않은 날. 전에는 이 블록과 제목의 "공포 NN · 매수 고려"가 둘 다 말없이
    # 사라져서, 지수를 보고 매수 시점을 잡는 사람에게는 신호가 빠진 날과 평범한 날이 구분되지
    # 않았다. 빠졌다는 사실 자체를 보여준다.
    $fgBlockHtml = @"
<div style="margin:0 0 16px;padding:12px 15px;background:#fdf6e7;border:1px solid #f0dcb4;border-left:4px solid #a15c00;border-radius:6px;">
  <div style="font-size:13px;font-weight:bold;color:#a15c00;">⚠ 오늘은 공포·탐욕지수를 받지 못했습니다</div>
  <div style="font-size:11.5px;color:#52514e;margin-top:4px;">CNN 사이트가 응답하지 않았습니다. 다음 실행 때 자동으로 다시 조회합니다. 급한 경우 <a href="https://edition.cnn.com/markets/fear-and-greed" style="color:#2a78d6;">CNN Fear &amp; Greed</a>에서 직접 확인하시기 바랍니다.</div>
</div>
"@
}

# Email subject lines are plain text by spec — a hyperlink can't live there. The equivalent is a
# prominent button at the very top of the body, which is one tap away in any mail client.
$dashboardUrl = "https://jhkim0603.github.io/stockdashboard/"

# The color-scheme meta pair says this mail is designed for light and only light. Without it,
# Gmail's and Apple Mail's dark modes decide for themselves which colours to invert, and they
# invert backgrounds more eagerly than text - which is how a card ends up dark grey with the
# near-black heading still sitting on it. Declaring one scheme opts the message out of that
# guesswork. Kept as a PowerShell comment rather than an HTML one so it is not mailed.
$emailHtml = @"
<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="color-scheme" content="light">
<meta name="supported-color-schemes" content="light">
</head>
<body style="margin:0;padding:0;background:#f9f9f7;font-family:'Malgun Gothic',sans-serif;">
<div style="max-width:600px;margin:0 auto;padding:24px 16px;">
  <h2 style="margin:0 0 4px;color:#0b0b0b;">JH 주식 투자 Dashboard</h2>
  <div style="font-size:12px;color:#898781;margin-bottom:14px;">$emailDateStr 기준$fxLine$fgLine</div>
  <div style="margin-bottom:16px;">
    <a href="$dashboardUrl" style="display:inline-block;background:#2a78d6;color:#ffffff;font-size:13px;font-weight:bold;text-decoration:none;padding:10px 18px;border-radius:6px;">📊 대시보드 열기 →</a>
  </div>
  $mailBriefHtml
  $mailHlHtml
  $ladderHtml
  $fgBlockHtml
  $perfHtml
  $scheduleMailHtml
  <div style="margin:22px 0 0;font-size:12px;font-weight:700;color:#0b0b0b;">종목별 상세</div>
  $detailHtml
  <div style="margin-top:16px;font-size:11px;color:#898781;line-height:1.6;">
    출처: 시세 Yahoo Finance, 뉴스 Google 뉴스(영문 기사는 자동 번역). 개인 투자 판단의 참고용 요약입니다.<br>
    실적, 목표주가, 이동평균선, 전체 차트는 <a href="$dashboardUrl" style="color:#2a78d6;">대시보드</a>에서 확인하시기 바랍니다.
  </div>
</div>
</body></html>
"@

# Set-Content -Encoding UTF8 writes a BOM, which would leak into the mail subject/body as a
# stray character in some clients — write both files BOM-less instead.
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $root "email-summary.html"), $emailHtml, $utf8NoBom)
# 제목에도 지수와 구간을 넣는다. 받은편지함 목록에서 메일을 열지 않고도 오늘이 어느 구간인지
# 보이고, 나중에 "공포 20" 같은 말로 지난 메일을 찾을 수도 있다.
$fgSubject = if ($fearGreed) {
    $a = Get-FearGreedAction -rating $fearGreed.rating
    if ($a) { " · $($fearGreed.ratingKo) $($fearGreed.score) · $($a.text)" } else { "" }
} else { " · 공포지수 수집실패" }
# 특이사항이 공포·탐욕지수보다 앞에 온다. 지수는 매일 있는 상시 정보지만 특이사항은 있는 날만
# 붙는 예외 정보라 먼저 읽혀야 하고, 무엇보다 받은편지함 목록(특히 모바일은 40자 안팎에서 잘림)
# 에서 뒤에 두면 정작 알려야 할 내용이 통째로 잘려 나간다. 없는 날은 예전과 똑같은 제목이 된다.
$topHighlights = @($highlights | Sort-Object priority -Descending | Select-Object -First 3 -ExpandProperty text)
$highlightSubject = if ($topHighlights.Count -gt 0) { " · ⚠ " + ($topHighlights -join ", ") } else { "" }
[System.IO.File]::WriteAllText((Join-Path $root "email-subject.txt"), "JH 주식 투자 Dashboard - $emailDateStr$highlightSubject$fgSubject", $utf8NoBom)
$emailKb = [math]::Round($utf8NoBom.GetByteCount($emailHtml) / 1KB, 1)
Write-Host "Email summary written: email-summary.html ($emailKb KB)"
# work-dashboard 와 같은 경고. Gmail 은 본문이 102KB 를 넘으면 뒷부분을 '[메시지 잘림]'으로 접는다(이 메일에서는
# 맨 아래 종목별 상세가 사라진다). 2026-10-29 개편으로 34KB 에서 46KB 가 됐다. 배포는 막지 않는다.
if ($emailKb -gt 90) {
    Write-Warning "메일 본문 $emailKb KB - Gmail 잘림 기준(102KB)에 가깝습니다. 종목별 기사 수나 섹션을 줄이세요."
    if ($env:CI) { Write-Host "::warning::메일 본문 $emailKb KB - Gmail 잘림 기준 102KB 의 $([math]::Round($emailKb / 102 * 100))%" }
}

# --- Output checks -------------------------------------------------------------------------
# Same idea as work-dashboard's: the checks that used to be made by eye after a run. Failing
# here stops the workflow before the mail and Pages steps, so yesterday's good page stays up
# rather than a half-built one going out with a green checkmark. A ticker with no news in the
# 21-day window is normal and is not checked.
$problems = New-Object System.Collections.Generic.List[string]

$renderedHtml = Get-Content -Path $outPath -Raw -Encoding UTF8
foreach ($token in @("__STOCKS_JSON__", "__USDKRW_JSON__", "__USDKRW_SERIES_JSON__", "__FEARGREED_JSON__", "__FETCHED_AT__", "__HIGHLIGHTS_JSON__", "__SCHEDULE_JSON__", "__STRIP_JSON__", "__BRIEF_JSON__")) {
    if ($renderedHtml -like "*$token*") { $problems.Add("템플릿 치환 누락: $token") }
}

# One flaky ticker is tolerated above; losing more than half means the run itself went wrong.
if ($stocks.Count -lt [Math]::Ceiling($tickers.Count / 2)) {
    $problems.Add("종목 $($stocks.Count)/$($tickers.Count)개만 수집되었습니다 (절반 미만)")
}
foreach ($s in $stocks) {
    if (@($s.series).Count -eq 0) { $problems.Add("$($s.symbol): 시계열이 비어 있습니다") }
}
# 시세와 52주 고가만 있으면 모든 종목이 단계를 갖는다. 하나도 없으면 계산이 고장 난 것이고, 그날 메일은 신호가 없는
# 평범한 날처럼 보이게 된다.
if ($stocks.Count -and -not @($stocks | Where-Object { $_.dip }).Count) {
    $problems.Add("분할 매수 단계를 한 종목도 계산하지 못했습니다")
}

$newsCut = $nowKst.Date.AddDays(-45)
foreach ($s in $stocks) {
    foreach ($n in @($s.news | Where-Object { $_ })) {
        [DateTime]$nd = Get-Date
        if ([DateTime]::TryParse($n.date, [ref]$nd) -and $nd -lt $newsCut) {
            $problems.Add("$($s.symbol): 오래된 기사가 남아 있습니다 ($($n.date))")
        }
    }
}

foreach ($f in @("email-summary.html", "email-subject.txt")) {
    $p = Join-Path $root $f
    if (-not (Test-Path $p) -or (Get-Item $p).Length -eq 0) { $problems.Add("$f 가 비어 있거나 없습니다") }
}

if ($problems.Count -gt 0) {
    Write-Host ""
    Write-Host "생성물 점검 실패 - 배포를 중단합니다:" -ForegroundColor Red
    foreach ($p in $problems) { Write-Host "  · $p" -ForegroundColor Red }
    if ($env:CI) { Write-Host "::error::생성물 점검 실패 $($problems.Count)건" }
    throw "생성물 점검 $($problems.Count)건 실패 - 이전 배포본을 유지합니다."
}
if ($script:spamBlocked -gt 0) { Write-Host "스팸 헤드라인 $($script:spamBlocked)건 차단됨" }
$newsCount = 0
foreach ($s in $stocks) { $newsCount += @($s.news | Where-Object { $_ }).Count }
Write-Host "생성물 점검 통과 (종목 $($stocks.Count)/$($tickers.Count)개 · 뉴스 ${newsCount}건)"
