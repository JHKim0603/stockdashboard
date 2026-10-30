"""매수 기준 개선안 비교. backtest.py 와 같은 데이터·같은 평가(같은 종목 모든 날 대비 백분위)로 규칙만 바꿔 본다."""
import json, sys, pathlib, statistics as stt, bisect
from datetime import date, timedelta

data_dir = pathlib.Path(sys.argv[1])
T = 0.01
HZ = [("3개월", 91), ("1년", 365)]
COOL = 20
GROUP = {"^IXIC": "지수", "^GSPC": "지수", "^KS11": "지수", "QLD": "레버리지", "BTC-KRW": "코인", "ETH-USD": "코인"}


def sma(c, w):
    out = [None] * len(c); s = 0.0
    for i, v in enumerate(c):
        s += v
        if i >= w: s -= c[i - w]
        if i >= w - 1: out[i] = s / w
    return out


def fwd(d, i, days):
    t = d[i] + timedelta(days=days)
    j = bisect.bisect_left(d, t, i + 1)
    return j if j < len(d) else None


series = []
for p in sorted(x for x in data_dir.glob("*.json") if x.name != "bt_result.json"):
    j = json.load(open(p, encoding="utf-8"))
    rows = j["rows"]
    d = [date.fromisoformat(r[0]) for r in rows]
    c = [r[1] for r in rows]; l = [r[2] for r in rows]; h = [r[3] for r in rows]
    n = len(c)
    mas = {w: sma(c, w) for w in (20, 60, 120, 180, 200)}
    hi52 = [None] * n; dq = []
    for i in range(n):
        while dq and h[dq[-1]] <= h[i]: dq.pop()
        dq.append(i)
        while d[dq[0]] < d[i] - timedelta(days=365): dq.pop(0)
        hi52[i] = h[dq[0]]
    dd = [max(0.0, (1 - c[i] / hi52[i]) * 100) for i in range(n)]
    ret = {}
    for lab, days in HZ:
        r = [None] * n
        for i in range(n):
            k = fwd(d, i, days)
            if k is not None: r[i] = (c[k] / c[i] - 1) * 100
        ret[lab] = r
    srt = {lab: sorted(x for x in ret[lab][200:] if x is not None) for lab, _ in HZ}
    series.append(dict(sym=j["symbol"], name=j["name"], grp=GROUP.get(j["symbol"], "개별"), d=d, c=c, l=l, mas=mas, dd=dd, ret=ret, srt=srt, n=n))


def pct(s, lab, i):
    v = s["ret"][lab][i]
    if v is None: return None
    a = s["srt"][lab]
    return (bisect.bisect_left(a, v) + bisect.bisect_right(a, v)) / 2 / len(a) * 100


def run(name, steps_of, ma_mode):
    """steps_of(sym)->[s1,s2,s3]; ma_mode: 'below'(현재: 저가가 MA×1.01 이하), 'touch'(종가도 MA×0.99 이상), 'none'(이평선 단계 없음)"""
    out = {}
    for s in series:
        steps = steps_of(s)
        lv = [0] * s["n"]
        for i in range(s["n"]):
            t1 = sum(1 for x in steps if s["dd"][i] >= x)
            tm = 0
            if ma_mode != "none":
                for k, w in enumerate((120, 200)):
                    m = s["mas"][w][i]
                    if m is None: continue
                    ok = s["l"][i] <= m * (1 + T) and (ma_mode == "below" or s["c"][i] >= m * (1 - T))
                    if ok: tm = k + 1
            lv[i] = min(3, max(t1, tm))
        days = s["n"] - 200
        g = s["grp"]
        o = out.setdefault(g, {"days": 0, "on1": 0, "on3": 0, "ev": {1: [], 2: [], 3: []}})
        o["days"] += days
        o["on1"] += sum(1 for i in range(200, s["n"]) if lv[i] >= 1)
        o["on3"] += sum(1 for i in range(200, s["n"]) if lv[i] >= 3)
        last = {}
        for i in range(200, s["n"]):
            if lv[i] > lv[i - 1] and lv[i] >= 1:
                k = lv[i]
                if k in last and i - last[k] <= COOL: last[k] = i; continue
                last[k] = i
                o["ev"][k].append((pct(s, "3개월", i), pct(s, "1년", i), s["ret"]["1년"][i]))
    print(f"\n### {name}")
    for g in ["지수", "개별", "레버리지", "코인"]:
        o = out.get(g)
        if not o: continue
        parts = [f"{g:4} 켜진 날 1단계↑ {o['on1']/o['days']*100:3.0f}% 3단계 {o['on3']/o['days']*100:3.0f}%"]
        for k in (1, 2, 3):
            e = o["ev"][k]
            p3 = [x[0] for x in e if x[0] is not None]; p12 = [x[1] for x in e if x[1] is not None]
            hit = [x[2] > 0 for x in e if x[2] is not None]
            if p3:
                parts.append(f"{k}단계 {len(e):3d}건 3개월 {stt.mean(p3):3.0f} 1년 {stt.mean(p12) if p12 else 0:3.0f} 1년 오름 {sum(hit)/len(hit)*100 if hit else 0:3.0f}%")
        print(" | ".join(parts))


base = lambda s: [10, 20, 30]
wide = lambda s: [20, 40, 60] if s["grp"] == "코인" else [10, 20, 30]
run("현재 규칙(고점 −10·−20·−30%, 120·200일선 아래면 켜짐)", base, "below")
run("안 A: 120·200일선은 '닿았을 때'만(종가가 선 −1% 안)", base, "touch")
run("안 B: 이평선 단계 없이 고점 대비 하락만", base, "none")
run("안 C: 안 A + 코인은 −20·−40·−60%", wide, "touch")

# 이평선 도달(20·60·180)을 고점 대비 하락과 함께 볼 때
print("\n### 이평선 도달 매수 기준을 고점 대비 하락과 함께 볼 때(3개월·1년 백분위, 건수)")
for lo, hi_ in [(0, 10), (10, 20), (20, 100)]:
    for g in ["지수·개별·레버리지", "코인"]:
        p3s, p12s = [], []
        for s in series:
            if (s["grp"] == "코인") != (g == "코인"): continue
            last = {}
            for w in (20, 60, 180):
                m = s["mas"][w]
                for i in range(200, s["n"]):
                    tc = lambda k: m[k] is not None and s["l"][k] <= m[k] * (1 + T) and s["c"][k] >= m[k] * (1 - T)
                    if tc(i) and not tc(i - 1) and m[i - 5] is not None and s["c"][i - 5] > m[i - 5] * (1 + T) and lo <= s["dd"][i] < hi_:
                        if w in last and i - last[w] <= COOL: last[w] = i; continue
                        last[w] = i
                        a, b = pct(s, "3개월", i), pct(s, "1년", i)
                        if a is not None: p3s.append(a)
                        if b is not None: p12s.append(b)
        if p3s:
            print(f"고점 대비 {lo}~{hi_}% 내려온 상태 / {g}: {len(p3s)}건, 3개월 {stt.mean(p3s):.0f}, 1년 {stt.mean(p12s) if p12s else 0:.0f}")
