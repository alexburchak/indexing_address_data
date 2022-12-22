## An address search

A search functionality is important for websites and applications to improve user experience. Some domain areas have
specifics that introduce additional requirements. This article is completely dedicated to the address search and one
of the possible approaches to store address data, to make that search possible.

It is clear that for different countries the address structure may, and it does differ - municipalities, postal
codes, regions, cities, districts, streets etc etc etc. A building location can be described using a number of the
"coordinates" listed above - and in many cases these "coordinates" are country specific.

If you live in Ukraine, you need to know a region (oblast'), a city, optionally a district (rayon), a street and a house
number and (optionally) letter. A postal code is also optional unless you want to send a slow mail. A street can be located
in different postal codes, split by different districts. The same is quite true for Denmark for example. But there is a
difference is in which "coordinates" are valid for Ukraine and which are valid for Denmark.

This gives us the first hint - in requirements we must define which "coordicates" are valid for which country. For
Denmark, we have to deal with municipality, postal code and street. Let's focus on Denmark.

What wee also need to know the exact format and values for each. We can refer to the publicly available registry -
[Datafordeler](https://selfservice.datafordeler.dk/) - for the data. Each municipality has a unique 4-digit code, each
postal code has a unique 4-digit code, and each street has a unique 4-digit code. The important thing here is that a street
can be split between multiple municipalities and multiple postal codes at the same time! For example, a street split between
2 municipalities and 3 postal codes can have 6! parts and each of them is sharing the same name.

If we had to implement a search by a city name, a street name and a house number prefix, the result set might contain
different coordinates (municipality code + postal code + street code). We should store these parts separately, as any moment
any of them can change its name, independently of the other parts.

## Data structure choices

Which data structure might help us keep country-specific coordinates in the same table, for different countries?

One of the approaches might be using a distinct column for each "coordinate". The search query could be built 
programmatically, according to the country format requirements. The problem with this approach is that we have to
maintain a lot of indexes, in different combinations. These indexes would occupy a lot of disk space, and it would be
a challenge to make PostgreSQL choose the proper one, for each country specific search query.

Fortunately, PostgreSQL offers a JSONB type, which can be indexed, and different operators allow to check for equality
and if the value contains the target entries (our "coordinates"). Thus, we will have a single GIN index onb a single
column.

In the [init-database.sql](docker/init-database.sql) script you may find our test schema. It creates a _building_ table
with a _key_ column of JSONB type, with the "coordinates". Each _building_ key should have a corresponding record in 
_area_ table, with the same key, for type _STREET_. To store a municipality and postal code, we need records of type
'MUNICIPALITY' and 'POSTAL', respectively. Each area entry has a name and an optional historical name (_alt_name_),
so that we may search by any of them. Below is an example of three rows which define a street _10. Februar Vej_ located
in _Kolding_ municipality and postal code _6070_ (which belongs to city _Christiansfeld_):

| id   | country_id | key                                           | type         | name            | alt_name | status |
|------|------------|-----------------------------------------------|--------------|-----------------|----------|--------|
| 787  | 1          | {"pst": "6070"}                               | POSTAL       | Christiansfeld  |          | VALID  |
| 1182 | 1          | {"mun": "0621"}                               | MUNICIPALITY | Kolding         |          | VALID  |
| 1191 | 1          | {"mun": "0621", "str": "1133", "pst": "6070"} | STREET       | 10. Februar Vej |          | VALID  |

This is a very flexible way to manage address data, and can be applied even to virtual addresses in virtual countries.
It can be even applied to private apartments within a Building!

## Dataset preparation

For testing purposes, start a new PostgreSQL Docker container:

```shell
cd docker && unzip -n dump.zip && docker-compose up -d --remove
```

That will create three database tables: _country_, _area_ and _building_, which we will use in our queries.
Also, the tables get populated with test data obtained from the national address registry (DAR):
[Datafordeler](https://selfservice.datafordeler.dk/). The dump file for [buildings](docker/dump/building.csv) contains
approximately 2.5M records, which is a good number for the tests.

Here is a short summary on area types ():

```sql
select type, count(*)
    from "area"
    group by type
    order by 2;
```

| type         | count  |
|--------------|--------|
| COUNTRY      | 1      |
| MUNICIPALITY | 99     |
| POSTAL       | 1089   |
| STREET       | 110511 |

## A straightforward solution

The first and easy to implement solution that comes to mind, is to find the building that strictly matches the search
criteria, using = operator:

```sql
explain (analyze, buffers)
select b.id, a1.name, a2.name, b.house_number, b.house_letter, b.key
    from building b
        inner join "area" a1
        on a1.country_id=1 and a1.type='POSTAL' and a1.status<>'DISCONTINUED'
    inner join "area" a2
        on a2.country_id=1 and a2.type='STREET' and a2.status<>'DISCONTINUED'
    where
        -- address place
        b.country_id=1 and b.status='VALID' and b.house_number='7' and b.house_letter is null
        -- postal code/postal place
        and a1.key->>'pst'=b.key->>'pst'
        and (a1.key->>'pst'='3230' or a1.name='Græsted')
        -- street
        and a2.key=b.key and a2.name='Skovbovej'
    order by lower(a1.name) asc, lower(a2.alt_name) asc, b.id asc;
```

The query execution plan shows that we have two sequential scans on _area_ table and are missing indexes on _status_,
_country_id_, _type_ and _key_:

```
Sort  (cost=7134.11..7134.11 rows=1 width=146) (actual time=17.510..19.021 rows=1 loops=1)
  Sort Key: (lower((a1.name)::text)), (lower((a2.alt_name)::text)), b.id
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=3251 read=53 dirtied=1
  ->  Gather  (cost=3911.32..7134.10 rows=1 width=146) (actual time=10.802..19.002 rows=1 loops=1)
        Workers Planned: 1
        Workers Launched: 1
        Buffers: shared hit=3248 read=53 dirtied=1
        ->  Parallel Hash Join  (cost=2911.32..6134.00 rows=1 width=146) (actual time=12.618..15.937 rows=0 loops=2)
              Hash Cond: ((a1.key ->> 'pst'::text) = (b.key ->> 'pst'::text))
              Buffers: shared hit=3248 read=53 dirtied=1
>>> A slow sequential scan is being performed 
              ->  Parallel Seq Scan on area a1  (cost=0.00..3222.65 rows=3 width=61) (actual time=3.436..6.754 rows=0 loops=2)
                    Filter: (((status)::text <> 'DISCONTINUED'::text) AND (country_id = 1) AND ((type)::text = 'POSTAL'::text) AND (((key ->> 'pst'::text) = '3230'::text) OR ((name)::text = 'Græsted'::text)))
                    Rows Removed by Filter: 55850
                    Buffers: shared hit=1580
<<<
              ->  Parallel Hash  (cost=2911.30..2911.30 rows=1 width=288) (actual time=8.998..8.999 rows=7 loops=2)
                    Buckets: 1024  Batches: 1  Memory Usage: 40kB
                    Buffers: shared hit=1624 read=53 dirtied=1
                    ->  Nested Loop  (cost=0.56..2911.30 rows=1 width=288) (actual time=8.009..8.969 rows=7 loops=2)
                          Buffers: shared hit=1624 read=53 dirtied=1
>>> A slow sequential scan is being performed 
                          ->  Parallel Seq Scan on area a2  (cost=0.00..2894.12 rows=2 width=279) (actual time=7.870..8.622 rows=10 loops=2)
                                Filter: (((status)::text <> 'DISCONTINUED'::text) AND (country_id = 1) AND ((type)::text = 'STREET'::text) AND ((name)::text = 'Skovbovej'::text))
                                Rows Removed by Filter: 55840
                                Buffers: shared hit=1580
<<<
                          ->  Index Scan using idx_building_countryid_status_key_housenumberletter on building b  (cost=0.56..8.58 rows=1 width=58) (actual time=0.034..0.034 rows=1 loops=20)
                                Index Cond: ((country_id = 1) AND ((status)::text = 'VALID'::text) AND (key = a2.key) AND ((house_number)::text = '7'::text) AND (house_letter IS NULL))
                                Buffers: shared hit=44 read=53 dirtied=1
Planning Time: 1.061 ms
Execution Time: 19.060 ms
```

Let's think of which columns should be in the index. As we have imported an initial dump for the buildings, we have 100%
of them in status _VALID_. With time, as we update our local database with changed from the DAR (the service allows to
download fresh dumps and/or subscribe for the changes), with time we will discover that some of the buildings get 
discontinued or abandoned, and some new buildings get created in status _VALID_ or _PRELIMINARY_.
Despite this, it may take years to get buildings in status other than _VALID_ close even to 1% of the total number of
buildings. It means, we can create our index without a _status_ column - this will save some space occupied by the
_building_ table, and PostgreSQL will filter the buildings later:

```sql
create index idx_area_countryid_type_name
    on "area" using btree (country_id, type, name);
```

Execute the query again. As expected, the query uses the new index, and we significantly reduced number of IO operations
and sped up the query:

```
Sort  (cost=1451.92..1451.93 rows=1 width=146) (actual time=1.070..1.072 rows=1 loops=1)
  Sort Key: (lower((a1.name)::text)), (lower((a2.alt_name)::text)), b.id
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=575 read=11
  ->  Nested Loop  (cost=1.39..1451.91 rows=1 width=146) (actual time=0.452..1.063 rows=1 loops=1)
        Join Filter: ((b.key ->> 'pst'::text) = (a1.key ->> 'pst'::text))
        Rows Removed by Join Filter: 13
        Buffers: shared hit=575 read=11
>>> The index is being applied 
        ->  Index Scan using "idx_area_countryid_type_name" on area a1  (cost=0.42..1403.56 rows=5 width=61) (actual time=0.207..0.657 rows=1 loops=1)
              Index Cond: ((country_id = 1) AND ((type)::text = 'POSTAL'::text))
              Filter: (((status)::text <> 'DISCONTINUED'::text) AND (((key ->> 'pst'::text) = '3230'::text) OR ((name)::text = 'Græsted'::text)))
              Rows Removed by Filter: 1088
              Buffers: shared hit=479 read=8
<<<
        ->  Materialize  (cost=0.97..48.15 rows=2 width=288) (actual time=0.055..0.391 rows=14 loops=1)
              Buffers: shared hit=96 read=3
              ->  Nested Loop  (cost=0.97..48.14 rows=2 width=288) (actual time=0.052..0.381 rows=14 loops=1)
                    Buffers: shared hit=96 read=3
>>> The index is being applied 
                    ->  Index Scan using "idx_area_countryid_type_name" on area a2  (cost=0.42..13.77 rows=4 width=279) (actual time=0.026..0.042 rows=20 loops=1)
                          Index Cond: ((country_id = 1) AND ((type)::text = 'STREET'::text) AND ((name)::text = 'Skovbovej'::text))
                          Filter: ((status)::text <> 'DISCONTINUED'::text)
                          Buffers: shared hit=2 read=3
<<<
                    ->  Index Scan using idx_building_countryid_status_key_housenumberletter on building b  (cost=0.56..8.58 rows=1 width=58) (actual time=0.016..0.016 rows=1 loops=20)
                          Index Cond: ((country_id = 1) AND ((status)::text = 'VALID'::text) AND (key = a2.key) AND ((house_number)::text = '7'::text) AND (house_letter IS NULL))
                          Buffers: shared hit=94
Planning Time: 1.014 ms
Execution Time: 1.113 ms
```

Now, we get a new requirement. We want to give a user an option to make an inexact search - they want to see search
results as they type in a city name or a street name. The search should be fast enough, to provide better user
experience. And we want to search using historical names (_alt_name_ column in the _area_ table). 

We think of adding a GIN index for the text search - it will require a function on both _name_ and _alt_name_:

```sql
create or replace function name_altname_vector(name varchar, alt_name varchar)
    returns tsvector as $$
begin
    return to_tsvector('simple', regexp_replace(name || ' ' || coalesce(alt_name, ''), '[\.,\s]+', ' ', 'g'));
end;
$$ language plpgsql immutable;
```

Next, the search will also require a new index, as from the _idx_area_countryid_type_name_ only _country_id_ and _type_
can be used.
Let's drop the index and create a new one:

```sql
create index idx_area_namealtnamevector
  on "area" using gin (name_altname_vector(name, alt_name));

explain (analyze, buffers)
select b.id, a1.name, a2.name, b.house_number, b.house_letter, b.key
    from building b
    cross join "area" a1
    cross join "area" a2
    where
        -- address place
        b.country_id=1 and b.status='VALID' and b.house_number='7' and b.house_letter is null
        -- postal code/postal place
        and a1.country_id=1 and a1.type='POSTAL' and a1.status<>'DISCONTINUED'
        and a1.key->>'pst'=b.key->>'pst'
        and (a1.key->>'pst'='3230' or name_altname_vector(a1.name, a1.alt_name) @@ to_tsquery('simple', 'Græ:*'))
        -- street
        and a2.country_id=1 and a2.type='STREET' and a2.status<>'DISCONTINUED'
        and a2.key=b.key
        and name_altname_vector(a2.name, a2.alt_name) @@ to_tsquery('simple', 'Skovb:*')
        order by lower(a1.name) asc, lower(a2.alt_name) asc, b.id asc;
```

You might notice only the _name_altname_vector_ function was not used - that's because we can not combine GIN and BTREE
indexes and thus PostgresSQL chooses one of them - the _idx_area_countryid_type_name_. The _idx_area_namealtnamevector_
index was not used and instead the rows were filtered using an extra filter condition. Thousands of rows were read just
to be thrown away:

```
Sort  (cost=42.37..42.37 rows=1 width=626) (actual time=1082.769..1082.771 rows=2 loops=1)
  Sort Key: (lower((a1.name)::text)), (lower((a2.alt_name)::text)), b.id
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=6709 read=1058 dirtied=168
  ->  Nested Loop  (cost=9.45..42.36 rows=1 width=626) (actual time=455.222..1082.760 rows=2 loops=1)
        Join Filter: ((b.key ->> 'pst'::text) = (a1.key ->> 'pst'::text))
        Rows Removed by Join Filter: 213
        Buffers: shared hit=6709 read=1058 dirtied=168
        ->  Nested Loop  (cost=5.00..25.46 rows=1 width=562) (actual time=17.404..328.478 rows=215 loops=1)
              Buffers: shared hit=2630 read=1052 dirtied=168
>>> The index is being applied, but the filter is doing a lot of extra work removing the rows that do not match the search condition
              ->  Bitmap Heap Scan on area a2  (cost=4.45..16.87 rows=1 width=468) (actual time=17.168..320.526 rows=328 loops=1)
                    Recheck Cond: ((country_id = 1) AND ((type)::text = 'STREET'::text))
                    Filter: (((status)::text <> 'DISCONTINUED'::text) AND (name_altname_vector(name, alt_name) @@ '''skovb'':*'::tsquery))
                    Rows Removed by Filter: 110183
                    Heap Blocks: exact=1569
                    Buffers: shared hit=1569 read=583
                    ->  Bitmap Index Scan on idx_area_countryid_type_name  (cost=0.00..4.45 rows=3 width=0) (actual time=12.260..12.261 rows=110511 loops=1)
                          Index Cond: ((country_id = 1) AND ((type)::text = 'STREET'::text))
                          Buffers: shared read=583
<<<
              ->  Index Scan using idx_building_countryid_status_key_housenumberletter on building b  (cost=0.55..8.58 rows=1 width=126) (actual time=0.023..0.023 rows=1 loops=328)
                    Index Cond: ((country_id = 1) AND ((status)::text = 'VALID'::text) AND (key = a2.key) AND ((house_number)::text = '7'::text) AND (house_letter IS NULL))
                    Buffers: shared hit=1061 read=469 dirtied=168
>>> The index is being applied, but the filter is doing a lot of extra work removing the rows that do not match the search condition
        ->  Bitmap Heap Scan on area a1  (cost=4.45..16.88 rows=1 width=250) (actual time=2.002..3.506 rows=1 loops=215)
              Recheck Cond: ((country_id = 1) AND ((type)::text = 'POSTAL'::text))
              Filter: (((status)::text <> 'DISCONTINUED'::text) AND (((key ->> 'pst'::text) = '3230'::text) OR (name_altname_vector(name, alt_name) @@ '''græ'':*'::tsquery)))
              Rows Removed by Filter: 1088
              Heap Blocks: exact=2365
              Buffers: shared hit=4079 read=6
              ->  Bitmap Index Scan on idx_area_countryid_type_name  (cost=0.00..4.45 rows=3 width=0) (actual time=0.052..0.052 rows=1089 loops=215)
                    Index Cond: ((country_id = 1) AND ((type)::text = 'POSTAL'::text))
                    Buffers: shared hit=1714 read=6
<<<
Planning Time: 0.967 ms
Execution Time: 1082.811 ms
```

There is an extension for PostgreSQL that provides a GIN operator classes that implement BTREE equivalent behavior,
which we may apply to our index, to speed up the index check part of the query. To make it work, we need to drop both of
the indexes and create a new one:

```sql
drop index idx_area_countryid_type_name;

drop index idx_area_namealtnamevector;

create extension btree_gin;
create index idx_area_namealtnamevector_countryid_type
    on "area" using gin (name_altname_vector(name, alt_name), country_id, type);
```

The execution plan shows that the new index is used, to find rows by the street name, _country_id_ and _type_, within
the same index condition:

```
Sort  (cost=22620.60..22620.72 rows=48 width=146) (actual time=9.849..9.851 rows=2 loops=1)
  Sort Key: (lower((a1.name)::text)), (lower((a2.alt_name)::text)), b.id
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=1618
  ->  Hash Join  (cost=1871.66..22619.26 rows=48 width=146) (actual time=7.010..9.843 rows=2 loops=1)
        Hash Cond: ((b.key ->> 'pst'::text) = (a1.key ->> 'pst'::text))
        Buffers: shared hit=1618
        ->  Nested Loop  (cost=68.74..20796.63 rows=1381 width=288) (actual time=0.715..4.625 rows=215 loops=1)
              Buffers: shared hit=1587
>>> The new index is being applied, resulting to 
              ->  Bitmap Heap Scan on area a2  (cost=68.18..2327.21 rows=2210 width=279) (actual time=0.683..0.745 rows=328 loops=1)
                    Recheck Cond: ((name_altname_vector(name, alt_name) @@ '''skovb'':*'::tsquery) AND (country_id = 1) AND ((type)::text = 'STREET'::text))
                    Filter: ((status)::text <> 'DISCONTINUED'::text)
                    Heap Blocks: exact=17
                    Buffers: shared hit=60
                    ->  Bitmap Index Scan on idx_area_namealtnamevector_countryid_type  (cost=0.00..67.63 rows=2210 width=0) (actual time=0.676..0.676 rows=328 loops=1)
                          Index Cond: ((name_altname_vector(name, alt_name) @@ '''skovb'':*'::tsquery) AND (country_id = 1) AND ((type)::text = 'STREET'::text))
                          Buffers: shared hit=43
<<<
              ->  Index Scan using idx_building_countryid_status_key_housenumberletter on building b  (cost=0.56..8.35 rows=1 width=58) (actual time=0.011..0.011 rows=1 loops=328)
                    Index Cond: ((country_id = 1) AND ((status)::text = 'VALID'::text) AND (key = a2.key) AND ((house_number)::text = '7'::text) AND (house_letter IS NULL))
                    Buffers: shared hit=1527
        ->  Hash  (cost=1802.59..1802.59 rows=26 width=61) (actual time=5.151..5.152 rows=1 loops=1)
              Buckets: 1024  Batches: 1  Memory Usage: 9kB
              Buffers: shared hit=31
>>> The new index is being applied but due to a complex condition on "key"->>'pst'=? OR name_altname_vector(name, alt_name) @@ ? a lot of rows are thrown away in the filter
              ->  Bitmap Heap Scan on area a1  (cost=30.51..1802.59 rows=26 width=61) (actual time=3.373..5.149 rows=1 loops=1)
                    Recheck Cond: ((country_id = 1) AND ((type)::text = 'POSTAL'::text))
                    Filter: (((status)::text <> 'DISCONTINUED'::text) AND (((key ->> 'pst'::text) = '3230'::text) OR (name_altname_vector(name, alt_name) @@ '''græ'':*'::tsquery)))
                    Rows Removed by Filter: 1088
                    Heap Blocks: exact=11
                    Buffers: shared hit=31
                    ->  Bitmap Index Scan on idx_area_namealtnamevector_countryid_type  (cost=0.00..30.50 rows=1050 width=0) (actual time=0.207..0.207 rows=1089 loops=1)
                          Index Cond: ((country_id = 1) AND ((type)::text = 'POSTAL'::text))
                          Buffers: shared hit=9
Planning Time: 1.261 ms
Execution Time: 9.933 ms
```

To deal with this new problem, when a lot of result rows do not match the filter condition, we create an additional
BTREE index, to cover the postal code match condition. We will have to have a distinct index for each :

```sql
create index idx_area_countryid_postal
    on "area" using btree (country_id, (key->>'pst')) 
    where type='POSTAL';
create index idx_area_countryid_municipality
    on "area" using btree (country_id, (key->>'mun')) 
    where type='MUNICIPALITY';
```

This time, 

```
Sort  (cost=20963.76..20963.88 rows=48 width=146) (actual time=7.573..7.577 rows=2 loops=1)
  Sort Key: (lower((a1.name)::text)), (lower((a2.alt_name)::text)), b.id
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=1605
  ->  Hash Join  (cost=214.81..20962.41 rows=48 width=146) (actual time=2.710..7.566 rows=2 loops=1)
        Hash Cond: ((b.key ->> 'pst'::text) = (a1.key ->> 'pst'::text))
        Buffers: shared hit=1605
        ->  Nested Loop  (cost=68.74..20796.63 rows=1381 width=288) (actual time=0.727..7.352 rows=215 loops=1)
              Buffers: shared hit=1587
              ->  Bitmap Heap Scan on area a2  (cost=68.18..2327.21 rows=2210 width=279) (actual time=0.694..0.792 rows=328 loops=1)
                    Recheck Cond: ((name_altname_vector(name, alt_name) @@ '''skovb'':*'::tsquery) AND (country_id = 1) AND ((type)::text = 'STREET'::text))
                    Filter: ((status)::text <> 'DISCONTINUED'::text)
                    Heap Blocks: exact=17
                    Buffers: shared hit=60
                    ->  Bitmap Index Scan on idx_area_namealtnamevector_countryid_type  (cost=0.00..67.63 rows=2210 width=0) (actual time=0.687..0.687 rows=328 loops=1)
                          Index Cond: ((name_altname_vector(name, alt_name) @@ '''skovb'':*'::tsquery) AND (country_id = 1) AND ((type)::text = 'STREET'::text))
                          Buffers: shared hit=43
              ->  Index Scan using idx_building_countryid_status_key_housenumberletter on building b  (cost=0.56..8.35 rows=1 width=58) (actual time=0.019..0.019 rows=1 loops=328)
                    Index Cond: ((country_id = 1) AND ((status)::text = 'VALID'::text) AND (key = a2.key) AND ((house_number)::text = '7'::text) AND (house_letter IS NULL))
                    Buffers: shared hit=1527
        ->  Hash  (cost=145.75..145.75 rows=26 width=61) (actual time=0.110..0.111 rows=1 loops=1)
              Buckets: 1024  Batches: 1  Memory Usage: 9kB
              Buffers: shared hit=18
>>> The indexes are being OR-ed and there are much fewer rows that are being thrown away by the filter condition
              ->  Bitmap Heap Scan on area a1  (cost=44.60..145.75 rows=26 width=61) (actual time=0.105..0.107 rows=1 loops=1)
                    Recheck Cond: (((country_id = 1) AND ((key ->> 'pst'::text) = '3230'::text) AND ((type)::text = 'POSTAL'::text)) OR ((name_altname_vector(name, alt_name) @@ '''græ'':*'::tsquery) AND (country_id = 1) AND ((type)::text = 'POSTAL'::text)))
                    Filter: ((status)::text <> 'DISCONTINUED'::text)
                    Heap Blocks: exact=1
                    Buffers: shared hit=18
                    ->  BitmapOr  (cost=44.60..44.60 rows=26 width=0) (actual time=0.102..0.102 rows=0 loops=1)
                          Buffers: shared hit=17
                          ->  Bitmap Index Scan on area_countryid_postal  (cost=0.00..4.33 rows=5 width=0) (actual time=0.006..0.006 rows=1 loops=1)
                                Index Cond: ((country_id = 1) AND ((key ->> 'pst'::text) = '3230'::text))
                                Buffers: shared hit=2
                          ->  Bitmap Index Scan on idx_area_namealtnamevector_countryid_type  (cost=0.00..40.26 rows=21 width=0) (actual time=0.095..0.096 rows=1 loops=1)
                                Index Cond: ((name_altname_vector(name, alt_name) @@ '''græ'':*'::tsquery) AND (country_id = 1) AND ((type)::text = 'POSTAL'::text))
                                Buffers: shared hit=15
<<<
Planning Time: 1.092 ms
Execution Time: 7.640 ms
```

Thankfully to the _type='POSTAL'_ condition in both the query and the partial index, PostgreSQL chooses the correct index
, for the postal code "coordinate".

The results are more than satisfying and are close to the exact search!

## How much does it cost?

The following queries will give us information on huw much disk space we spend on the tables and the indexes. It is
clear that the largest index corresponds to the largest table.

```sql
select relname, pg_size_pretty (pg_table_size (relname::regclass)) as size
    from pg_stat_all_tables
    where schemaname = 'public'
    order by pg_table_size (relname::regclass) desc;;

select relname, indexrelname, pg_size_pretty(pg_relation_size(indexrelname::regclass)) as size
    from pg_stat_all_indexes
    where schemaname = 'public' and indexrelname like 'idx\_%'
    order by pg_relation_size(indexrelname::regclass) desc;
```

| relname  | size       |
|----------|------------|
| building | 243 MB     |
| area     | 12 MB      |
| country  | 8192 bytes |

| relname  | indexrelname                                        | size    |
|----------|-----------------------------------------------------|---------|
| building | idx_building_countryid_status_key_housenumberletter | 338 MB  |
| area     | idx_area_key                                        | 14 MB   |
| area     | idx_area_namealtnamevector_countryid_type           | 3848 kB |
| area     | idx_area_countryid_postal                           | 56 kB   |
| area     | idx_area_countryid_municipality                     | 16 kB   |

## What's next?

All the search queries above used a street _name_ to sort result set in some repeatable order. But to improve usability,
we might order the result depending on how close the address to the user is. It is most likely that the user wants to
search for a street nearby than in some other city, moreover located a hundred miles away.

So, what about using geo-coordinates, to prioritize search results? This topic requires another blog entry )
