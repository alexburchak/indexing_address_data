create extension if not exists citext;

create table country (
	id int4 not null,
	name varchar(20) not null,
	constraint pk_country primary key (id)
);

create table "area" (
	id serial not null,
	country_id int4 not null,
	"key" jsonb null,
	type varchar(20) not null,
	name varchar(100) not null,
	alt_name varchar(100) null,
	status varchar(20) not null,
	constraint pk_area_id primary key (id)
);

create index idx_area_key
    on "area" using btree ("key");

alter table "area"
    add constraint fk_zone_country foreign key (country_id) references country(id);

create table building (
	id serial not null,
	country_id int4 not null,
	"key" jsonb not null,
	house_number varchar(20) null,
	house_letter citext null,
	status varchar(20) not null,
	constraint pk_building_id primary key (id)
);

create index idx_building_countryid_status_key_housenumberletter
    on building using btree (country_id, status, key, house_number, house_letter);

alter table building
    add constraint fk_addressplace_country foreign key (country_id) references country(id);

\copy country from '/docker-entrypoint-initdb.d/dump/country.csv' with (format csv, header true);
\copy "area" from '/docker-entrypoint-initdb.d/dump/area.csv' with (format csv, header true);
\copy building from '/docker-entrypoint-initdb.d/dump/building.csv' with (format csv, header true);
