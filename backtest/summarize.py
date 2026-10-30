import json, sys, statistics as stt
R = json.load(open(sys.argv[1], encoding="utf-8"))
res, ev = R["results"], R["events"]


def row(rows, lab):
    v = [x for x in rows if x.get(lab) is not None and x.get("pct_" + lab) is not None]
    if len(v) < 5: return None
    return {"n": len(v), "med": stt.median(x[lab] for x in v), "hit": sum(x[lab] > 0 for x in v) / len(v) * 100,
            "bhit": stt.mean(x["bhit_" + lab] for x in v), "pct": stt.mean(x["pct_" + lab] for x in v),
            "mae": stt.median(x["mae3"] for x in v if x.get("mae3") is not None)}


def table(title, rows):
    a, b = row(rows, "3개월"), row(rows, "1년")
    if not a: return
    s = f"{title:28} n={a['n']:4d} | 3개월 백분위 {a['pct']:4.0f} 오른비율 {a['hit']:3.0f}% (평소 {a['bhit']:3.0f}%) 중앙 {a['med']:+6.1f}% 최대하락 {a['mae']:+5.1f}%"
    if b: s += f" | 1년 백분위 {b['pct']:4.0f} 오른비율 {b['hit']:3.0f}% (평소 {b['bhit']:3.0f}%) 중앙 {b['med']:+6.1f}%"
    print(s)


kinds = ["이평선 20일선", "이평선 60일선", "이평선 180일선", "분할 1단계", "분할 2단계", "분할 3단계"]
for grp in ["전체", "지수", "개별 종목", "레버리지 ETF", "코인"]:
    print("\n=====", grp)
    rg = ev if grp == "전체" else [x for x in ev if x["group"] == grp]
    for k in kinds:
        table(k, [x for x in rg if x["kind"] == k])

print("\n===== 추세별 (전체, 코인 제외)")
nc = [x for x in ev if x["group"] != "코인"]
for k in kinds:
    rr = [x for x in nc if x["kind"] == k]
    table(k + " / 200일선 오름", [x for x in rr if x["up200"]])
    table(k + " / 200일선 내림", [x for x in rr if not x["up200"]])
print()
for k in ["이평선 20일선", "이평선 60일선", "이평선 180일선"]:
    rr = [x for x in nc if x["kind"] == k]
    table(k + " / 정배열", [x for x in rr if x["align"]])
    table(k + " / 정배열 아님", [x for x in rr if not x["align"]])
print()
for k in ["분할 1단계", "분할 2단계", "분할 3단계"]:
    rr = [x for x in nc if x["kind"] == k]
    table(k + " / 고점대비로 켜짐", [x for x in rr if x.get("why") == "고점 대비"])
    table(k + " / 이평선으로 켜짐", [x for x in rr if x.get("why") == "이평선"])

print("\n===== 추세별 (코인)")
cc = [x for x in ev if x["group"] == "코인"]
for k in kinds:
    rr = [x for x in cc if x["kind"] == k]
    table(k + " / 200일선 오름", [x for x in rr if x["up200"]])
    table(k + " / 200일선 내림", [x for x in rr if not x["up200"]])

print("\n===== 종목별 분할 3단계 / 이평선 전체 (3개월·1년 백분위, 건수)")
for s, r in res.items():
    out = f"{r['name'][:8]:10}"
    for label, sel in [("3단계", lambda x: x["kind"] == "분할 3단계"), ("이평선", lambda x: x["kind"].startswith("이평선"))]:
        rr = [x for x in ev if x["sym"] == s and sel(x)]
        p3 = [x["pct_3개월"] for x in rr if x.get("pct_3개월") is not None]
        p12 = [x["pct_1년"] for x in rr if x.get("pct_1년") is not None]
        out += f" | {label} 3개월 {stt.mean(p3):4.0f}({len(p3):3d}) 1년 {stt.mean(p12) if p12 else float('nan'):4.0f}({len(p12):3d})" if p3 else f" | {label}   –"
    print(out)
