-- =============================================================================
-- 00_raw.sql  -  Load landed JSON into the raw layer (1:1 with the API, plus load metadata)
-- Run from the project root (paths are relative).
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS dw;
CREATE SCHEMA IF NOT EXISTS rpt;

-- NVE: weekly reservoir filling, all area types (EL / VASS / NO)
CREATE OR REPLACE TABLE raw.nve_magasin AS
SELECT *, now() AS _loaded_at, filename AS _source_file
FROM read_json('data/landing/nve/magasin.json', filename = true);

-- NVE: historic min / median / max per ISO week and area
CREATE OR REPLACE TABLE raw.nve_minmaxmedian AS
SELECT *, now() AS _loaded_at
FROM read_json('data/landing/nve/minmaxmedian.json');

-- NVE: area metadata
CREATE OR REPLACE TABLE raw.nve_omrader AS
SELECT *, now() AS _loaded_at
FROM read_json('data/landing/nve/omrader.json');

-- NVE GridTimeSeries (seNorge): one file per point and year, Data[] = one value per day
CREATE OR REPLACE TABLE raw.nve_gts_precip AS
SELECT *, now() AS _loaded_at, filename AS _source_file
FROM read_json('data/landing/nve_gts/*.json', filename = true, union_by_name = true);

-- Seeds owned by the model
CREATE OR REPLACE TABLE raw.seed_precip_points AS
SELECT * FROM read_csv('sql/seeds/precip_points.csv', header = true);

CREATE OR REPLACE TABLE raw.seed_station_area AS
SELECT * FROM read_csv('sql/seeds/station_area.csv', header = true);
