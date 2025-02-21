-- This file and its contents are licensed under the Timescale License.
-- Please see the included NOTICE for copyright information and
-- LICENSE-TIMESCALE for a copy of the license.

-- Test parameterized data node scan.
\c :TEST_DBNAME :ROLE_CLUSTER_SUPERUSER;

\set DN_DBNAME_1 :TEST_DBNAME _1
-- pg_regress doesn't drop these databases for repeated invocation such as in
-- the flaky check.
set client_min_messages to ERROR;
drop database if exists :"DN_DBNAME_1";
select 1 from add_data_node('data_node_1', host => 'localhost',
                            database => :'DN_DBNAME_1');
grant usage on foreign server data_node_1 to public;
set role :ROLE_1;
reset client_min_messages;

-- helper function: float -> pseudorandom float [0..1].
create or replace function mix(x float4) returns float4 as $$ select ((hashfloat4(x) / (pow(2., 31) - 1) + 1) / 2)::float4 $$ language sql;

-- distributed hypertable
create table metric_dist(ts timestamptz, id int, value float);
select create_distributed_hypertable('metric_dist', 'ts', 'id');
insert into metric_dist
    select '2022-02-02 02:02:02+03'::timestamptz + interval '1 year' * mix(x),
        mix(x + 1.) * 20,
        mix(x + 2.) * 50
    from generate_series(1, 1000000) x(x)
;
analyze metric_dist;
select count(*) from show_chunks('metric_dist');

-- dictionary
create table metric_name(id int primary key, name text);
insert into metric_name values (1, 'cpu1'), (3, 'cpu3'),  (7, 'cpu7');
analyze metric_name;

-- for predictable plans
set enable_hashjoin to off;
set enable_mergejoin to off;
set enable_hashagg to off;

-- Subquery + IN
select id, max(value), count(*)
from metric_dist
where id in (select id from metric_name where name like 'cpu%')
    and ts between '2022-02-02 02:02:02+03' and '2022-02-03 02:02:02+03'
group by id
order by id
;

explain (costs off, verbose)
select id, max(value), count(*)
from metric_dist
where id in (select id from metric_name where name like 'cpu%')
    and ts between '2022-02-02 02:02:02+03' and '2022-02-03 02:02:02+03'
group by id
order by id
;


-- Shippable EC join
select name, max(value), count(*)
from metric_dist join metric_name using (id)
where name like 'cpu%'
    and ts between '2022-02-02 02:02:02+03' and '2022-02-03 02:02:02+03'
group by name
order by name
;

explain (costs off, verbose)
select name, max(value), count(*)
from metric_dist join metric_name using (id)
where name like 'cpu%'
    and ts between '2022-02-02 02:02:02+03' and '2022-02-03 02:02:02+03'
group by name
order by name
;


-- Non-shippable EC join
explain (costs off, verbose)
select name, max(value), count(*)
from metric_dist join metric_name on name = concat('cpu', metric_dist.id)
where ts between '2022-02-02 02:02:02+03' and '2022-02-03 02:02:02+03'
group by name
order by name
;


-- Shippable non-EC join. The weird condition is to only use immutable functions
-- that can be shipped to the remote node. `id::text` does CoerceViaIO which is
-- not generally shippable. And `int4out` returns cstring, not text, that's why
-- the `textin` is needed.
select name, max(value), count(*)
from metric_dist join metric_name
    on texteq('cpu' || textin(int4out(metric_dist.id)), name)
where ts between '2022-02-02 02:02:02+03' and '2022-02-03 02:02:02+03'
group by name
order by name
;

explain (costs off, verbose)
select name, max(value), count(*)
from metric_dist join metric_name
    on texteq('cpu' || textin(int4out(metric_dist.id)), name)
where ts between '2022-02-02 02:02:02+03' and '2022-02-03 02:02:02+03'
group by name
order by name
;


-- Non-shippable non-EC join.
explain (costs off, verbose)
select name, max(value), count(*)
from metric_dist join metric_name
    on texteq(concat('cpu', textin(int4out(metric_dist.id))), name)
where ts between '2022-02-02 02:02:02+03' and '2022-02-03 02:02:02+03'
group by name
order by name
;


-- distinct on, order by, limit 1, with subquery
select distinct on (id)
    id, ts, value
from metric_dist
where id in (select id from metric_name where name like 'cpu%')
    and ts between '2022-02-02 02:02:02+03' and '2022-02-03 02:02:02+03'
order by id, ts, value
limit 1
;

explain (costs off, verbose)
select distinct on (id)
    id, ts, value
from metric_dist
where id in (select id from metric_name where name like 'cpu%')
    and ts between '2022-02-02 02:02:02+03' and '2022-02-03 02:02:02+03'
order by id, ts, value
limit 1
;


-- distinct on, order by, limit 1, with explicit join
select distinct on (name)
    name, ts, value
from metric_dist join metric_name using (id)
where name like 'cpu%'
    and ts between '2022-02-02 02:02:02+03' and '2022-02-03 02:02:02+03'
order by name, ts, value
limit 1
;

explain (costs off, verbose)
select distinct on (name)
    name, ts, value
from metric_dist join metric_name using (id)
where name like 'cpu%'
    and ts between '2022-02-02 02:02:02+03' and '2022-02-03 02:02:02+03'
order by name, ts, value
limit 1
;


-- If the local table is very big, the parameterized nested loop might download
-- the entire dist table or even more than that (in case of not equi-join).
-- Check that the parameterized plan is not chosen in this case.
create table metric_name_big as select * from metric_name;
insert into metric_name_big select x, 'other' || x
    from generate_series(1000, 10000) x
;
analyze metric_name_big;

explain (costs off, verbose)
select name, max(value), count(*)
from metric_dist
join metric_name_big using (id)
where ts between '2022-02-02 02:02:02+03' and '2022-02-03 02:02:02+03'
group by name
order by name
;


-- An interesting special case is when the remote SQL has a parameter, but it is
-- the result of an initplan. It's not "parameterized" in the join sense, because
-- there is only one param value. This is the most efficient plan for querying a
-- small number of ids.
explain (costs off, verbose)
select id, max(value)
from metric_dist
where id = any((select array_agg(id) from metric_name where name like 'cpu%')::int[])
    and ts between '2022-02-02 02:02:02+03' and '2022-02-03 02:02:02+03'
group by id
order by id
;


-- Multiple joins. Test both EC and non-EC (texteq) join in one query.
create table metric_location(id int, location text);
insert into metric_location values (1, 'Yerevan'), (3, 'Dilijan'), (7, 'Stepanakert');
analyze metric_location;

select id, max(value)
from metric_dist natural join metric_location natural join metric_name
where name like 'cpu%' and texteq(location, 'Yerevan')
    and ts between '2022-02-02 02:02:02+03' and '2022-02-03 02:02:02+03'
group by id
;

explain (costs off, verbose)
select id, max(value)
from metric_dist natural join metric_location natural join metric_name
where name like 'cpu%' and texteq(location, 'Yerevan')
    and ts between '2022-02-02 02:02:02+03' and '2022-02-03 02:02:02+03'
group by id
;

-- Multiple joins on different variables. Use a table instead of a CTE for saner
-- stats.
create table max_value_times as
select distinct on (id) id, ts from metric_dist
where ts between '2022-02-02 02:02:02+03' and '2022-02-03 02:02:02+03'
order by id, value desc
;
analyze max_value_times;

explain (costs off, verbose)
select id, value
from metric_dist natural join max_value_times natural join metric_name
where name like 'cpu%'
order by 1
;
