<#
  Update-StockDashboard.ps1
  Fetches live quotes (Yahoo Finance) + recent headlines (Google News RSS) for the tickers below
  and regenerates dashboard.html.
  Run manually by double-clicking run.bat, or right-click > Run with PowerShell.
#>

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

# Tickers live in watchlist.json, not here — only "Symbol" is required, e.g. { "Symbol": "AAPL" }.
# Everything else (DisplayName, MarketLabel, NewsQuery, NewsLang, FinanceMode/Code) is optional and
# auto-derived from the symbol below; set any of them explicitly in watchlist.json to override.
#   Symbol suffix convention: ".KS" = KOSPI, ".KQ" = KOSDAQ, "^" prefix = index, "XXX-USD" = 코인,
#   anything else = NASDAQ
#   (NYSE tickers need an explicit "FinanceCode": "SYMBOL.N" override — the auto-default assumes NASDAQ)
function Resolve-TickerConfig {
    param($raw)

    $symbol = $raw.Symbol
    if (-not $symbol) { throw "watchlist.json 항목에 Symbol이 없습니다: $($raw | ConvertTo-Json -Compress)" }

    $isIndex = if ($null -ne $raw.IsIndex) { [bool]$raw.IsIndex } else { $symbol.StartsWith("^") }
    $isDomestic = $symbol.EndsWith(".KS") -or $symbol.EndsWith(".KQ")
    # 코인은 실적·목표주가가 없다. 판정하지 않으면 해외주식으로 떨어져 네이버에 "BTC-USD.O" 를
    # 묻고, 메일 링크도 존재하지 않는 BTC-USD:NASDAQ 페이지로 간다.
    $isCrypto = if ($null -ne $raw.IsCrypto) { [bool]$raw.IsCrypto } else { $symbol -match '^[A-Z0-9]+-USD$' }

    $marketLabel =
        if ($raw.MarketLabel) { $raw.MarketLabel }
        elseif ($isIndex) { "지수" }
        elseif ($isCrypto) { "코인" }
        elseif ($symbol.EndsWith(".KS")) { "KOSPI" }
        elseif ($symbol.EndsWith(".KQ")) { "KOSDAQ" }
        else { "NASDAQ" }

    $newsLang = if ($raw.NewsLang) { $raw.NewsLang } elseif ($isDomestic) { "ko" } else { "en" }

    $financeMode =
        if ($raw.FinanceMode) { $raw.FinanceMode }
        elseif ($isIndex -or $isCrypto) { $null }
        elseif ($isDomestic) { "domestic" }
        else { "overseas" }

    $financeCode =
        if ($raw.FinanceCode) { $raw.FinanceCode }
        elseif ($financeMode -eq "domestic") { $symbol -replace '\.KS$|\.KQ$', '' }
        elseif ($financeMode -eq "overseas") { "$symbol.O" }
        else { $null }

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
    }
}

$watchlistRaw = Get-Content -Path (Join-Path $root "watchlist.json") -Raw -Encoding UTF8 | ConvertFrom-Json
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

function Get-NewsSentiment {
    # 제목에 등장한 호재/악재 키워드 수를 세어 더 많은 쪽으로 분류. 동점이거나 하나도 없으면 중립.
    param($title)
    if (-not $title) { return "neutral" }
    $goodHits = @($sentimentKeywords.good | Where-Object { $title -like "*$_*" }).Count
    $badHits  = @($sentimentKeywords.bad  | Where-Object { $title -like "*$_*" }).Count
    if ($goodHits -gt $badHits) { return "good" }
    if ($badHits -gt $goodHits) { return "bad" }
    return "neutral"
}

function Get-NewsHeadlines {
    param($query, $lang, $max = 4)

    $loc = $newsLocales[$lang]
    $uri = "https://news.google.com/rss/search?q=" + [uri]::EscapeDataString($query) + "&hl=$($loc.hl)&gl=$($loc.gl)&ceid=$($loc.ceid)"
    try {
        $raw = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing
        [xml]$rss = $raw.Content
        $items = $rss.rss.channel.item | Select-Object -First $max

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
            [PSCustomObject]@{
                title   = $title
                source  = $source
                pubDate = [System.DateTimeOffset]::Parse($it.pubDate)
                link    = $it.link
            }
        })

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

function Get-StockSnapshot {
    param($cfg)

    $uri = "https://query1.finance.yahoo.com/v8/finance/chart/$($cfg.Symbol)?interval=1d&range=1y"
    $resp = Invoke-RestMethod -Uri $uri -Headers $headers
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

    $pairs = @(for ($i = 0; $i -lt $closes.Count; $i++) {
        if ($null -ne $closes[$i]) {
            [PSCustomObject]@{
                Date  = ConvertTo-ExchangeDate $timestamps[$i]
                Close = [math]::Round([double]$closes[$i], 2)
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
            $pairs += [PSCustomObject]@{ Date = $metaDate; Close = [math]::Round([double]$meta.regularMarketPrice, 2) }
        }
    }

    $fullSeries = @($pairs.Close)
    $fullDates  = @($pairs.Date)

    # Yahoo's meta.fiftyTwoWeekHigh/Low occasionally comes back as 0 for some tickers;
    # fall back to the min/max of the fetched 1y series so we never divide by zero.
    $rangeHigh = if ($meta.fiftyTwoWeekHigh -and $meta.fiftyTwoWeekHigh -gt 0) { $meta.fiftyTwoWeekHigh } else { ($fullSeries | Measure-Object -Maximum).Maximum }
    $rangeLow  = if ($meta.fiftyTwoWeekLow  -and $meta.fiftyTwoWeekLow  -gt 0) { $meta.fiftyTwoWeekLow }  else { ($fullSeries | Measure-Object -Minimum).Minimum }

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

    $periodSign = if ($periodPct -ge 0) { "+" } else { "" }
    $lowSign    = if ($pctFromLow -ge 0) { "+" } else { "" }

    $summary = "최근 {0}거래일 중 {1}일 상승 · {2}일 하락, 기간 시작 대비 {3}{4:N1}%. 52주 고점 대비 {5:N1}%, 저점 대비 {6}{7:N1}% 수준입니다." -f `
        $rSeries.Count, $upDays, $downDays, $periodSign, $periodPct, $pctFromHigh, $lowSign, $pctFromLow

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
        # 거래소 자체 이름. 시세 지연 점검에서 같은 장끼리만 비교하려면 이게 필요하다 —
        # MarketLabel 로는 KOSPI 지수와 나스닥 지수가 똑같이 "지수" 라 한 그룹이 돼버린다.
        exchangeTz = $meta.exchangeTimezoneName
        rangeLow  = $rangeLow
        rangeHigh = $rangeHigh
        summary   = $summary
        news      = $news
        finance   = $finance
        consensus = $consensus
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
    # Mirrors the dashboard's own detectCross() in template.html — same MA windows, same
    # 5-day lookback for an actual sign-flip event, not just "which MA is on top now".
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
    # Mirrors the dashboard's own describeMaTrend() in template.html — same priority order
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
    if ($cross -eq "golden") { return @{ text = "골든크로스임, 상승전환임"; tone = "up" } }
    if ($cross -eq "dead")   { return @{ text = "데드크로스임, 하락전환임"; tone = "down" } }

    if ($null -eq $a -or $null -eq $b) { return $null }  # not enough history yet for even the 20/60 pair

    if ($null -ne $c) {
        if ($last -gt $a -and $a -gt $b -and $b -gt $c) { return @{ text = "정배열임, 상승추세임"; tone = "up" } }
        if ($last -lt $a -and $a -lt $b -and $b -lt $c) { return @{ text = "역배열임, 하락추세임"; tone = "down" } }
    }

    if ($a -gt $b) { return @{ text = "정배열은 아님, 단기 상승세"; tone = "up" } }
    if ($a -lt $b) { return @{ text = "역배열은 아님, 단기 하락세"; tone = "down" } }
    return @{ text = "뚜렷한 추세 없음"; tone = $null }
}

function Get-StockPageUrl {
    # Where the email's price link should go — a real per-ticker page to read more, the same
    # way news links already go to their source article.
    param($cfg)
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
    $fxPairs = for ($i = 0; $i -lt $fxCloses.Count; $i++) {
        if ($null -ne $fxCloses[$i]) {
            [PSCustomObject]@{
                Date  = [DateTimeOffset]::FromUnixTimeSeconds($fxTimestamps[$i]).ToLocalTime().ToString("yyyy-MM-dd")
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
$stocks = foreach ($t in $tickers) {
    Write-Host "  - $($t.Symbol)"
    try {
        Get-StockSnapshot $t
    } catch {
        # One flaky ticker (Yahoo's unofficial endpoint is occasionally unreliable) must not take
        # down the whole run — skip it and keep going, so the rest of the dashboard/email still ships.
        Write-Warning "Skipping $($t.Symbol) - snapshot fetch failed: $($_.Exception.Message)"
    }
    Start-Sleep -Milliseconds 400  # be gentle with Yahoo's unofficial endpoint across 7 tickers
}

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

# ConvertTo-Json on $null returns $null (not the string "null"), and String.Replace() coerces a
# $null replacement to "" — which would emit `const fearGreed = ;` into the page, a hard
# SyntaxError that stops the whole script block and renders a completely blank dashboard.
# Any optional value that can legitimately be missing must go through this.
function ConvertTo-JsonOrNull {
    param($InputObject, $Depth = 4)
    if ($null -eq $InputObject) { return "null" }
    $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth
    if ($null -eq $json -or $json -eq "") { return "null" }
    return $json
}

$stocksJson = ConvertTo-Json -InputObject @($stocks) -Depth 8
$usdKrwJson = ConvertTo-JsonOrNull -InputObject $usdKrw
$usdKrwSeriesJson = ConvertTo-JsonOrNull -InputObject $usdKrwSeries -Depth 4
$fearGreedJson = ConvertTo-JsonOrNull -InputObject $fearGreed
$fetchedAt = $nowKst.ToString("yyyy-MM-ddTHH:mm:ss") + "+09:00"  # $nowKst's DateTimeKind is still Utc after the manual +9h shift, so "zzz" would report +00:00 — append the known-fixed KST offset literally instead.

$template = Get-Content -Path (Join-Path $root "template.html") -Raw -Encoding UTF8
$output = $template.Replace("__STOCKS_JSON__", $stocksJson).Replace("__USDKRW_JSON__", $usdKrwJson).Replace("__USDKRW_SERIES_JSON__", $usdKrwSeriesJson).Replace("__FEARGREED_JSON__", $fearGreedJson).Replace("__FETCHED_AT__", $fetchedAt)

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

$rowsHtml = foreach ($s in $stocks) {
    $last = $s.series[-1]
    $prev = $s.series[-2]
    $diff = $last - $prev
    $pct = if ($prev -ne 0) { ($diff / $prev) * 100 } else { 0 }
    $up = $diff -ge 0
    $sign = if ($up) { "+" } else { "" }
    $color = if ($up) { "#0ca30c" } else { "#e34948" }
    $arrow = if ($up) { "▲" } else { "▼" }
    $priceFmt = if ($s.currency -eq "₩") { "{0:N0}" -f $last } else { "{0:N2}" -f $last }

    if ([math]::Abs($pct) -ge $MOVE_THRESHOLD_PCT) {
        $dir = if ($up) { "급등" } else { "급락" }
        [void]$highlights.Add([PSCustomObject]@{ text = "$($s.name) $dir $sign$($pct.ToString('N1'))%"; priority = [math]::Abs($pct) })
    }
    $cross = Get-CrossSignal -series $s.series
    if ($cross -eq "golden") { [void]$highlights.Add([PSCustomObject]@{ text = "$($s.name) 골든크로스"; priority = 80 }) }
    elseif ($cross -eq "dead") { [void]$highlights.Add([PSCustomObject]@{ text = "$($s.name) 데드크로스"; priority = 80 }) }
    if ($last -ge ($s.rangeHigh * 0.999)) { [void]$highlights.Add([PSCustomObject]@{ text = "$($s.name) 52주 신고가"; priority = 100 }) }
    elseif ($last -le ($s.rangeLow * 1.001)) { [void]$highlights.Add([PSCustomObject]@{ text = "$($s.name) 52주 신저가"; priority = 100 }) }

    $trend = Get-MaTrendComment -series $s.series
    $trendHtml = ""
    if ($trend) {
        $trendColor = if ($trend.tone -eq "up") { "#0ca30c" } elseif ($trend.tone -eq "down") { "#e34948" } else { "#898781" }
        $trendHtml = "<div style='font-size:11.5px;font-weight:600;color:$trendColor;margin-top:4px;'>$($trend.text)</div>"
    }

    $newsHtml = ""
    if ($s.news -and $s.news.Count -gt 0) {
        $newsLines = foreach ($n in ($s.news | Select-Object -First 2)) {
            $tag = switch ($n.sentiment) {
                "good" { "<span style='color:#0ca30c;font-weight:700;'>[호재]</span> " }
                "bad"  { "<span style='color:#e34948;font-weight:700;'>[악재]</span> " }
                default { "" }
            }
            "<div style='font-size:12px;color:#52514e;margin-top:3px;'>· $tag<a href='$($n.link)' style='color:#2a78d6;text-decoration:none;'>$($n.title)</a></div>"
        }
        $newsHtml = $newsLines -join ""
    }

    $priceInner = @"
<div style="font-weight:650;font-size:14px;color:#0b0b0b;">$($s.currency)$priceFmt</div>
    <div style="font-size:12px;font-weight:600;color:$color;">$arrow $([math]::Abs($pct).ToString("N2"))%</div>
"@
    $priceHtml = if ($s.pageUrl) { "<a href='$($s.pageUrl)' style='text-decoration:none;display:block;'>$priceInner</a>" } else { $priceInner }

    @"
<tr>
  <td style="padding:10px 12px;border-bottom:1px solid #e1e0d9;width:auto;">
    <div style="font-weight:600;font-size:13px;color:#0b0b0b;">$($s.name)</div>
    <div style="font-size:11px;color:#898781;">$($s.ticker)</div>
    $trendHtml
    $newsHtml
  </td>
  <td width="112" style="padding:10px 12px;border-bottom:1px solid #e1e0d9;text-align:right;white-space:nowrap;vertical-align:top;width:112px;max-width:112px;">
    $priceHtml
  </td>
</tr>
"@
}

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
    "공포에 사고 탐욕에 팔라" 원칙을 CNN 밴드에 얹은 참고 문구입니다. 매매 신호가 아닙니다 —
    극단적 공포는 바닥 직전에도, 하락이 더 이어지는 구간에도 나옵니다.
  </div>
</div>
"@
    }
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
  $fgBlockHtml
  <table style="width:100%;border-collapse:collapse;background:#ffffff;border:1px solid #e1e0d9;border-radius:8px;">
    $($rowsHtml -join "`n")
  </table>
  <div style="margin-top:16px;font-size:11px;color:#898781;line-height:1.6;">
    시세 출처: Yahoo Finance. 뉴스 출처: Google 뉴스(영문 기사는 자동 번역). 투자 판단 참고용으로만 사용하세요 — 개인 용도 요약입니다.<br>
    실적·목표주가·이동평균선·전체 차트 등 자세한 내용은 <a href="$dashboardUrl" style="color:#2a78d6;">대시보드</a>에서 확인하세요.
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
} else { "" }
$topHighlights = @($highlights | Sort-Object priority -Descending | Select-Object -First 3 -ExpandProperty text)
$highlightSubject = if ($topHighlights.Count -gt 0) { " · ⚠ " + ($topHighlights -join ", ") } else { "" }
[System.IO.File]::WriteAllText((Join-Path $root "email-subject.txt"), "JH 주식 투자 Dashboard - $emailDateStr$fgSubject$highlightSubject", $utf8NoBom)
Write-Host "Email summary written: email-summary.html"
