-- Empty Frost tables with the API's shape, used when Frost is not ingested.
CREATE OR REPLACE TABLE raw.frost_sources (
    id VARCHAR, name VARCHAR, shortName VARCHAR, municipality VARCHAR, county VARCHAR,
    masl INTEGER, geometry STRUCT(coordinates DOUBLE[]), _loaded_at TIMESTAMP WITH TIME ZONE
);
CREATE OR REPLACE TABLE raw.frost_observations (
    sourceId VARCHAR, referenceTime VARCHAR,
    observations STRUCT(elementId VARCHAR, "value" DOUBLE, timeOffset VARCHAR, qualityCode INTEGER)[],
    _loaded_at TIMESTAMP WITH TIME ZONE, _source_file VARCHAR
);
