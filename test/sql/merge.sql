-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- Create conditions table with location and temperature
CREATE TABLE conditions (
   time        TIMESTAMPTZ       NOT NULL,
   location    SMALLINT          NOT NULL,
   temperature DOUBLE PRECISION  NULL
);

SELECT create_hypertable(
  'conditions',
  'time',
  chunk_time_interval => INTERVAL '5 seconds');
  

INSERT INTO conditions
SELECT time, location, 14 as temperature
FROM generate_series(
	'2021-01-01 00:00:00',
    '2021-01-01 00:00:09',
    INTERVAL '5 seconds'
  ) as time,
generate_series(1,4) as location;

-- Create conditions_updated table with location and temperature
CREATE TABLE conditions_updated (
   time        TIMESTAMPTZ       NOT NULL,
   location    SMALLINT          NOT NULL,
   temperature DOUBLE PRECISION  NULL
);

SELECT create_hypertable(
  'conditions_updated',
  'time',
  chunk_time_interval => INTERVAL '5 seconds');

-- Generate data that overlaps with conditions table
INSERT INTO conditions_updated
SELECT time, location, 80 as temperature
FROM generate_series(
	'2021-01-01 00:00:05',
    '2021-01-01 00:00:14',
    INTERVAL '5 seconds'
  ) as time,
generate_series(1,4) as location;

-- Print table/rows/num of chunks
select * from conditions order by time, location asc;
select * from conditions_updated order by time, location asc;
select hypertable_name, count(*) as num_of_chunks from timescaledb_information.chunks group by hypertable_name;

-- Print expected values in the conditions table once conditions_updated is merged into it
-- If a key exists in both tables, we take average of the temperature measured
-- average logic here is a mess but it works
SELECT COALESCE(c.time, cu.time) as time,
       COALESCE(c.location, cu.location) as location,
       (COALESCE(c.temperature, cu.temperature) + COALESCE(cu.temperature, c.temperature))/2 as temperature 
FROM conditions AS c FULL JOIN conditions_updated AS cu
ON c.time = cu.time AND c.location = cu.location;

-- Test that normal PostgreSQL tables can merge without exceptions
CREATE TABLE conditions_pg AS SELECT * FROM conditions;
CREATE TABLE conditions_updated_pg AS SELECT * FROM conditions_updated;
MERGE INTO conditions_pg c
USING conditions_updated_pg cu
ON c.time = cu.time AND c.location = cu.location
WHEN MATCHED THEN
UPDATE SET temperature = (c.temperature + cu.temperature)/2
WHEN NOT MATCHED THEN
INSERT (time, location, temperature) VALUES (cu.time, cu.location, cu.temperature);
SELECT * FROM conditions_pg ORDER BY time, location ASC;

-- Merge conditions_updated into conditions
\set ON_ERROR_STOP 0
MERGE INTO conditions c
USING conditions_updated cu
ON c.time = cu.time AND c.location = cu.location
WHEN MATCHED THEN
UPDATE SET temperature = (c.temperature + cu.temperature)/2
WHEN NOT MATCHED THEN
INSERT (time, location, temperature) VALUES (cu.time, cu.location, cu.temperature);

SELECT * FROM conditions ORDER BY time, location ASC;
\set ON_ERROR_STOP 1
