"""StockDashboard 매수 기준 과거 검증.

대시보드(Update-StockDashboard.ps1)의 Get-MaLevels·Get-DipSignal 규칙을 그대로 옮겨 10년치 일봉에 매일 적용하고,
신호가 새로 켜진 날 종가에 샀다면 1·3·6개월·1년 뒤 수익률이 어땠는지를 같은 종목의 '아무 날이나 샀을 때'와 비교한다.

- 이평선 도달(매수 기준): 그날 저가 ≤ MA×1.01 이고 종가 ≥ MA×0.99, 5거래일 전 종가 > 그때 MA×1.01(위에서 내려옴).
  새로 닿은 날(전날은 닿지 않음)만 사건으로 센다. 20·60·180일선 각각.
- 분할 매수 단계: 52주 고점(최근 365일 고가 최댓값) 대비 하락률이 10·20·30% 이상이면 1·2·3단계, 또는 저가가 120일선×1.01 이하면
  1단계, 200일선×1.01 이하면 2단계. 둘 중 높은 단계, 최대 3. 단계가 오른 날을 사건으로 센다.
- 같은 종목에서 같은 신호가 20거래일 안에 다시 켜지면 하나로 본다(몰려 켜지는 날이 결과를 부풀리지 않게).
- 기간은 달력 기준(30·91·182·365일 뒤 첫 거래일 종가). 3개월 안 최저점은 그 사이 저가의 최솟값.
"""
import json, sys, pathlib, statistics as stt, bisect
from datetime import date, timedelta

data_dir = pathlib.Path(sys.argv[1])
T = 0.01
MA_W = [20, 60, 180]
DIP_STEPS = [10, 20, 30]
DIP_MA = [120, 200]
HZ = [("1개월", 30), ("3개월", 91), ("6개월", 182), ("1년", 365)]
COOL = 20
GROUP = {"^IXIC": "지수", "^GSPC": "지수", "^KS11": "지수", "QLD": "레버리지 ETF", "BTC-KRW": "코인", "ETH-USD": "코인"}


def sma(c, w):
    out = [None] * len(c); s = 0.0
    for i, v in enumerate(c):
        s += v
        if i >= w: s -= c[i - w]
        if i >= w - 1: out[i] = s / w
    return out


def load(p):
    j = json.load(open(p, encoding="utf-8"))
    rows = j["rows"]
    d = [date.fromisoformat(r[0]) for r in rows]
    return j["symbol"], j["name"], d, [r[1] for r in rows], [r[2] for r in rows], [r[3] for r in rows]


def fwd_index(d, i, days):
    target = d[i] + timedelta(days=days)
    lo, hi = i + 1, len(d)
    while lo < hi:
        mid = (lo + hi) // 2
        if d[mid] < target: lo = mid + 1
        else: hi = mid
    return lo if lo < len(d) else None


results = {}
events_all = []
base_all = {}
for p in sorted(x for x in data_dir.glob("*.json") if x.name != "bt_result.json"):
    sym, name, d, c, l, h = load(p)
    n = len(c)
    mas = {w: sma(c, w) for w in set(MA_W + DIP_MA)}
    # 52주 고점: 최근 365일 고가 최댓값(대시보드는 야후 meta.fiftyTwoWeekHigh = 52주 장중 고가)
    hi52 = [None] * n
    dq = []
    for i in range(n):
        while dq and h[dq[-1]] <= h[i]: dq.pop()
        dq.append(i)
        while d[dq[0]] < d[i] - timedelta(days=365): dq.pop(0)
        hi52[i] = h[dq[0]]
    start = 200  # 200일선이 생기는 날부터

    def touch(w, i):
        m = mas[w][i]
        return m is not None and l[i] <= m * (1 + T) and c[i] >= m * (1 - T)

    level = [0] * n; dd = [0.0] * n; tierDd = [0] * n; tierMa = [0] * n
    for i in range(n):
        dd[i] = max(0.0, (1 - c[i] / hi52[i]) * 100)
        tierDd[i] = sum(1 for s_ in DIP_STEPS if dd[i] >= s_)
        tm = 0
        for k, w in enumerate(DIP_MA):
            m = mas[w][i]
            if m is not None and l[i] <= m * (1 + T): tm = k + 1
        tierMa[i] = tm
        level[i] = min(3, max(tierDd[i], tm))

    # 수익률 계산
    def outcome(i):
        o = {}
        for lab, days in HZ:
            j = fwd_index(d, i, days)
            o[lab] = (c[j] / c[i] - 1) * 100 if j is not None else None
        j3 = fwd_index(d, i, 91)
        if j3 is not None:
            o["mae3"] = (min(l[i + 1:j3 + 1]) / c[i] - 1) * 100
        else:
            o["mae3"] = None
        return o

    base = [outcome(i) for i in range(start, n)]
    base_stats = {}
    for lab, _ in HZ:
        v = [b[lab] for b in base if b[lab] is not None]
        base_stats[lab] = {"mean": stt.mean(v), "median": stt.median(v), "hit": sum(x > 0 for x in v) / len(v) * 100, "n": len(v)} if v else None
    base_all[sym] = base_stats
    # 백분위 비교용: 같은 종목 모든 날의 수익률 분포(정렬)
    base_sorted = {lab: sorted(b[lab] for b in base if b[lab] is not None) for lab, _ in HZ}

    last_ev = {}
    raw_count = {}

    def add_event(kind, i, extra=None):
        raw_count[kind] = raw_count.get(kind, 0) + 1
        if kind in last_ev and i - last_ev[kind] <= COOL:
            last_ev[kind] = i
            return
        last_ev[kind] = i
        ev = {"sym": sym, "name": name, "group": GROUP.get(sym, "개별 종목"), "kind": kind, "date": d[i].isoformat(),
              "close": c[i], "dd": dd[i]}
        ev.update(outcome(i))
        for lab, _ in HZ:
            arr = base_sorted[lab]
            if ev.get(lab) is not None and arr:
                ev["pct_" + lab] = (bisect.bisect_left(arr, ev[lab]) + bisect.bisect_right(arr, ev[lab])) / 2 / len(arr) * 100
                ev["bhit_" + lab] = base_stats[lab]["hit"]
        # 그날의 추세: 200일선이 20거래일 전보다 높은가(장기 상승), 20>60>180 정배열인가
        m200, m200p = mas[200][i], mas[200][i - 20]
        ev["up200"] = bool(m200 and m200p and m200 > m200p)
        ev["align"] = bool(mas[20][i] and mas[60][i] and mas[180][i] and mas[20][i] > mas[60][i] > mas[180][i])
        ev["above200"] = bool(m200 and c[i] > m200)
        if extra: ev.update(extra)
        events_all.append(ev)

    for i in range(start, n):
        for w in MA_W:
            if touch(w, i) and not touch(w, i - 1):
                m5 = mas[w][i - 5]
                if m5 is not None and c[i - 5] > m5 * (1 + T):
                    add_event(f"이평선 {w}일선", i)
        if level[i] > level[i - 1] and level[i] >= 1:
            why = "고점 대비" if tierDd[i] >= level[i] else "이평선"
            add_event(f"분할 {level[i]}단계", i, {"why": why})

    days = n - start
    results[sym] = {
        "name": name, "group": GROUP.get(sym, "개별 종목"), "from": d[start].isoformat(), "to": d[-1].isoformat(), "days": days,
        "pctLv1": sum(1 for i in range(start, n) if level[i] >= 1) / days * 100,
        "pctLv2": sum(1 for i in range(start, n) if level[i] >= 2) / days * 100,
        "pctLv3": sum(1 for i in range(start, n) if level[i] >= 3) / days * 100,
        "pctMaTier2": sum(1 for i in range(start, n) if tierMa[i] >= 2) / days * 100,
        "raw": raw_count, "base": base_stats, "levelNow": level[-1], "ddNow": dd[-1],
    }

json.dump({"results": results, "events": events_all}, open(data_dir / "bt_result.json", "w", encoding="utf-8"), ensure_ascii=False, indent=0)
print("종목", len(results), "사건", len(events_all))
