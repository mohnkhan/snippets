-- show running queries (pre 9.2)
SELECT procpid, age(query_start, clock_timestamp()), usename, current_query 
FROM pg_stat_activity 
WHERE current_query != '<IDLE>' AND current_query NOT ILIKE '%pg_stat_activity%' 
ORDER BY query_start desc;

-- show running queries (9.2)
SELECT pid, age(query_start, clock_timestamp()), usename, query 
FROM pg_stat_activity 
WHERE query != '<IDLE>' AND query NOT ILIKE '%pg_stat_activity%' 
ORDER BY query_start desc;

-- kill running query
SELECT pg_cancel_backend(procpid);

-- kill idle query
SELECT pg_terminate_backend(procpid);

-- vacuum command
VACUUM (VERBOSE, ANALYZE);

-- all database users
select * from pg_stat_activity where current_query not like '<%';

-- all databases and their sizes
select * from pg_user;

-- all tables and their size, with/without indexes
select datname, pg_size_pretty(pg_database_size(datname))
from pg_database
order by pg_database_size(datname) desc;

-- cache hit rates (should not be less than 0.99)
SELECT sum(heap_blks_read) as heap_read, sum(heap_blks_hit)  as heap_hit, (sum(heap_blks_hit) - sum(heap_blks_read)) / sum(heap_blks_hit) as ratio
FROM pg_statio_user_tables;

-- table index usage rates (should not be less than 0.99)
SELECT relname, 100 * idx_scan / (seq_scan + idx_scan) percent_of_times_index_used, n_live_tup rows_in_table
FROM pg_stat_user_tables 
ORDER BY n_live_tup DESC;

-- how many indexes are in cache
SELECT sum(idx_blks_read) as idx_read, sum(idx_blks_hit)  as idx_hit, (sum(idx_blks_hit) - sum(idx_blks_read)) / sum(idx_blks_hit) as ratio
FROM pg_statio_user_indexes;

-- Dump database on remote host to file
$ pg_dump -U username -h hostname databasename > dump.sql

-- Import dump into existing database
$ psql -d newdb -f dump.sql


-- Table information like sortkeys, unsorted percentage
-- see http://docs.aws.amazon.com/redshift/latest/dg/r_SVV_TABLE_INFO.html
-- http://docs.aws.amazon.com/redshift/latest/dg/c_intro_STL_tables.html  --> meaning 

SELECT * FROM svv_table_info;

-- Table sizes in GB
SELECT t.name, COUNT(tbl) / 1000.0 AS gb
FROM (
  SELECT DISTINCT datname, id, name
  FROM stv_tbl_perm
  JOIN pg_database ON pg_database.oid = db_id
) AS t
JOIN stv_blocklist ON tbl = t.id
GROUP BY t.name ORDER BY gb DESC;

-- Table column metadata
SELECT * FROM pg_table_def
WHERE schemaname = 'public'
AND tablename = …;

-- Vacuum progress
-- see http://docs.aws.amazon.com/redshift/latest/dg/r_SVV_VACUUM_PROGRESS.html
SELECT * FROM svv_vacuum_progress;

-- The size in MB of each column of each table (actually the number of blocks, but blocks are 1 MB)
-- see http://stackoverflow.com/questions/33388587/how-can-i-find-out-the-size-of-each-column-in-a-redshift-table
SELECT
  TRIM(name) as table_name,
  TRIM(pg_attribute.attname) AS column_name,
  COUNT(1) AS size
FROM
  svv_diskusage JOIN pg_attribute ON
    svv_diskusage.col = pg_attribute.attnum-1 AND
    svv_diskusage.tbl = pg_attribute.attrelid
GROUP BY 1, 2
ORDER BY 1, 2;

-- List users and groups
SELECT * FROM pg_user;
SELECT * FROM pg_group;

-- List all databases
SELECT * FROM pg_database;

-- List the 100 last load errors
-- see http://docs.aws.amazon.com/redshift/latest/dg/r_STL_LOAD_ERRORS.html
SELECT *
FROM stl_load_errors
ORDER BY starttime DESC
LIMIT 100;

-- Convert a millisecond resolution number to a TIMESTAMP
SELECT TIMESTAMP 'epoch' + (millisecond_timestamp/1000 * INTERVAL '1 second') FROM …;

-- Get the full SQL from a query ID
SELECT LISTAGG(text) WITHIN GROUP (ORDER BY sequence) AS sql
FROM STL_QUERYTEXT
WHERE query = …;

-- Get the full SQL, plus more query details from a query ID
-- filter on xid to see all (including Redshift internal) operations in the transaction
WITH query_sql AS (
  SELECT
    query,
    LISTAGG(text) WITHIN GROUP (ORDER BY sequence) AS sql
  FROM stl_querytext
  GROUP BY 1
)
SELECT
  q.query,
  userid,
  xid,
  pid,
  starttime,
  endtime,
  DATEDIFF(milliseconds, starttime, endtime)/1000.0 AS duration,
  TRIM(database) AS database,
  (CASE aborted WHEN 1 THEN TRUE ELSE FALSE END) AS aborted,
  sql
FROM
  stl_query q JOIN query_sql qs ON (q.query = qs.query)
WHERE
  q.query = …
ORDER BY starttime;

-- Show the most recently executed DDL statements
SELECT
  starttime,
  xid,
  LISTAGG(text) WITHIN GROUP (ORDER BY sequence) AS sql
FROM stl_ddltext
GROUP BY 1, 2
ORDER BY 1 DESC;

-- Query duration stats per database, user and query group; including the max, median, 99 percentile, etc.
-- Change which duration to use (queue, exec or total) by commenting out the right lines below
WITH
durations1 AS (
  SELECT
    TRIM("database") AS db,
    TRIM(u.usename) AS "user",
    TRIM(label) AS query_group,
    DATE_TRUNC('day', starttime) AS day,
    -- total_queue_time/1000000.0 AS duration,
    -- total_exec_time/1000000.0 AS duration,
    (total_queue_time + total_exec_time)/1000000.0 AS duration
  FROM stl_query q, stl_wlm_query w, pg_user u
  WHERE q.query = w.query
    AND q.userid = u.usesysid
    AND aborted = 0
),
durations2 AS (
  SELECT
    db,
    "user",
    query_group,
    day,
    duration,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY duration) OVER (PARTITION BY db, "user", query_group, day) AS median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY duration) OVER (PARTITION BY db, "user", query_group, day) AS p75,
    PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY duration) OVER (PARTITION BY db, "user", query_group, day) AS p90,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration) OVER (PARTITION BY db, "user", query_group, day) AS p95,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY duration) OVER (PARTITION BY db, "user", query_group, day) AS p99,
    PERCENTILE_CONT(0.999) WITHIN GROUP (ORDER BY duration) OVER (PARTITION BY db, "user", query_group, day) AS p999
  FROM durations1
)
SELECT
  db,
  "user",
  query_group,
  day,
  MIN(duration) AS min,
  AVG(duration) AS avg,
  MAX(median) AS median,
  MAX(p75) AS p75,
  MAX(p90) AS p90,
  MAX(p95) AS p95,
  MAX(p99) AS p99,
  MAX(p999) AS p999,
  MAX(duration) AS max
FROM durations2
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 3, 4;

-- Currently executing and recently executed queries with status, duration, database, etc.
SELECT
  r.pid,
  TRIM(status) AS status,
  TRIM(db_name) AS db,
  TRIM(user_name) AS "user",
  TRIM(label) AS query_group,
  r.starttime AS start_time,
  r.duration,
  r.query AS sql
FROM stv_recents r LEFT JOIN stv_inflight i ON r.pid = i.pid;
 
-- See the remote host and port of running queries
SELECT
  recents.pid,
  TRIM(db_name) AS db,
  TRIM(user_name) AS "user",
  TRIM(label) AS query_group,
  recents.starttime AS start_time,
  recents.duration,
  recents.query AS sql,
  TRIM(remotehost) AS remote_host,
  TRIM(remoteport) AS remote_port
FROM stv_recents recents
LEFT JOIN stl_connection_log connections ON (recents.pid = connections.pid)
LEFT JOIN stv_inflight inflight ON recents.pid = inflight.pid
WHERE TRIM(status) = 'Running'
AND event = 'initiating session';


--- Find running query
select pid, user_name, starttime, query
from stv_recents
where status='Running';
----


