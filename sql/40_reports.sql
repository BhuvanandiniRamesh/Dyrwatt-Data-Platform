-- =============================================================================
-- 40_reports.sql  -  Report views on top of the star schema.
-- Each view answers one of DyrWatt's questions and can be used directly in
-- Power BI / the HTML dashboard. Nothing here reads raw or staging.
-- =============================================================================

-- Helper: daily precipitation per area (station average) incl. national (NOR)
CREATE OR REPLACE VIEW dw.v_precipitation_daily_area AS
WITH f AS (
    SELECT f.* FROM dw.fact_precipitation_daily f
    JOIN dw.dim_station st USING (station_key)
    WHERE st.use_for_area
)
SELECT f.date_key, f.area_key, AVG(f.precip_mm) AS precip_mm, AVG(f.is_wet_day) AS wet_day_share
FROM f
GROUP BY ALL
UNION ALL
SELECT f.date_key, (SELECT area_key FROM dw.dim_area WHERE area_code = 'NOR'),
       AVG(f.precip_mm), AVG(f.is_wet_day)
FROM f
GROUP BY f.date_key;

-- 1. TREND OVER TIME + COMPARISON WITH PREVIOUS YEAR (weekly) ----------------------
CREATE OR REPLACE VIEW rpt.reservoir_trend AS
SELECT
    a.area_code, a.area_name,
    d.date        AS week_end_date,
    r.iso_year, r.iso_week,
    r.fill_pct, r.fill_twh, r.capacity_twh,
    r.change_pp                         AS week_change_pp,
    r.fill_pct_prev_year, r.yoy_change_pp,
    r.hist_min_pct, r.hist_median_pct, r.hist_max_pct, r.deviation_from_median_pp,
    p.precip_mm                         AS precip_week_mm,
    pp.precip_mm                        AS precip_week_prev_year_mm
FROM dw.fact_reservoir_weekly r
JOIN dw.dim_area a  USING (area_key)
JOIN dw.dim_date d  USING (date_key)
LEFT JOIN dw.fact_precipitation_weekly p
       ON p.area_key = r.area_key AND p.date_key = r.date_key
LEFT JOIN dw.fact_precipitation_weekly pp
       ON pp.area_key = r.area_key AND pp.iso_year = r.iso_year - 1 AND pp.iso_week = r.iso_week;

-- 2. PRECIPITATION PER MONTH vs PREVIOUS YEAR and vs NORMAL ---------------------------
CREATE OR REPLACE VIEW rpt.precipitation_monthly AS
WITH m AS (
    SELECT a.area_code, a.area_name, d.year, d.month, d.month_short,
           ROUND(SUM(p.precip_mm), 1)        AS precip_mm,
           ROUND(SUM(p.wet_day_share), 0)    AS wet_days,
           MAX(p.precip_mm)                  AS max_day_mm,
           COUNT(*)                          AS days_with_data
    FROM dw.v_precipitation_daily_area p
    JOIN dw.dim_area a USING (area_key)
    JOIN dw.dim_date d USING (date_key)
    GROUP BY ALL
)
SELECT m.*,
       LAG(precip_mm) OVER w                                  AS precip_prev_year_mm,
       ROUND(precip_mm - LAG(precip_mm) OVER w, 1)            AS yoy_change_mm,
       ROUND(100.0 * (precip_mm / NULLIF(LAG(precip_mm) OVER w, 0) - 1), 1) AS yoy_change_pct,
       -- "Normal" = average for the month across all complete years in the data set
       ROUND(AVG(precip_mm) FILTER (WHERE days_with_data >= 28)
             OVER (PARTITION BY area_code, month), 1)         AS normal_mm,
       days_with_data < 28                                    AS is_partial_month
FROM m
WINDOW w AS (PARTITION BY area_code, month ORDER BY year);

-- 3. MAX / MIN PER YEAR + YEAR-OVER-YEAR SUMMARY --------------------------------------
CREATE OR REPLACE VIEW rpt.yearly_summary AS
WITH res AS (
    SELECT area_code, iso_year AS year,
           ROUND(AVG(fill_pct), 1)                       AS avg_fill_pct,
           MAX(fill_pct)                                 AS max_fill_pct,
           ARG_MAX(iso_week, fill_pct)                   AS max_fill_week,
           MIN(fill_pct)                                 AS min_fill_pct,
           ARG_MIN(iso_week, fill_pct)                   AS min_fill_week,
           MAX(week_change_pp)                           AS max_week_increase_pp,
           MIN(week_change_pp)                           AS max_week_decrease_pp,
           ARG_MAX(fill_pct, week_end_date)              AS last_fill_pct,
           MAX(iso_week)                                 AS last_week
    FROM rpt.reservoir_trend
    GROUP BY ALL
),
pre AS (
    SELECT a.area_code, d.year,
           ROUND(SUM(p.precip_mm), 0)                    AS total_precip_mm,
           ROUND(MAX(p.precip_mm), 1)                    AS max_day_precip_mm,
           ARG_MAX(d.date, p.precip_mm)                  AS max_day_precip_date,
           ROUND(SUM(p.wet_day_share), 0)                AS wet_days,
           MAX(d.day_of_year)                            AS last_day_of_year
    FROM dw.v_precipitation_daily_area p
    JOIN dw.dim_area a USING (area_key)
    JOIN dw.dim_date d USING (date_key)
    GROUP BY ALL
),
ytd AS (  -- precipitation year-to-date, so the current (incomplete) year compares fairly
    SELECT a.area_code, d.year, ROUND(SUM(p.precip_mm), 0) AS precip_ytd_mm
    FROM dw.v_precipitation_daily_area p
    JOIN dw.dim_area a USING (area_key)
    JOIN dw.dim_date d USING (date_key)
    WHERE d.day_of_year <= (SELECT DAYOFYEAR(MAX(date)) FROM dw.dim_date
                            WHERE date_key IN (SELECT date_key FROM dw.fact_precipitation_daily))
    GROUP BY ALL
)
SELECT res.*, pre.total_precip_mm, pre.max_day_precip_mm, pre.max_day_precip_date, pre.wet_days,
       ytd.precip_ytd_mm,
       LAG(res.avg_fill_pct)    OVER w                                  AS avg_fill_pct_prev_year,
       ROUND(res.avg_fill_pct - LAG(res.avg_fill_pct) OVER w, 1)        AS avg_fill_yoy_pp,
       LAG(ytd.precip_ytd_mm)   OVER w                                  AS precip_ytd_prev_year_mm,
       ROUND(100.0 * (ytd.precip_ytd_mm / NULLIF(LAG(ytd.precip_ytd_mm) OVER w, 0) - 1), 1)
                                                                        AS precip_ytd_yoy_pct
FROM res
LEFT JOIN pre USING (area_code, year)
LEFT JOIN ytd USING (area_code, year)
WINDOW w AS (PARTITION BY res.area_code ORDER BY res.year);

-- 4. PERIODS WITH THE LARGEST CHANGE ----------------------------------------------------
-- Four lenses, ranked within each area-year and across all years:
--   fill_1w   weekly change in fill (pp)        fill_4w   change over 4 weeks (pp)
--   precip_1w weekly precipitation total (mm)   precip_4w rolling 4-week total (mm)
CREATE OR REPLACE VIEW rpt.largest_changes AS
WITH base AS (
    SELECT area_code, area_name, iso_year, iso_week, week_end_date,
           week_change_pp,
           fill_pct - LAG(fill_pct, 4) OVER (PARTITION BY area_code ORDER BY week_end_date) AS change_4w_pp,
           precip_week_mm,
           SUM(precip_week_mm) OVER (PARTITION BY area_code ORDER BY week_end_date
                                     ROWS BETWEEN 3 PRECEDING AND CURRENT ROW)           AS precip_4w_mm
    FROM rpt.reservoir_trend
),
long AS (
    SELECT area_code, area_name, iso_year, iso_week, week_end_date, 'fill_1w' AS metric,
           week_change_pp AS value FROM base WHERE week_change_pp IS NOT NULL
    UNION ALL SELECT area_code, area_name, iso_year, iso_week, week_end_date, 'fill_4w',
           ROUND(change_4w_pp, 2) FROM base WHERE change_4w_pp IS NOT NULL
    UNION ALL SELECT area_code, area_name, iso_year, iso_week, week_end_date, 'precip_1w',
           precip_week_mm FROM base WHERE precip_week_mm IS NOT NULL
    UNION ALL SELECT area_code, area_name, iso_year, iso_week, week_end_date, 'precip_4w',
           ROUND(precip_4w_mm, 1) FROM base WHERE precip_4w_mm IS NOT NULL
)
SELECT *,
       CASE WHEN metric LIKE 'fill%' THEN (CASE WHEN value >= 0 THEN 'Økning' ELSE 'Nedgang' END)
            ELSE 'Nedbør' END                                                      AS direction,
       week_end_date - 6                                                           AS period_start,
       CASE WHEN metric LIKE '%4w' THEN week_end_date - 27 ELSE week_end_date - 6 END AS window_start,
       RANK() OVER (PARTITION BY area_code, metric, iso_year ORDER BY ABS(value) DESC) AS rank_in_year,
       RANK() OVER (PARTITION BY area_code, metric          ORDER BY ABS(value) DESC) AS rank_all_time
FROM long;

-- 5. ALL-TIME RECORDS per area (for KPI cards) ------------------------------------------
CREATE OR REPLACE VIEW rpt.alltime_extremes AS
SELECT area_code,
       MAX(fill_pct)                               AS record_high_fill_pct,
       ARG_MAX(week_end_date, fill_pct)            AS record_high_fill_week,
       MIN(fill_pct)                               AS record_low_fill_pct,
       ARG_MIN(week_end_date, fill_pct)            AS record_low_fill_week,
       MAX(precip_week_mm)                         AS record_wet_week_mm,
       ARG_MAX(week_end_date, precip_week_mm)      AS record_wet_week
FROM rpt.reservoir_trend
GROUP BY area_code;
