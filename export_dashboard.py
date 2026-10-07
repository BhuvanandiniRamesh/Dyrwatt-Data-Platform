"""Serve step: read the rpt.* views and bake them into a self-contained dashboard.

Usage:  python export_dashboard.py      ->  dashboard/dyrwatt_dashboard.html
The dashboard is a single HTML file (no server needed). Re-run after build.py
to refresh it with the latest data.
"""
import json
import os
import shutil
import subprocess
from datetime import datetime

import config as cfg

TEMPLATE = cfg.ROOT / "dashboard" / "template.html"
OUT = cfg.ROOT / "dashboard" / "dyrwatt_dashboard.html"
PLACEHOLDER = "/*__DASHBOARD_DATA__*/null"


def _query_factory():
    """Use the duckdb Python package; fall back to the duckdb CLI if it is not installed."""
    try:
        import duckdb
        con = duckdb.connect(str(cfg.DB_PATH), read_only=True)

        def q(sql):
            cur = con.execute(sql)
            cols = [c[0] for c in cur.description]
            return [dict(zip(cols, r)) for r in cur.fetchall()]
        return q
    except ImportError:
        cli = os.getenv("DUCKDB_CLI") or shutil.which("duckdb")

        def q(sql):
            out = subprocess.run([cli, "-readonly", "-json", str(cfg.DB_PATH), "-c", sql],
                                 capture_output=True, text=True, check=True).stdout
            return json.loads(out) if out.strip() else []
        return q


def _by_area(rows, cols):
    out = {}
    for r in rows:
        out.setdefault(r["area_code"], []).append([r[c] for c in cols])
    return out


def export():
    q = _query_factory()
    areas = q("""
        SELECT a.area_code AS code, a.area_name AS name, a.area_long_name AS long_name,
               a.description, s.station_name AS station, s.station_id,
               s.elevation_m, s.source AS precip_source
        FROM dw.dim_area a
        LEFT JOIN dw.dim_station s ON s.area_key = a.area_key AND s.use_for_area
        ORDER BY a.sort_order""")

    wcols = ["week_end_date", "iso_year", "iso_week", "fill_pct", "fill_twh", "capacity_twh",
             "week_change_pp", "hist_min_pct", "hist_median_pct", "hist_max_pct", "precip_week_mm"]
    weekly = _by_area(q(f"SELECT area_code, {', '.join(wcols)} FROM rpt.reservoir_trend "
                        "ORDER BY area_code, week_end_date"), wcols)

    mcols = ["year", "month", "precip_mm", "normal_mm", "wet_days", "max_day_mm", "is_partial_month"]
    monthly = _by_area(q(f"SELECT area_code, {', '.join(mcols)} FROM rpt.precipitation_monthly "
                         "ORDER BY area_code, year, month"), mcols)

    ycols = ["year", "avg_fill_pct", "max_fill_pct", "max_fill_week", "min_fill_pct", "min_fill_week",
             "max_week_increase_pp", "max_week_decrease_pp", "total_precip_mm", "max_day_precip_mm",
             "max_day_precip_date", "wet_days", "precip_ytd_mm", "precip_ytd_yoy_pct", "avg_fill_yoy_pp"]
    yearly = _by_area(q(f"SELECT area_code, {', '.join(ycols)} FROM rpt.yearly_summary "
                        "ORDER BY area_code, year"), ycols)

    ccols = ["metric", "iso_year", "iso_week", "window_start", "week_end_date", "value",
             "rank_in_year", "rank_all_time"]
    changes = _by_area(q(f"SELECT area_code, {', '.join(ccols)} FROM rpt.largest_changes "
                         "WHERE rank_in_year <= 5 OR rank_all_time <= 10 "
                         "ORDER BY area_code, metric, rank_all_time"), ccols)

    meta = q("""SELECT (SELECT MAX(week_end_date) FROM rpt.reservoir_trend) AS last_week_end,
                       (SELECT MAX(d.date) FROM dw.fact_precipitation_daily f
                        JOIN dw.dim_date d USING (date_key)) AS last_precip_date""")[0]
    meta.update(generated_at=datetime.now().isoformat(timespec="minutes"),
                demo=(cfg.LANDING / "_DEMO").exists())

    data = {"meta": meta, "areas": areas, "cols": {"weekly": wcols, "monthly": mcols,
            "yearly": ycols, "changes": ccols},
            "weekly": weekly, "monthly": monthly, "yearly": yearly, "changes": changes}
    payload = json.dumps(data, default=str, ensure_ascii=False, separators=(",", ":"))

    html = TEMPLATE.read_text(encoding="utf-8")
    assert PLACEHOLDER in html, "placeholder missing from template"
    OUT.write_text(html.replace(PLACEHOLDER, payload), encoding="utf-8")
    (cfg.ROOT / "dashboard" / "dashboard_data.json").write_text(payload, encoding="utf-8")
    print(f"Dashboard written to {OUT} ({len(payload) / 1024:.0f} KB of data)")


if __name__ == "__main__":
    export()
