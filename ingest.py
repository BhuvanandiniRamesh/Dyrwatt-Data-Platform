"""Extract step: pull raw JSON from the APIs into data/landing/.

Python only extracts and lands the API responses untouched. All cleaning,
typing and modelling happens in SQL (see sql/).

Sources
  nve     NVE Magasinstatistikk  - weekly reservoir filling + historic min/median/max (open)
  precip  NVE GridTimeSeries     - seNorge daily precipitation 'rr' per point (open, no key)
  frost   MET Frost (optional)   - station precipitation; needs FROST_CLIENT_ID

Usage:
    python ingest.py                  # nve + precip (+ frost if FROST_CLIENT_ID is set)
    python ingest.py --only precip
    python ingest.py --force          # re-fetch closed years as well
"""
import argparse
import csv
import json
import time
from datetime import date

import requests

import config as cfg


def _get(url, params=None, auth=None, retries=3):
    for attempt in range(1, retries + 1):
        try:
            r = requests.get(url, params=params, auth=auth, timeout=60)
            if r.status_code == 404 and "frost" in url:
                return None  # Frost: no data for this station/period
            r.raise_for_status()
            return r.json()
        except requests.RequestException as e:
            if attempt == retries:
                raise
            wait = 2 ** attempt
            print(f"  retry {attempt}/{retries} in {wait}s ({e})")
            time.sleep(wait)


def _write(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")


def _years():
    return range(cfg.START_YEAR, cfg.END_YEAR + 1)


def _skip(path, year, force):
    """Incremental load: closed years are fetched once, the current year every run."""
    return path.exists() and year < date.today().year and not force


# ------------------------------------------------------------------ NVE reservoirs
def ingest_nve():
    """Full refresh: the reservoir datasets are small (~20k rows) and NVE revises history."""
    out = cfg.LANDING / "nve"
    for name, endpoint in cfg.NVE_ENDPOINTS.items():
        data = _get(f"{cfg.NVE_BASE}/{endpoint}")
        _write(out / f"{name}.json", data)
        print(f"NVE {endpoint}: {len(data)} rows -> {name}.json")
    (cfg.LANDING / "_DEMO").unlink(missing_ok=True)  # reservoir data is real from here on


# ------------------------------------------------- NVE seNorge precipitation (GTS)
def ingest_precip(force=False):
    """One call per point and year: /GridTimeSeries/{x}/{y}/{start}/{end}/rr.json
    x/y are UTM33 (EPSG:25833) coordinates from sql/seeds/precip_points.csv."""
    out = cfg.LANDING / "nve_gts"
    with open(cfg.SQL_DIR / "seeds" / "precip_points.csv", encoding="utf-8") as f:
        points = list(csv.DictReader(f))
    today = date.today()
    for p in points:
        for year in _years():
            path = out / f"{p['point_id']}_{year}.json"
            if _skip(path, year, force):
                continue
            end = f"{year}-12-31" if year < today.year else today.isoformat()
            url = f"{cfg.GTS_BASE}/{p['utm33_x']}/{p['utm33_y']}/{year}-01-01/{end}/{cfg.GTS_THEME}.json"
            data = _get(url)
            _write(path, data)
            print(f"seNorge {p['point_id']} {year}: {len(data['Data'])} days")
            time.sleep(0.2)


# ------------------------------------------------------------- MET Frost (optional)
def ingest_frost(force=False):
    auth = (cfg.FROST_CLIENT_ID, "")
    out = cfg.LANDING / "frost"
    src = _get(f"{cfg.FROST_BASE}/sources/v0.jsonld",
               params={"ids": ",".join(cfg.STATIONS)}, auth=auth)
    _write(out / "sources.json", src["data"])
    print(f"Frost sources: {len(src['data'])} stations")
    today = date.today()
    for station in cfg.STATIONS:
        for year in _years():
            path = out / "observations" / f"{station}_{year}.json"
            if _skip(path, year, force):
                continue
            end = f"{year + 1}-01-01" if year < today.year else today.isoformat()
            resp = _get(f"{cfg.FROST_BASE}/observations/v0.jsonld", auth=auth, params={
                "sources": station,
                "referencetime": f"{year}-01-01/{end}",
                "elements": cfg.FROST_ELEMENT,
                "timeoffsets": "PT6H",
            })
            _write(path, resp["data"] if resp else [])
            print(f"Frost {station} {year}: {len(resp['data']) if resp else 0} days")
            time.sleep(0.2)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=["nve", "precip", "frost"])
    ap.add_argument("--force", action="store_true", help="re-fetch closed years")
    a = ap.parse_args()
    if a.only in (None, "nve"):
        ingest_nve()
    if a.only in (None, "precip"):
        ingest_precip(force=a.force)
    if a.only == "frost" or (a.only is None and cfg.FROST_CLIENT_ID):
        if not cfg.FROST_CLIENT_ID:
            raise SystemExit("Set FROST_CLIENT_ID (free at https://frost.met.no/auth/requestCredentials.html)")
        ingest_frost(force=a.force)
