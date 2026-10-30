"""StockDashboard 매수 기준 과거 검증.

대시보드(Update-StockDashboard.ps1)의 Get-MaLevels·Get-DipSignal 규칙을 buy-rules.json·watchlist.json 설정 그대로 10년치 일봉에
매일 적용하고, 신호가 새로 켜진 날 종가에 샀다면 3개월·1년 뒤 결과가 어땠는지를 같은 종목의 '아무 날이나 샀을 때'와 비교한다.
결과 중 분야별 성적은 저장소 맨 위 backtest-stats.json 으로 남기고, 대시보드가 신호 옆에 '과거 10년 성적'으로 보여 준다.

- 이평선 도달: 그날 저가 ≤ MA×(1+touch) 이고 종가 ≥ MA×(1−touch), 5거래일 전 종가 > 그때 MA×(1+touch)(위에서 내려옴).
  새로 닿은 날만 센다. 52주 고점보다 maMinDrawdownPct% 넘게 내려온 상태면 '이평선 매수 기준', 아니면 '이평선 참고'.
- 분할 매수 단계: 52주 고점(최근 365일 고가 최댓값) 대비 하락률이 단계 기준 이상이거나, 저가가 단계 이평선×(1+touch) 이하.
  둘 중 높은 단계(최대 3). 종목별 DipSteps·DipMA, 지수는 dip.indexMaSteps. 단계가 오른 날을 사건으로 센다.
- 같은 종목에서 같은 신호가 20거래일 안에 다시 켜지면 하나로 본다.
- 기간은 달력 기준(91·365일 뒤 첫 거래일 종가). 비교는 같은 종목 모든 날 수익률 분포 안의 백분위(50 = 아무 날이나).
"""
import json, sys, pathlib, statistics as stt, bisect
from datetime import date, timedelta

root = pathlib.Path(__file__).resolve().parent.parent
data_dir = pathlib.Path(sys.argv[1])
rules = json.load(open(root / "buy-rules.json", encoding="utf-8"))
watch = {w["Symbol"]: w for w in json.load(open(root / "watchlist.json", encoding="utf-8"))}
T = float(rules.get("touchPct", 1.0)) / 100
MA_W = [int(x) for x in rules.get("maWindows", [20, 60, 180])]
MIN_DD = float(rules.get("maMinDrawdownPct", 0))
DIP = rules.get("dip", {})
DIP_STEPS = [float(x) for x in DIP.get("drawdownSteps", [10, 20, 30])]
DIP_MA = [int(x) for x in DIP.get("maSteps", [120, 200])]
INDEX_MA = [int(x) for x in DIP.get("indexMaSteps", DIP_MA)]
HZ = [("1개월", 30), ("3개월", 91), ("6개월", 182), ("1년", 365)]
COOL = 20


def stat_group(sym):
    # 대시보드(PS)의 분야 구분과 같아야 한다: 지수, 코인, 레버리지 ETF, 개별 종목
    w = watch.get(sym, {})
    if sym.startswith("^"): return "지수"
    if sym.endswith("-USD") or sym.endswith("-KRW") or w.get("Group") == "코인": return "코인"
    if w.get("Group") == "레버리지 ETF": return "레버리지 ETF"
    return "개별 종목"


def sma(c, w):
    out = [None] * len(c); s = 0.0
    for i, v in enumerate(c):
        s += v
        if i >= w: s -= c[i - w]
        if i >= w - 1: out[i] = s / w
    return out


def fwd_index(d, i, days):
    j = bisect.bisect_left(d, d[i] + timedelta(days=days), i + 1)
    return j if j < len(d) else None


results, events_all = {}, []
for p in sorted(x for x in data_dir.glob("*.json") if x.name != "bt_result.json"):
    j = json.load(open(p, encoding="utf-8"))
    sym, name, rows = j["symbol"], j["name"], j["rows"]
    if sym not in watch: continue
    w_cfg = watch[sym]
    grp = stat_group(sym)
    steps = sorted(float(x) for x in w_cfg["DipSteps"]) if w_cfg.get("DipSteps") else DIP_STEPS
    ma_steps = [int(x) for x in w_cfg["DipMA"]] if "DipMA" in w_cfg else (INDEX_MA if grp == "지수" else DIP_MA)
    ma_windows = [int(x) for x in w_cfg["BuyMA"]] if w_cfg.get("BuyMA") else MA_W
    d = [date.fromisoformat(r[0]) for r in rows]
    c = [r[1] for r in rows]; l = [r[2] for r in rows]; h = [r[3] for r in rows]
    n = len(c)
    mas = {w: sma(c, w) for w in set(ma_windows + ma_steps + [200])}
    hi52 = [None] * n; dq = []
    for i in range(n):
        while dq and h[dq[-1]] <= h[i]: dq.pop()
        dq.append(i)
        while d[dq[0]] < d[i] - timedelta(days=365): dq.pop(0)
        hi52[i] = h[dq[0]]
    start = 200
    dd = [max(0.0, (1 - c[i] / hi52[i]) * 100) for i in range(n)]
    tier_dd = [sum(1 for s_ in steps if dd[i] >= s_) for i in range(n)]
    tier_ma = [0] * n
    for i in range(n):
        for k, w in enumerate(ma_steps):
            m = mas[w][i]
            if m is not None and l[i] <= m * (1 + T): tier_ma[i] = k + 1
    level = [min(3, max(tier_dd[i], tier_ma[i])) for i in range(n)]

    def outcome(i):
        o = {}
        for lab, days in HZ:
            k = fwd_index(d, i, days)
            o[lab] = (c[k] / c[i] - 1) * 100 if k is not None else None
        k3 = fwd_index(d, i, 91)
        o["mae3"] = (min(l[i + 1:k3 + 1]) / c[i] - 1) * 100 if k3 is not None else None
        return o

    base = [outcome(i) for i in range(start, n)]
    base_stats, base_sorted = {}, {}
    for lab, _ in HZ:
        v = [b[lab] for b in base if b[lab] is not None]
        base_sorted[lab] = sorted(v)
        base_stats[lab] = {"mean": stt.mean(v), "median": stt.median(v), "hit": sum(x > 0 for x in v) / len(v) * 100, "n": len(v)} if v else None

    last_ev = {}

    def add_event(kind, i, extra):
        if kind in last_ev and i - last_ev[kind] <= COOL:
            last_ev[kind] = i
            return
        last_ev[kind] = i
        ev = {"sym": sym, "name": name, "group": grp, "kind": kind, "date": d[i].isoformat(), "close": c[i], "dd": dd[i]}
        ev.update(outcome(i))
        for lab, _ in HZ:
            arr = base_sorted[lab]
            if ev.get(lab) is not None and arr:
                ev["pct_" + lab] = (bisect.bisect_left(arr, ev[lab]) + bisect.bisect_right(arr, ev[lab])) / 2 / len(arr) * 100
                ev["bhit_" + lab] = base_stats[lab]["hit"]
        m200, m200p = mas[200][i], mas[200][i - 20]
        ev["up200"] = bool(m200 and m200p and m200 > m200p)
        ev.update(extra)
        events_all.append(ev)

    def touch(w, i):
        m = mas[w][i]
        return m is not None and l[i] <= m * (1 + T) and c[i] >= m * (1 - T)

    for i in range(start, n):
        for w in ma_windows:
            if touch(w, i) and not touch(w, i - 1):
                m5 = mas[w][i - 5]
                if m5 is not None and c[i - 5] > m5 * (1 + T):
                    add_event(f"이평선 {w}일선", i, {"buy": dd[i] >= MIN_DD})
        if level[i] > level[i - 1] and level[i] >= 1:
            add_event(f"분할 {level[i]}단계", i, {"why": "고점 대비" if tier_dd[i] >= level[i] else "이평선"})

    days = n - start
    results[sym] = {
        "name": name, "group": grp, "from": d[start].isoformat(), "to": d[-1].isoformat(), "days": days,
        "steps": steps, "maSteps": ma_steps,
        "pctLv1": sum(1 for i in range(start, n) if level[i] >= 1) / days * 100,
        "pctLv2": sum(1 for i in range(start, n) if level[i] >= 2) / days * 100,
        "pctLv3": sum(1 for i in range(start, n) if level[i] >= 3) / days * 100,
        "base": base_stats, "levelNow": level[-1], "ddNow": dd[-1],
    }

json.dump({"results": results, "events": events_all}, open(data_dir / "bt_result.json", "w", encoding="utf-8"), ensure_ascii=False, indent=0)


# ---- 대시보드용 분야별 성적(backtest-stats.json) ----------------------------------------------------
def agg(rows):
    y = [x for x in rows if x.get("1년") is not None and x.get("pct_1년") is not None]
    q = [x for x in rows if x.get("3개월") is not None and x.get("pct_3개월") is not None]
    if not y: return None
    return {
        "n": len(y), "up": sum(1 for x in y if x["1년"] > 0),
        "hit": round(sum(1 for x in y if x["1년"] > 0) / len(y) * 100),
        "baseHit": round(stt.mean(x["bhit_1년"] for x in y)),
        "pct1y": round(stt.mean(x["pct_1년"] for x in y)),
        "pct3m": round(stt.mean(x["pct_3개월"] for x in q)) if q else None,
        "mae3": round(stt.median(x["mae3"] for x in q if x.get("mae3") is not None), 1) if q else None,
    }


stats = {}
for grp in ["지수", "개별 종목", "레버리지 ETF", "코인"]:
    g = [x for x in events_all if x["group"] == grp]
    if not g: continue
    s = {}
    for k in (1, 2, 3):
        a = agg([x for x in g if x["kind"] == f"분할 {k}단계"])
        if a: s[f"분할 {k}단계"] = a
    a = agg([x for x in g if x["kind"].startswith("이평선") and x.get("buy")])
    if a: s["이평선 매수 기준"] = a
    a = agg([x for x in g if x["kind"].startswith("이평선") and not x.get("buy")])
    if a: s["이평선 참고"] = a
    stats[grp] = s
froms = sorted(r["from"] for r in results.values())
out = {
    "//": "backtest/backtest.py 가 만든 과거 검증 성적입니다. 대시보드가 신호 옆 '과거 10년 성적'에 씁니다. 규칙(buy-rules.json, watchlist.json)을 바꾸면 다시 만듭니다.",
    "generated": max(r["to"] for r in results.values()),
    "since": froms[len(froms) // 2],
    "groups": stats,
}
json.dump(out, open(root / "backtest-stats.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("종목", len(results), "사건", len(events_all))
for g, s in stats.items():
    print(g, {k: (v["n"], v["hit"], v["baseHit"], v["pct1y"]) for k, v in s.items()})
