-- =============================================================================
-- 01_raw_frost.sql  -  OPTIONAL: MET Frost station data (run when data/landing/frost exists).
-- build.py runs 01_raw_frost_empty.sql instead when there are no Frost files,
-- so the staging views always find these tables.
-- =============================================================================
CREATE OR REPLACE TABLE raw.frost_sources AS
SELECT *, now() AS _loaded_at
FROM read_json('data/landing/frost/sources.json');

CREATE OR REPLACE TABLE raw.frost_observations AS
SELECT *, now() AS _loaded_at, filename AS _source_file
FROM read_json('data/landing/frost/observations/*.json', filename = true, union_by_name = true);
