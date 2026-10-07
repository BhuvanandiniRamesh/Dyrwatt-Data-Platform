"""Generate DEMO reservoir landing files (NVE Magasinstatistikk shape) for offline testing.

Precipitation is not simulated: ingest.py --only precip fetches the real seNorge data.
Real reservoir data: python ingest.py --only nve (overwrites data/landing/nve/ and
removes the _DEMO marker).

The last reservoir week (2026 week 39) and the capacities are the real NVE
values published 2026-09-30; everything before is simulated.
"""
import json
import math
import random
from datetime import date, timedelta
from pathlib import Path

random.seed(42)
ROOT = Path(__file__).resolve().parents[1]
LAND = ROOT / "data" / "landing"
START, END_RES, END_PRE = date(2018, 1, 1), date(2026, 9, 27), date(2026, 10, 6)

# area: (capacity TWh, seasonal min %, seasonal max %, station, annual precip mm, real 2026 W38/W39 %)
AREAS = {
    1: (6.0032635, 32, 88, "SN18700", 840, 74.310964, 75.0023),
    2: (34.04359, 36, 88, "SN39040", 1400, 49.801803, 51.145524),
    3: (8.920932, 26, 89, "SN68860", 900, 68.07045, 71.528834),
    4: (21.079208, 38, 91, "SN90450", 1030, 90.168935, 89.774907),
    5: (17.390587, 30, 90, "SN50540", 2500, 68.80356, 70.734537),
}
# monthly precipitation share (sums ~1); west coast is autumn/winter heavy, Oslo summer/autumn
SHAPE = {
    "east": [.06, .05, .05, .05, .07, .08, .10, .11, .10, .12, .11, .10],
    "west": [.10, .08, .08, .05, .05, .05, .06, .08, .11, .12, .11, .11],
}
STATIONS = {
    "SN18700": ("OSLO - BLINDERN", "Blindern", 94, [10.72, 59.9423], "OSLO", "OSLO", "east"),
    "SN39040": ("KRISTIANSAND - KJEVIK", "Kjevik", 12, [8.0767, 58.2], "AGDER", "KRISTIANSAND", "west"),
    "SN68860": ("TRONDHEIM - VOLL", "Voll", 127, [10.4533, 63.4107], "TRØNDELAG", "TRONDHEIM", "east"),
    "SN90450": ("TROMSØ", "Tromsø", 100, [18.9368, 69.6537], "TROMS", "TROMSØ", "west"),
    "SN50540": ("BERGEN - FLORIDA", "Florida", 12, [5.3327, 60.383], "VESTLAND", "BERGEN", "west"),
}


def seasonal(week, lo, hi):
    """Median filling curve: min around week 17, max around week 40."""
    w = (week - 17) % 52
    frac = (1 - math.cos(math.pi * w / 23)) / 2 if w <= 23 else (1 + math.cos(math.pi * (w - 23) / 29)) / 2
    return lo + (hi - lo) * frac


def precipitation():
    daily = {}
    for sid, (*_, kind) in STATIONS.items():
        annual = next(a[4] for a in AREAS.values() if a[3] == sid)
        d, series, yearly = START, {}, {}
        while d <= END_PRE:
            if d.year not in yearly:
                yearly[d.year] = random.gauss(1, 0.12)
            month_mm = annual * SHAPE[kind][d.month - 1] * yearly[d.year]
            p_wet = 0.45 if kind == "east" else 0.6
            mean_wet = month_mm / (30.4 * p_wet)
            v = round(random.gammavariate(0.8, mean_wet / 0.8), 1) if random.random() < p_wet else 0.0
            if random.random() > 0.01:  # ~1 % missing days, like real stations
                series[d] = v
            d += timedelta(days=1)
        daily[sid] = series
    return daily


def write_nve(daily):
    out = LAND / "nve"
    out.mkdir(parents=True, exist_ok=True)
    first_sunday = START + timedelta(days=(6 - START.weekday()) % 7)
    weeks = []
    d = first_sunday
    while d <= END_RES:
        weeks.append(d)
        d += timedelta(days=7)

    fill = {}
    for nr, (cap, lo, hi, sid, annual, real_prev, real_last) in AREAS.items():
        series = daily[sid]
        wk_mean = annual / 52
        anom, vals = 0.0, []
        for w in weeks:
            p = sum(series.get(w - timedelta(days=i), 0) for i in range(7))
            anom = 0.96 * anom + 0.025 * (p - wk_mean) * (40 / wk_mean) + random.gauss(0, 0.35)
            vals.append(seasonal(w.isocalendar()[1], lo, hi) + anom)
        # Blend 2026 towards the real published values for week 38-39
        i26 = next(i for i, w in enumerate(weeks) if w.year == 2026)
        n = len(weeks) - 2 - i26
        delta = real_prev - vals[-2]
        for k, i in enumerate(range(i26, len(weeks) - 1)):
            vals[i] += delta * (k / n) ** 1.5
        vals[-2], vals[-1] = real_prev, real_last
        fill[nr] = [min(97.5, max(5.0, v)) / 100 for v in vals]

    rows = []
    for i, w in enumerate(weeks):
        y, wk, _ = w.isocalendar()
        tot_cap = sum(a[0] for a in AREAS.values())
        nat = sum(fill[nr][i] * AREAS[nr][0] for nr in AREAS) / tot_cap
        nat_prev = sum(fill[nr][i - 1] * AREAS[nr][0] for nr in AREAS) / tot_cap if i else None
        for typ, nr, f, fp, cap in [("EL", nr, fill[nr][i], fill[nr][i - 1] if i else None, AREAS[nr][0])
                                    for nr in AREAS] + [("NO", 0, nat, nat_prev, tot_cap)]:
            rows.append({"dato_Id": w.isoformat(), "omrType": typ, "omrnr": nr, "iso_aar": y, "iso_uke": wk,
                         "fyllingsgrad": round(f, 6), "kapasitet_TWh": cap, "fylling_TWh": round(f * cap, 6),
                         "neste_Publiseringsdato": "2026-10-07T13:00:00",
                         "fyllingsgrad_forrige_uke": round(fp, 6) if fp is not None else None,
                         "endring_fyllingsgrad": round(f - fp, 6) if fp is not None else None})
    (out / "magasin.json").write_text(json.dumps(rows), encoding="utf-8")

    mmm = []
    for nr, (cap, lo, hi, *_) in list(AREAS.items()) + [(0, (0, 33, 89))]:
        for wk in range(1, 54):
            med = seasonal(min(wk, 52), lo, hi)
            vals = (max(2, med - 17), med, min(99, med + 11))
            mmm.append({"omrType": "NO" if nr == 0 else "EL", "omrnr": nr, "iso_uke": wk,
                        "minFyllingsgrad": vals[0] / 100, "minFyllingTWH": None,
                        "medianFyllingsGrad": vals[1] / 100, "medianFylling_TWH": None,
                        "maxFyllingsgrad": vals[2] / 100, "maxFyllingTWH": None})
    (out / "minmaxmedian.json").write_text(json.dumps(mmm), encoding="utf-8")

    # Real values from HentOmråder
    omr = [{"navn": f"NO {n}", "navn_langt": f"Elspotområde {n}", "beskrivelse": b, "omrType": "EL", "omrnr": n}
           for n, b in [
               (1, "Sørøst-Norge. Omfatter østlige del av Østlandet fra Buskerud og nordover (bortsett fra den del av Innlandet som ligger vest og nord for Vågåmo)."),
               (2, "Sørvest-Norge. Omfatter mesteparten av Vestfold, Telemark, Agder, Rogaland og sørlige del av Vestland."),
               (3, "Midt-Norge. Omfatter nordre og vestlige del av Vestland, den del av Innlandet som ligger vest og nord for Vågåmo, Møre og Romsdal og Trøndelag til Tunnsjødal."),
               (4, "Nord-Norge. Omfatter resten av Trøndelag og Nord-Norge."),
               (5, "Vest-Norge. Omfatter midtre del av Vestland opp til Sognefjorden og Indre Sogn, og vestlig del av Buskerud.")]]
    (out / "omrader.json").write_text(json.dumps(omr, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    daily = precipitation()
    write_nve(daily)
    (LAND / "_DEMO").write_text("Reservoir landing files are simulated demo data. Run: python ingest.py --only nve\n")
    print(f"Demo landing files written to {LAND}")
