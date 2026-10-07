-- =============================================================================
-- 20_dimensions.sql  -  Conformed dimensions (materialised as tables)
-- =============================================================================

-- dim_date: one row per calendar day. Carries both calendar and ISO-week
-- attributes so the weekly reservoir fact and the daily precipitation fact
-- share the same date dimension.
CREATE OR REPLACE TABLE dw.dim_date AS
WITH bounds AS (
    SELECT LEAST(
               (SELECT MIN(week_end_date) FROM stg.reservoir_weekly),
               COALESCE((SELECT MIN(obs_date) FROM stg.precipitation_daily), DATE '9999-12-31')
           ) - 6 AS d0,
           MAKE_DATE(YEAR(current_date), 12, 31) AS d1
),
days AS (
    SELECT CAST(gs AS DATE) AS d
    FROM bounds, generate_series(CAST(d0 AS TIMESTAMP), CAST(d1 AS TIMESTAMP), INTERVAL 1 DAY) AS t(gs)
)
SELECT
    CAST(strftime(d, '%Y%m%d') AS INTEGER)                  AS date_key,
    d                                                       AS date,
    YEAR(d)                                                 AS year,
    QUARTER(d)                                              AS quarter,
    MONTH(d)                                                AS month,
    ['Januar','Februar','Mars','April','Mai','Juni','Juli','August',
     'September','Oktober','November','Desember'][MONTH(d)] AS month_name,
    ['Jan','Feb','Mar','Apr','Mai','Jun','Jul','Aug',
     'Sep','Okt','Nov','Des'][MONTH(d)]                     AS month_short,
    DAY(d)                                                  AS day_of_month,
    ISODOW(d)                                               AS iso_day_of_week,
    DAYOFYEAR(d)                                            AS day_of_year,
    ISOYEAR(d)                                              AS iso_year,
    WEEKOFYEAR(d)                                           AS iso_week,
    ISOYEAR(d) * 100 + WEEKOFYEAR(d)                        AS iso_year_week,
    d + CAST(7 - ISODOW(d) AS INTEGER)                      AS week_end_date,   -- Sunday, matches NVE
    CASE WHEN MONTH(d) IN (12, 1, 2) THEN 'Vinter'
         WHEN MONTH(d) IN (3, 4, 5)  THEN 'Vår'
         WHEN MONTH(d) IN (6, 7, 8)  THEN 'Sommer'
         ELSE 'Høst' END                                    AS season,
    -- Hydrological year in Norway starts 1 October (snow accumulates, then melts)
    CASE WHEN MONTH(d) >= 10 THEN YEAR(d) ELSE YEAR(d) - 1 END AS hydro_year
FROM days;

-- dim_area ---------------------------------------------------------------------
CREATE OR REPLACE TABLE dw.dim_area AS
SELECT ROW_NUMBER() OVER (ORDER BY sort_order) AS area_key,
       area_code, area_name, area_long_name, description, area_type, sort_order
FROM stg.area;

-- dim_station ------------------------------------------------------------------
CREATE OR REPLACE TABLE dw.dim_station AS
SELECT ROW_NUMBER() OVER (ORDER BY s.station_id) AS station_key,
       s.station_id, s.station_name, s.short_name, s.municipality, s.county,
       s.elevation_m, s.latitude, s.longitude, s.source, s.use_for_area,
       a.area_key, a.area_code
FROM stg.station s
JOIN dw.dim_area a USING (area_code);
