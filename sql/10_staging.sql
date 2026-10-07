-- =============================================================================
-- 10_staging.sql  -  Clean, type, rename and de-duplicate. Views only.
-- =============================================================================

-- Map NVE (omrType, omrnr) to a readable area code. We keep the five elspot
-- areas (EL) and the national total (NO); VASS (watercourse regions) is out of scope.
CREATE OR REPLACE MACRO stg.area_code(omr_type, omr_nr) AS
    CASE WHEN omr_type = 'EL' THEN 'NO' || omr_nr
         WHEN omr_type = 'NO' THEN 'NOR' END;

-- Weekly reservoir filling -----------------------------------------------------
CREATE OR REPLACE VIEW stg.reservoir_weekly_base AS
SELECT
    stg.area_code(omrType, omrnr)                AS area_code,
    CAST(dato_Id AS DATE)                        AS week_end_date,   -- NVE week ends Sunday
    CAST(iso_aar AS INTEGER)                     AS iso_year,
    CAST(iso_uke AS INTEGER)                     AS iso_week,
    ROUND(fyllingsgrad * 100, 2)                 AS fill_pct,
    CAST(fylling_TWh   AS DOUBLE)                AS fill_twh,
    CAST(kapasitet_TWh AS DOUBLE)                AS capacity_twh,
    ROUND(endring_fyllingsgrad * 100, 2)         AS nve_change_pp       -- as published (vs NVE's revised previous week)
FROM raw.nve_magasin
WHERE omrType IN ('EL', 'NO')
  AND fyllingsgrad IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY omrType, omrnr, dato_Id ORDER BY _loaded_at DESC) = 1;

-- Weekly change computed from the series itself, so it always matches the plotted
-- line. NVE's own endring_fyllingsgrad can differ slightly when NVE revised the
-- previous week after publishing it (mostly 2024 onwards).
CREATE OR REPLACE VIEW stg.reservoir_weekly AS
SELECT *,
       CASE WHEN week_end_date - LAG(week_end_date) OVER w = 7
            THEN ROUND(fill_pct - LAG(fill_pct) OVER w, 2) END AS change_pp
FROM stg.reservoir_weekly_base
WINDOW w AS (PARTITION BY area_code ORDER BY week_end_date);

-- Historic benchmark per ISO week ---------------------------------------------
CREATE OR REPLACE VIEW stg.reservoir_benchmark AS
SELECT
    stg.area_code(omrType, omrnr)       AS area_code,
    CAST(iso_uke AS INTEGER)            AS iso_week,
    ROUND(minFyllingsgrad    * 100, 2)  AS hist_min_pct,
    ROUND(medianFyllingsGrad * 100, 2)  AS hist_median_pct,
    ROUND(maxFyllingsgrad    * 100, 2)  AS hist_max_pct
FROM raw.nve_minmaxmedian
WHERE omrType IN ('EL', 'NO');

-- Areas --------------------------------------------------------------------------
CREATE OR REPLACE VIEW stg.area AS
SELECT stg.area_code(omrType, omrnr) AS area_code,
       navn                          AS area_name,
       navn_langt                    AS area_long_name,
       beskrivelse                   AS description,
       'Elspotområde'                AS area_type,
       omrnr                         AS sort_order
FROM raw.nve_omrader
WHERE omrType = 'EL'
UNION ALL
SELECT 'NOR', 'Norge', 'Hele landet', 'Sum av alle elspotområder', 'Nasjonalt', 0;

-- Precipitation points -------------------------------------------------------------
-- Primary: NVE seNorge grid points placed at a key reservoir in each area.
-- Optional: MET Frost stations (only present if Frost was ingested).
-- use_for_area: area-level precipitation uses seNorge points, falling back to Frost
-- only for an area that has no seNorge point, so city stations and mountain
-- catchments are never averaged together.
CREATE OR REPLACE VIEW stg.station AS
WITH gts_meta AS (
    SELECT X, Y, ANY_VALUE(Altitude) AS altitude FROM raw.nve_gts_precip GROUP BY X, Y
),
all_points AS (
    SELECT p.point_id                    AS station_id,
           p.name                        AS station_name,
           p.name                        AS short_name,
           NULL                          AS municipality,
           NULL                          AS county,
           CAST(g.altitude AS INTEGER)   AS elevation_m,
           CAST(p.latitude AS DOUBLE)    AS latitude,
           CAST(p.longitude AS DOUBLE)   AS longitude,
           p.area_code,
           'NVE seNorge (grid 1x1 km)'   AS source
    FROM raw.seed_precip_points p
    LEFT JOIN gts_meta g ON g.X = p.utm33_x AND g.Y = p.utm33_y
    UNION ALL
    SELECT s.id, s.name, s.shortName, s.municipality, s.county,
           CAST(s.masl AS INTEGER),
           s.geometry.coordinates[2],      -- GeoJSON order is [lon, lat]
           s.geometry.coordinates[1],
           m.area_code,
           'MET Frost (station)'
    FROM raw.frost_sources s
    JOIN raw.seed_station_area m ON m.station_id = s.id
)
SELECT *,
       source LIKE 'NVE%' OR NOT EXISTS (
           SELECT 1 FROM raw.seed_precip_points q WHERE q.area_code = all_points.area_code
       ) AS use_for_area
FROM all_points;

-- Daily precipitation --------------------------------------------------------------
CREATE OR REPLACE VIEW stg.precipitation_daily AS
WITH gts AS (      -- NVE GTS: Data[i] is day i counted from StartDate
    SELECT p.point_id                                          AS station_id,
           CAST(strptime(g.StartDate, '%d.%m.%Y %H:%M:%S') AS DATE) + CAST(t.i - 1 AS INTEGER) AS obs_date,
           NULLIF(CAST(t.v AS DOUBLE), g.NoDataValue)          AS precip_mm,
           NULL::INTEGER                                       AS quality_code,
           g._loaded_at
    FROM raw.nve_gts_precip g
    JOIN raw.seed_precip_points p ON p.utm33_x = g.X AND p.utm33_y = g.Y,
         (SELECT UNNEST(g.Data) AS v, generate_subscripts(g.Data, 1) AS i) AS t
    WHERE g.Theme = 'rr'
),
frost AS (         -- MET Frost JSON-LD: data[] -> observations[]
    SELECT split_part(d.sourceId, ':', 1)                      AS station_id,
           CAST(CAST(d.referenceTime AS TIMESTAMPTZ) AT TIME ZONE 'UTC' AS DATE) AS obs_date,
           GREATEST(CAST(o.value AS DOUBLE), 0)                AS precip_mm,   -- -1 = no measurable precipitation
           o.qualityCode                                       AS quality_code,
           d._loaded_at
    FROM raw.frost_observations d, UNNEST(d.observations) AS x(o)
    WHERE o.elementId = 'sum(precipitation_amount P1D)' AND o.timeOffset = 'PT6H'
)
SELECT station_id, obs_date, precip_mm, quality_code
FROM (SELECT * FROM gts UNION ALL SELECT * FROM frost)
WHERE precip_mm IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY station_id, obs_date ORDER BY _loaded_at DESC) = 1;
