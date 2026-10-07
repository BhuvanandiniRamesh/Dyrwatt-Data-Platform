-- =============================================================================
-- 30_facts.sql  -  Fact tables
--   fact_reservoir_weekly      grain: area x ISO week     (NVE)
--   fact_precipitation_daily   grain: station x day       (Frost)
--   fact_precipitation_weekly  grain: area x ISO week     (aggregate, aligns with reservoir)
-- =============================================================================

CREATE OR REPLACE TABLE dw.fact_reservoir_weekly AS
SELECT
    d.date_key,
    a.area_key,
    r.iso_year,
    r.iso_week,
    r.fill_pct,
    r.fill_twh,
    r.capacity_twh,
    r.change_pp,
    -- Same ISO week one year earlier (ISO weeks make this a clean like-for-like)
    py.fill_pct                               AS fill_pct_prev_year,
    ROUND(r.fill_pct - py.fill_pct, 2)        AS yoy_change_pp,
    b.hist_min_pct,
    b.hist_median_pct,
    b.hist_max_pct,
    ROUND(r.fill_pct - b.hist_median_pct, 2)  AS deviation_from_median_pp
FROM stg.reservoir_weekly r
JOIN dw.dim_date d          ON d.date = r.week_end_date
JOIN dw.dim_area a          ON a.area_code = r.area_code
LEFT JOIN stg.reservoir_weekly py
       ON py.area_code = r.area_code AND py.iso_year = r.iso_year - 1 AND py.iso_week = r.iso_week
LEFT JOIN stg.reservoir_benchmark b
       ON b.area_code = r.area_code AND b.iso_week = r.iso_week;

CREATE OR REPLACE TABLE dw.fact_precipitation_daily AS
SELECT
    d.date_key,
    s.station_key,
    s.area_key,
    p.precip_mm,
    CASE WHEN p.precip_mm >= 1 THEN 1 ELSE 0 END AS is_wet_day,   -- met.no definition: >= 1.0 mm
    p.quality_code
FROM stg.precipitation_daily p
JOIN dw.dim_station s ON s.station_id = p.station_id
JOIN dw.dim_date d    ON d.date = p.obs_date;

-- Weekly precipitation per area, keyed on the same week-end date as the reservoir
-- fact so the two can be compared directly. With several stations in one area
-- the area value is the average of the station totals. The national row (NOR)
-- is the average across all stations used for areas.
CREATE OR REPLACE TABLE dw.fact_precipitation_weekly AS
WITH per_station AS (
    SELECT d.iso_year, d.iso_week, d.week_end_date, f.area_key, f.station_key,
           SUM(f.precip_mm)  AS precip_mm,
           SUM(f.is_wet_day) AS wet_days,
           COUNT(*)          AS days_with_data
    FROM dw.fact_precipitation_daily f
    JOIN dw.dim_date d USING (date_key)
    JOIN dw.dim_station st USING (station_key)
    WHERE st.use_for_area          -- seNorge points; Frost only where an area has none
    GROUP BY ALL
),
tagged AS (
    SELECT * FROM per_station
    UNION ALL
    SELECT iso_year, iso_week, week_end_date,
           (SELECT area_key FROM dw.dim_area WHERE area_code = 'NOR'),
           station_key, precip_mm, wet_days, days_with_data
    FROM per_station
)
SELECT CAST(strftime(week_end_date, '%Y%m%d') AS INTEGER) AS date_key,
       area_key, iso_year, iso_week,
       ROUND(AVG(precip_mm), 1)       AS precip_mm,
       ROUND(AVG(wet_days), 1)        AS wet_days,
       MIN(days_with_data)            AS days_with_data,
       COUNT(*)                       AS station_count
FROM tagged
GROUP BY date_key, area_key, iso_year, iso_week;
