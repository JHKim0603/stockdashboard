"""관심 종목 10년치 일봉(종가·저가·고가)을 야후에서 받아 bt_data/ 에 저장한다."""
import json, sys, time, urllib.request, urllib.parse, pathlib

out = pathlib.Path(sys.argv[1]); out.mkdir(exist_ok=True)
wl = json.load(open(pathlib.Path(__file__).resolve().parent.parent / "watchlist.json", encoding="utf-8"))
for w in wl:
    sym = w["Symbol"]
    url = "https://query1.finance.yahoo.com/v8/finance/chart/" + urllib.parse.quote(sym) + "?interval=1d&range=10y"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    for t in range(3):
        try:
            raw = urllib.request.urlopen(req, timeout=30).read()
            break
        except Exception as e:
            print(sym, "retry", e); time.sleep(3)
    r = json.loads(raw)["chart"]["result"][0]
    q = r["indicators"]["quote"][0]
    off = r["meta"].get("gmtoffset", 0)
    rows = []
    for ts, c, lo, hi in zip(r["timestamp"], q["close"], q["low"], q["high"]):
        if c is None:
            continue
        d = time.strftime("%Y-%m-%d", time.gmtime(ts + off))
        rows.append([d, c, lo if lo is not None else c, hi if hi is not None else c])
    # 같은 날짜가 두 번 오면(장중 값) 뒤의 것을 쓴다.
    dedup = {}
    for row in rows:
        dedup[row[0]] = row
    rows = [dedup[k] for k in sorted(dedup)]
    json.dump({"symbol": sym, "name": w.get("DisplayName", sym), "group": w.get("Group", ""), "rows": rows},
              open(out / (sym.replace("^", "_").replace("=", "_") + ".json"), "w", encoding="utf-8"))
    print(sym, len(rows), rows[0][0], rows[-1][0])
    time.sleep(0.6)
