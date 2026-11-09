drop table if exists retail.cohort_segments;
drop table if exists retail.second_order;
drop table if exists retail.customer_orders;
drop table if exists retail.cohort_revenue;
drop table if exists retail.cohort_retention;
drop table if exists retail.cohort_activity;
drop table if exists retail.cohort_size;
drop table if exists retail.customer_cohorts;
 
 
-- step 1: give every customer a cohort
-- cohort = the month of their first ever purchase
create table retail.customer_cohorts as
select
    customer_id,
    min(invoice_month) as cohort_month
from retail.clean_transactions
group by customer_id;
 
alter table retail.customer_cohorts add primary key (customer_id);
 
-- how many new customers per month
-- 1) the data starts in dec 2009 so the dec 2009 cohort also has old customers
--    who were already buying before the data starts, it isn't all new people
-- 2) the data stops around 9 dec 2011 so the last month is only a partial month
select cohort_month, count(*) as new_customers
from retail.customer_cohorts
group by cohort_month
order by cohort_month;
 
 
-- step 2: size of each cohort
-- i need this as the denominator for retention
create table retail.cohort_size as
select
    cohort_month,
    count(*) as cohort_size
from retail.customer_cohorts
group by cohort_month;
 
alter table retail.cohort_size add primary key (cohort_month);
 
 
-- step 3: which months was each customer active
-- one row per customer per month they bought something
-- month_number = how many months after their first purchase (0 = the first month)
create table retail.cohort_activity as
select distinct
    t.customer_id,
    c.cohort_month,
    t.invoice_month as activity_month,
    ((extract(year  from t.invoice_month) - extract(year  from c.cohort_month)) * 12
      + extract(month from t.invoice_month) - extract(month from c.cohort_month))::int as month_number
from retail.clean_transactions t
join retail.customer_cohorts c on c.customer_id = t.customer_id;
 
create index idx_cohort_activity on retail.cohort_activity (cohort_month, month_number);
 
-- smallest month_number must be 0, and nothing should be negative
select min(month_number) as min_month, max(month_number) as max_month
from retail.cohort_activity;
 
 
-- step 4: retention table
-- retention % = customers active in that month / customers in the cohort
-- i build a full grid first (every cohort x every month it could have been observed)
-- because if i only use the activity table, a month where nobody came back would
-- just be missing instead of showing 0%
-- a cohort from 2011 can't have month 20, so the grid stops at the last month in the data
create table retail.cohort_retention as
with last_data_month as (
    select max(invoice_month) as last_month
    from retail.clean_transactions
),
grid as (
    select
        s.cohort_month,
        s.cohort_size,
        g.month_number
    from retail.cohort_size s
    cross join last_data_month l
    cross join lateral generate_series(
        0,
        ((extract(year  from l.last_month) - extract(year  from s.cohort_month)) * 12
          + extract(month from l.last_month) - extract(month from s.cohort_month))::int
    ) as g(month_number)
),
active as (
    select cohort_month, month_number, count(*) as active_customers
    from retail.cohort_activity
    group by cohort_month, month_number
)
select
    g.cohort_month,
    g.month_number,
    g.cohort_size,
    coalesce(a.active_customers, 0) as active_customers,
    round(100.0 * coalesce(a.active_customers, 0) / g.cohort_size, 1) as retention_pct
from grid g
left join active a
       on a.cohort_month = g.cohort_month
      and a.month_number = g.month_number;
 
alter table retail.cohort_retention add primary key (cohort_month, month_number);
 
-- the classic retention triangle, first 12 months
-- this is the one i'll screenshot / check against the power bi heatmap later
select
    cohort_month,
    cohort_size,
    max(retention_pct) filter (where month_number = 0)  as m0,
    max(retention_pct) filter (where month_number = 1)  as m1,
    max(retention_pct) filter (where month_number = 2)  as m2,
    max(retention_pct) filter (where month_number = 3)  as m3,
    max(retention_pct) filter (where month_number = 4)  as m4,
    max(retention_pct) filter (where month_number = 5)  as m5,
    max(retention_pct) filter (where month_number = 6)  as m6,
    max(retention_pct) filter (where month_number = 7)  as m7,
    max(retention_pct) filter (where month_number = 8)  as m8,
    max(retention_pct) filter (where month_number = 9)  as m9,
    max(retention_pct) filter (where month_number = 10) as m10,
    max(retention_pct) filter (where month_number = 11) as m11,
    max(retention_pct) filter (where month_number = 12) as m12
from retail.cohort_retention
group by cohort_month, cohort_size
order by cohort_month;
 
-- average retention curve across cohorts
-- weighted (total active / total cohort size) so a tiny cohort doesn't count as much as a big one
-- dec 2009 is separate because it has the old customers in it, so it looks better than the rest
select
    month_number,
    round(100.0 * sum(active_customers) / sum(cohort_size), 1) as retention_all_cohorts,
    round(100.0 * sum(active_customers) filter (where cohort_month > date '2009-12-01')
                / nullif(sum(cohort_size) filter (where cohort_month > date '2009-12-01'), 0), 1) as retention_excl_dec09
from retail.cohort_retention
where month_number <= 12
group by month_number
order by month_number;
 
 
-- step 5: revenue per cohort
-- how much each cohort spends over time, and the running total per customer
-- (this is like a simple lifetime value curve)
create table retail.cohort_revenue as
with rev as (
    select
        c.cohort_month,
        ((extract(year  from t.invoice_month) - extract(year  from c.cohort_month)) * 12
          + extract(month from t.invoice_month) - extract(month from c.cohort_month))::int as month_number,
        sum(t.line_revenue) as revenue
    from retail.clean_transactions t
    join retail.customer_cohorts c on c.customer_id = t.customer_id
    group by 1, 2
)
select
    r.cohort_month,
    r.month_number,
    r.cohort_size,
    r.active_customers,
    coalesce(v.revenue, 0)                                                          as revenue,
    sum(coalesce(v.revenue, 0)) over (partition by r.cohort_month order by r.month_number) as cumulative_revenue,
    round(sum(coalesce(v.revenue, 0)) over (partition by r.cohort_month order by r.month_number)
          / r.cohort_size, 2)                                                       as cumulative_revenue_per_customer
from retail.cohort_retention r
left join rev v
       on v.cohort_month = r.cohort_month
      and v.month_number = r.month_number;
 
alter table retail.cohort_revenue add primary key (cohort_month, month_number);
 
-- average spend per customer after 0, 3, 6 and 12 months for each cohort
select
    cohort_month,
    cohort_size,
    max(cumulative_revenue_per_customer) filter (where month_number = 0)  as spend_m0,
    max(cumulative_revenue_per_customer) filter (where month_number = 3)  as spend_m3,
    max(cumulative_revenue_per_customer) filter (where month_number = 6)  as spend_m6,
    max(cumulative_revenue_per_customer) filter (where month_number = 12) as spend_m12
from retail.cohort_revenue
group by cohort_month, cohort_size
order by cohort_month;
 
-- is the revenue of the first month already most of it? 
-- (share of the 12 month revenue that came in month 0, only for cohorts with 12+ months of data)
select
    round(100.0 * sum(revenue) filter (where month_number = 0)
                / sum(revenue), 1) as pct_of_12m_revenue_in_first_month
from retail.cohort_revenue
where month_number <= 12
  and cohort_month in (
        select cohort_month from retail.cohort_retention
        group by cohort_month
        having max(month_number) >= 12
  );
 
 
-- step 6: how long until the second order
-- this is the number i care about most, the first repurchase decides who stays
-- first make one row per order
create table retail.customer_orders as
select
    customer_id,
    invoice,
    min(invoice_date) as order_date,
    sum(line_revenue) as order_value
from retail.clean_transactions
group by customer_id, invoice;
 
create index idx_customer_orders on retail.customer_orders (customer_id, order_date);
 
-- first and second order for each customer
-- days_to_second_order can be 0 if they placed two separate invoices on the same day
-- and it is null for customers who never came back
create table retail.second_order as
with ranked as (
    select
        customer_id,
        order_date,
        row_number() over (partition by customer_id order by order_date, invoice) as order_no
    from retail.customer_orders
)
select
    c.customer_id,
    c.cohort_month,
    f.order_date::date                                as first_order_date,
    s.order_date::date                                as second_order_date,
    s.order_date::date - f.order_date::date           as days_to_second_order
from retail.customer_cohorts c
join ranked f on f.customer_id = c.customer_id and f.order_no = 1
left join ranked s on s.customer_id = c.customer_id and s.order_no = 2;
 
alter table retail.second_order add primary key (customer_id);
 
-- how many customers ever came back, and how fast
select
    count(*)                                                       as customers,
    count(second_order_date)                                       as came_back,
    round(100.0 * count(second_order_date) / count(*), 1)          as pct_came_back,
    round(avg(days_to_second_order), 1)                            as avg_days_to_second,
    percentile_cont(0.5) within group (order by days_to_second_order) as median_days_to_second
from retail.second_order;
 
-- repeat rate within 30 / 60 / 90 days
-- only counting customers whose first order is at least that many days before the end of the data
-- otherwise recent customers look like they never came back, just because they had no time
with ld as (
    select max(invoice_date)::date as last_day
    from retail.clean_transactions
)
select
    count(*) filter (where first_order_date <= ld.last_day - 30) as eligible_30d,
    round(100.0 * count(*) filter (where first_order_date <= ld.last_day - 30 and days_to_second_order <= 30)
                / nullif(count(*) filter (where first_order_date <= ld.last_day - 30), 0), 1) as repeat_30d_pct,
    round(100.0 * count(*) filter (where first_order_date <= ld.last_day - 60 and days_to_second_order <= 60)
                / nullif(count(*) filter (where first_order_date <= ld.last_day - 60), 0), 1) as repeat_60d_pct,
    round(100.0 * count(*) filter (where first_order_date <= ld.last_day - 90 and days_to_second_order <= 90)
                / nullif(count(*) filter (where first_order_date <= ld.last_day - 90), 0), 1) as repeat_90d_pct
from retail.second_order
cross join ld;
 
-- 90 day repeat rate for each cohort (to see if newer customers are worse than older ones)
-- cohorts from the last 3 months are left out, they don't have 90 days yet
with ld as (
    select max(invoice_date)::date as last_day
    from retail.clean_transactions
)
select
    cohort_month,
    count(*) filter (where first_order_date <= ld.last_day - 90) as eligible_customers,
    round(100.0 * count(*) filter (where first_order_date <= ld.last_day - 90 and days_to_second_order <= 90)
                / nullif(count(*) filter (where first_order_date <= ld.last_day - 90), 0), 1) as repeat_90d_pct
from retail.second_order
cross join ld
group by cohort_month
having count(*) filter (where first_order_date <= ld.last_day - 90) > 0
order by cohort_month;
 
 
-- step 7: connect cohorts with the rfm segments from 02
 
-- long table, one row per cohort and segment, for power bi
create table retail.cohort_segments as
select
    c.cohort_month,
    r.segment,
    count(*)                 as customers,
    round(sum(r.monetary), 2) as revenue
from retail.customer_cohorts c
join retail.rfm_segments r on r.customer_id = c.customer_id
group by c.cohort_month, r.segment;
 
alter table retail.cohort_segments add primary key (cohort_month, segment);
 
-- which cohorts produced the most champions (as a % of the cohort)
select
    c.cohort_month,
    count(*)                                                                    as customers,
    count(*) filter (where r.segment = 'Champions')                             as champions,
    round(100.0 * count(*) filter (where r.segment = 'Champions') / count(*), 1) as pct_champions,
    count(*) filter (where r.segment in ('At Risk', 'Can''t Lose Them'))         as at_risk_customers
from retail.customer_cohorts c
join retail.rfm_segments r on r.customer_id = c.customer_id
group by c.cohort_month
order by c.cohort_month;
 
-- do customers who reorder fast end up as champions more often?
-- using only customers who had at least 60 days to reorder
-- careful: this shows a link, it doesn't prove that the early reorder caused it
-- (people who reorder early also have more time to spend)
with ld as (
    select max(invoice_date)::date as last_day
    from retail.clean_transactions
)
select
    case when so.days_to_second_order <= 60
         then 'reordered within 60 days'
         else 'did not reorder within 60 days'
    end                                                                       as group_name,
    count(*)                                                                  as customers,
    round(100.0 * count(*) filter (where r.segment = 'Champions') / count(*), 1) as pct_champions,
    round(avg(r.monetary), 2)                                                 as avg_total_spend
from retail.second_order so
join retail.rfm_segments r on r.customer_id = so.customer_id
cross join ld
where so.first_order_date <= ld.last_day - 60
group by 1
order by 1;
 
 
-- step 8: final checks
 
-- cohort sizes should add up to all customers
select
    (select count(distinct customer_id) from retail.clean_transactions) as customers_clean,
    (select count(*) from retail.customer_cohorts)                      as customers_in_cohorts,
    (select sum(cohort_size) from retail.cohort_size)                   as sum_cohort_sizes;
 
-- month 0 should be 100% for every cohort, and nothing should go over 100%
select
    count(*) filter (where month_number = 0 and retention_pct <> 100) as month0_not_100,
    count(*) filter (where retention_pct > 100)                       as over_100,
    count(*) filter (where retention_pct < 0)                         as below_0
from retail.cohort_retention;
 
-- 25 cohorts expected (dec 2009 to dec 2011)
select count(*) as number_of_cohorts, min(cohort_month) as first_cohort, max(cohort_month) as last_cohort
from retail.cohort_size;
 
-- revenue by cohort should add up to the revenue in the clean table
select
    (select sum(revenue) from retail.cohort_revenue) as revenue_cohorts,
    (select sum(line_revenue) from retail.clean_transactions) as revenue_clean;
 
-- every customer should have a first order, and the second order should be after the first
select
    count(*) filter (where first_order_date is null)                  as no_first_order,
    count(*) filter (where days_to_second_order < 0)                  as second_before_first
from retail.second_order;
 