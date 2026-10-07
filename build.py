"""Transform step: run the SQL model (raw -> staging -> star schema -> reports) in DuckDB.

Usage:  python build.py
Equivalent with the DuckDB CLI (from the project root):
    duckdb data/dyrwatt.duckdb -c ".read sql/00_raw.sql" -c ".read sql/01_raw_frost_empty.sql" -c ".read sql/10_staging.sql" \
        -c ".read sql/20_dimensions.sql" -c ".read sql/30_facts.sql" -c ".read sql/40_reports.sql"
"""
import os

import duckdb

import config as cfg

def sql_files():
    # Frost is optional: load it if it was ingested, else create empty Frost tables
    frost = "01_raw_frost.sql" if (cfg.LANDING / "frost" / "sources.json").exists() else "01_raw_frost_empty.sql"
    return ["00_raw.sql", frost, "10_staging.sql", "20_dimensions.sql", "30_facts.sql", "40_reports.sql"]


def build():
    os.chdir(cfg.ROOT)  # SQL uses paths relative to the project root
    cfg.DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(cfg.DB_PATH))
    for f in sql_files():
        print(f"running {f}")
        con.execute((cfg.SQL_DIR / f).read_text(encoding="utf-8"))
    for t in ["dw.dim_date", "dw.dim_area", "dw.dim_station",
              "dw.fact_reservoir_weekly", "dw.fact_precipitation_daily", "dw.fact_precipitation_weekly"]:
        print(f"  {t:32s} {con.execute(f'SELECT COUNT(*) FROM {t}').fetchone()[0]:>8,} rows")
    con.close()


if __name__ == "__main__":
    build()
