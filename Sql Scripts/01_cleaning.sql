CREATE SCHEMA IF NOT EXISTS retail;

CREATE TABLE retail.stg_online_retail (
    invoice       TEXT,
    stock_code    TEXT,
    description   TEXT,
    quantity      TEXT,
    invoice_date  TEXT,
    price         TEXT,
    customer_id   TEXT,  
    country       TEXT
);

drop table if exists retail.cleaning_log;
drop table if exists retail.clean_transactions;
drop table if exists retail.returns;
drop table if exists retail.sales_no_customer;
drop table if exists retail.product_lookup;
 
-- keeping a log of how much I remove at each step for the readme
create table retail.cleaning_log (
    step_no          int,
    step_desc        text,
    rows_removed     bigint,
    revenue_removed  numeric(14,2),
    rows_remaining   bigint,
    logged_at        timestamp default now()
);
 
 
-- step 1: look at the raw data first
 
-- how big is it
select
    count(*)                     as total_rows,
    count(distinct invoice)      as distinct_invoices,
    count(distinct customer_id)  as distinct_customers,
    count(distinct stock_code)   as distinct_products,
    count(distinct country)      as distinct_countries
from retail.stg_online_retail;
 
-- missing or blank values in each column
select
    count(*) filter (where invoice      is null or trim(invoice)      = '') as invoice_missing,
    count(*) filter (where stock_code   is null or trim(stock_code)   = '') as stock_code_missing,
    count(*) filter (where description  is null or trim(description)  = '') as description_missing,
    count(*) filter (where quantity     is null or trim(quantity)     = '') as quantity_missing,
    count(*) filter (where invoice_date is null or trim(invoice_date) = '') as invoice_date_missing,
    count(*) filter (where price        is null or trim(price)        = '') as price_missing,
    count(*) filter (where customer_id  is null or trim(customer_id)  = '') as customer_id_missing,
    count(*) filter (where country      is null or trim(country)      = '') as country_missing
from retail.stg_online_retail;
 
-- how many cancelled invoices (start with C)
select count(*) as cancellation_rows
from retail.stg_online_retail
where invoice like 'C%';
 
select * from retail.stg_online_retail limit 20;
 
 
-- step 2: fix the data types
-- everything is text in staging so i need to convert it
 
-- check if the casts will work, i want all 4 to be 0
select
    count(*) filter (where quantity !~ '^-?[0-9]+$')                          as bad_quantity,
    count(*) filter (where price !~ '^-?[0-9]+(\.[0-9]+)?$')                  as bad_price,
    count(*) filter (where customer_id is not null
                       and trim(customer_id) <> ''
                       and customer_id !~ '^[0-9]+(\.0+)?$')                  as bad_customer_id,
    count(*) filter (where invoice_date !~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}(:\d{2})?$') as bad_invoice_date
from retail.stg_online_retail;
 
-- customer_id goes text -> numeric -> int because some look like 13085.0
create table retail.clean_transactions as
select
    trim(invoice)                                  as invoice,
    trim(stock_code)                               as stock_code,
    nullif(trim(description), '')                  as description,
    quantity::int                                  as quantity,
    invoice_date::timestamp                        as invoice_date,
    price::numeric                                 as price,
    nullif(trim(customer_id), '')::numeric::int    as customer_id,
    nullif(trim(country), '')                      as country
from retail.stg_online_retail;
 
-- first row of the log
insert into retail.cleaning_log (step_no, step_desc, rows_removed, revenue_removed, rows_remaining)
select 0, 'raw data loaded and typed', 0, 0, count(*)
from retail.clean_transactions;
 
-- min and max of the number columns and the date range
select
    min(quantity)     as min_qty,
    max(quantity)     as max_qty,
    min(price)        as min_price,
    max(price)        as max_price,
    min(invoice_date) as first_date,
    max(invoice_date) as last_date
from retail.clean_transactions;
 
-- zero or negative qty / price
select
    count(*) filter (where quantity <= 0) as qty_zero_or_negative,
    count(*) filter (where price    <= 0) as price_zero_or_negative
from retail.clean_transactions;
 
 
-- step 3: clean up the text
 
-- some stock codes have lowercase letters
select stock_code, count(*) as n
from retail.clean_transactions
where stock_code <> upper(stock_code)
group by stock_code
order by n desc
limit 20;
 
update retail.clean_transactions
set stock_code  = upper(trim(stock_code)),
    description = regexp_replace(trim(description), '\s+', ' ', 'g'),
    country     = trim(country);
 
 
-- step 4: missing customer ids
-- RFM and cohorts need a customer, so these rows can't be used for them
-- i'll save them in another table in case i need overall sales later
 
select
    count(*)                         as rows_without_customer,
    round(sum(quantity * price), 2)  as revenue_without_customer
from retail.clean_transactions
where customer_id is null;
 
create table retail.sales_no_customer as
select * from retail.clean_transactions
where customer_id is null;
 
-- delete and write it into the log in one go
with del as (
    delete from retail.clean_transactions
    where customer_id is null
    returning *
)
insert into retail.cleaning_log (step_no, step_desc, rows_removed, revenue_removed, rows_remaining)
select 4,
       'removed rows with no customer_id (saved in sales_no_customer)',
       count(*),
       round(sum(quantity * price), 2),
       (select count(*) from retail.clean_transactions) - count(*)
from del;
 
 
-- step 5: cancellations
-- invoices starting with C are cancellations with negative quantity
-- not throwing these away, i might use them for return rate later
 
select count(*) as cancellation_rows,
       min(quantity) as min_qty,
       max(quantity) as max_qty
from retail.clean_transactions
where invoice like 'C%';
 
create table retail.returns as
select * from retail.clean_transactions
where invoice like 'C%';
 
with del as (
    delete from retail.clean_transactions
    where invoice like 'C%'
    returning *
)
insert into retail.cleaning_log (step_no, step_desc, rows_removed, revenue_removed, rows_remaining)
select 5,
       'moved cancellations (invoice starts with C) to retail.returns',
       count(*),
       round(sum(quantity * price), 2),
       (select count(*) from retail.clean_transactions) - count(*)
from del;
 
 
-- step 6: bad quantity and price
 
select
    count(*) filter (where quantity <= 0) as bad_qty,
    count(*) filter (where price    <= 0) as bad_price
from retail.clean_transactions;
 
-- look at the rows before deleting
select * from retail.clean_transactions
where quantity <= 0 or price <= 0
order by invoice_date
limit 30;
 
-- zero price rows look like giveaways / adjustments, no real revenue so removing them
with del as (
    delete from retail.clean_transactions
    where quantity <= 0 or price <= 0
    returning *
)
insert into retail.cleaning_log (step_no, step_desc, rows_removed, revenue_removed, rows_remaining)
select 6,
       'removed rows with quantity <= 0 or price <= 0',
       count(*),
       round(coalesce(sum(quantity * price), 0), 2),
       (select count(*) from retail.clean_transactions) - count(*)
from del;
 
 
-- step 7: stock codes that aren't products
-- postage, fees, manual entries etc. would mess up frequency and monetary
 
-- normal product code = 5 digits + maybe some letters, so show everything else
-- need to read this list properly before deleting
select
    stock_code,
    min(description)                 as sample_description,
    count(*)                         as n_rows,
    round(sum(quantity * price), 2)  as revenue
from retail.clean_transactions
where stock_code !~ '^[0-9]{5}[A-Z]{0,2}$'
group by stock_code
order by n_rows desc;
 
-- codes i decided to remove after checking the list above
-- (POST postage, D discount, M manual, DOT dotcom postage, C2 carriage,
-- CRUK charity, AMAZONFEE, ADJUST, TEST etc.)
with del as (
    delete from retail.clean_transactions
    where stock_code in ('POST', 'D', 'DOT', 'M', 'C2', 'CRUK', 'BANK CHARGES',
                         'PADS', 'AMAZONFEE', 'ADJUST', 'ADJUST2', 'S', 'B',
                         'SP1002', 'TEST001', 'TEST002')
       or stock_code like 'GIFT\_%'
    returning *
)
insert into retail.cleaning_log (step_no, step_desc, rows_removed, revenue_removed, rows_remaining)
select 7,
       'removed non-product stock codes (postage, fees, manual, test, gift vouchers)',
       count(*),
       round(sum(quantity * price), 2),
       (select count(*) from retail.clean_transactions) - count(*)
from del;
 
-- run the first query of this step again to see if anything weird is left
 
 
-- step 8: duplicates
 
-- how many extra copies are there
select count(*) as duplicate_rows
from (
    select row_number() over (
               partition by invoice, stock_code, description, quantity,
                            invoice_date, price, customer_id, country
               order by ctid
           ) as rn
    from retail.clean_transactions
) x
where rn > 1;
 
-- look at some of them
select invoice, stock_code, quantity, invoice_date, price, customer_id, count(*) as copies
from retail.clean_transactions
group by invoice, stock_code, description, quantity, invoice_date, price, customer_id, country
having count(*) > 1
order by copies desc
limit 20;
 
-- same invoice, product, qty, price and exact same timestamp, so i'm treating them as
-- entry mistakes. keeping one copy
with ranked as (
    select ctid as rid,
           row_number() over (
               partition by invoice, stock_code, description, quantity,
                            invoice_date, price, customer_id, country
               order by ctid
           ) as rn
    from retail.clean_transactions
),
del as (
    delete from retail.clean_transactions t
    using ranked r
    where t.ctid = r.rid
      and r.rn > 1
    returning t.*
)
insert into retail.cleaning_log (step_no, step_desc, rows_removed, revenue_removed, rows_remaining)
select 8,
       'removed exact duplicate rows (kept one copy)',
       count(*),
       round(sum(quantity * price), 2),
       (select count(*) from retail.clean_transactions) - count(*)
from del;
 
 
-- step 9: outliers
 
-- biggest quantities
select invoice, stock_code, description, quantity, price, invoice_date, customer_id
from retail.clean_transactions
order by quantity desc
limit 20;
 
-- biggest line values
select invoice, stock_code, description, quantity, price,
       round(quantity * price, 2) as line_value, customer_id
from retail.clean_transactions
order by quantity * price desc
limit 20;
 
-- were the huge orders cancelled later? same customer, same product, opposite qty
select t.invoice, t.stock_code, t.description, t.quantity,
       r.invoice as return_invoice, r.quantity as return_qty
from retail.clean_transactions t
join retail.returns r
  on  r.customer_id = t.customer_id
  and r.stock_code  = t.stock_code
  and r.quantity    = -t.quantity
where t.quantity >= 1000
order by t.quantity desc;
 
-- removing the huge ones that got cancelled, they look like mistakes
-- change the 10000 if my data looks different
with del as (
    delete from retail.clean_transactions
    where quantity >= 10000
    returning *
)
insert into retail.cleaning_log (step_no, step_desc, rows_removed, revenue_removed, rows_remaining)
select 9,
       'removed extreme quantity orders (>= 10000 units, cancelled later)',
       count(*),
       round(coalesce(sum(quantity * price), 0), 2),
       (select count(*) from retail.clean_transactions) - count(*)
from del;
 
 
-- step 10: descriptions and countries
 
-- some stock codes have more than one description
select stock_code, count(distinct description) as n_descriptions
from retail.clean_transactions
group by stock_code
having count(distinct description) > 1
order by n_descriptions desc
limit 20;
 
-- use the most common description for each stock code
create table retail.product_lookup as
select stock_code, description
from (
    select stock_code,
           description,
           row_number() over (
               partition by stock_code
               order by count(*) desc, description
           ) as rn
    from retail.clean_transactions
    where description is not null
    group by stock_code, description
) x
where rn = 1;
 
update retail.clean_transactions t
set description = p.description
from retail.product_lookup p
where t.stock_code = p.stock_code
  and t.description is distinct from p.description;
 
-- countries
select country, count(*) as n_rows, count(distinct customer_id) as customers
from retail.clean_transactions
group by country
order by n_rows desc;
 
-- EIRE is Ireland and RSA is South Africa
update retail.clean_transactions
set country = case country
                  when 'EIRE' then 'Ireland'
                  when 'RSA'  then 'South Africa'
                  else country
              end
where country in ('EIRE', 'RSA');
 
 
-- step 11: new columns i'll need later
-- line_revenue for monetary, invoice_day and invoice_month for the cohorts
alter table retail.clean_transactions
    add column line_revenue  numeric(12,2) generated always as (round(quantity * price, 2)) stored,
    add column invoice_day   date          generated always as (invoice_date::date) stored,
    add column invoice_month date          generated always as (date_trunc('month', invoice_date)::date) stored;
 
-- primary key and indexes so the later queries run faster
alter table retail.clean_transactions add column row_id bigserial primary key;
create index idx_clean_customer on retail.clean_transactions (customer_id);
create index idx_clean_invdate  on retail.clean_transactions (invoice_date);
 
vacuum analyze retail.clean_transactions;
 
 
-- step 12: final checks
 
-- nulls, everything should be 0
select
    count(*) filter (where invoice      is null) as null_invoice,
    count(*) filter (where stock_code   is null) as null_stock_code,
    count(*) filter (where description  is null) as null_description,
    count(*) filter (where quantity     is null) as null_quantity,
    count(*) filter (where invoice_date is null) as null_invoice_date,
    count(*) filter (where price        is null) as null_price,
    count(*) filter (where customer_id  is null) as null_customer_id,
    count(*) filter (where country      is null) as null_country
from retail.clean_transactions;
 
-- no bad values or cancellations left, both 0
select
    count(*) filter (where quantity <= 0 or price <= 0) as bad_values,
    count(*) filter (where invoice like 'C%')           as cancellations_left
from retail.clean_transactions;
 
-- final numbers
select
    count(*)                     as final_rows,
    count(distinct invoice)      as invoices,
    count(distinct customer_id)  as customers,
    count(distinct stock_code)   as products,
    min(invoice_date)            as first_date,
    max(invoice_date)            as last_date,
    sum(line_revenue)            as total_revenue
from retail.clean_transactions;
 
-- the log, going into the readme
select step_no, step_desc, rows_removed, revenue_removed, rows_remaining
from retail.cleaning_log
order by step_no;
 
-- raw revenue should be about removed + final (small rounding difference is ok)
select
    (select round(sum(quantity::int * price::numeric), 2) from retail.stg_online_retail) as raw_revenue,
    (select sum(revenue_removed) from retail.cleaning_log)                               as removed_revenue,
    (select sum(line_revenue) from retail.clean_transactions)                            as final_revenue;
 
 
 