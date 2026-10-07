"""Shared configuration for the DyrWatt data pipeline."""
import os
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent
LANDING = ROOT / "data" / "landing"
DB_PATH = ROOT / "data" / "dyrwatt.duckdb"
SQL_DIR = ROOT / "sql"

# --- NVE magasinstatistikk (open, no key) -----------------------------------
NVE_BASE = "https://biapi.nve.no/magasinstatistikk/api/Magasinstatistikk"
NVE_ENDPOINTS = {
    "magasin": "HentOffentligData",                    # weekly fill, all areas, 1995 ->
    "minmaxmedian": "HentOffentligDataMinMaxMedian",   # historic min/median/max per ISO week
    "omrader": "HentOmråder",                          # area names/descriptions
}

# --- NVE GridTimeSeries / seNorge (open, no key): gridded daily precipitation since 1957.
# Points per area are in sql/seeds/precip_points.csv (UTM33 coordinates).
GTS_BASE = "https://gts.nve.no/api/GridTimeSeries"
GTS_THEME = "rr"   # døgnnedbør, mm

# --- MET Frost, optional (needs a free client id: https://frost.met.no/auth/requestCredentials.html)
FROST_BASE = "https://frost.met.no"
FROST_CLIENT_ID = os.getenv("FROST_CLIENT_ID", "")
# Daily precipitation, the standard Norwegian "nedbørdøgn" (06-06 UTC)
FROST_ELEMENT = "sum(precipitation_amount P1D)"

# One representative station per elspot area. The station->area mapping lives in
# sql/seeds/station_area.csv so the SQL model owns it; this list just drives extraction.
STATIONS = ["SN18700", "SN39040", "SN50540", "SN68860", "SN90450"]

START_YEAR = int(os.getenv("START_YEAR", "2018"))
END_YEAR = date.today().year
