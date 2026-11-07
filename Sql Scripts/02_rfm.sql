drop view  if exists retail.rfm_segment_summary;
drop table if exists retail.rfm_segments;
drop table if exists retail.rfm_base;
drop table if exists retail.segment_actions;

-- step 1: pick the snapshot date
-- recency = days between the last purchase and "today"
-- the data stops in dec 2011 so i can't use the real today, otherwise everyone is ~900 days inactive
-- using last invoice date + 1 day instead
select
    max(invoice_date)        as last_invoice,
    max(invoice_date)::date + 1 as snapshot_date
from retail.clean_transactions;

-- step 2: one row per customer (recency, frequency, monetary)
-- frequency = number of different invoices, not number of rows
-- (one invoice has lots of rows, one per product)
-- monetary = total spend
create table retail.rfm_base as
with snapshot as (
    select max(invoice_date)::date + 1 as snapshot_date
    from retail.clean_transactions
)
select
    t.customer_id,
    min(t.invoice_date)::date                         as first_purchase_date,
    max(t.invoice_date)::date                         as last_purchase_date,
    s.snapshot_date - max(t.invoice_date)::date       as recency_days,
    count(distinct t.invoice)                         as frequency,
    sum(t.line_revenue)                               as monetary,
    round(sum(t.line_revenue) / count(distinct t.invoice), 2) as avg_order_value,
    -- a few customers might have more than one country, taking the latest one
    (array_agg(t.country order by t.invoice_date desc))[1]    as country
from retail.clean_transactions t
cross join snapshot s
group by t.customer_id, s.snapshot_date;

alter table retail.rfm_base add primary key (customer_id);

-- step 3: check the base table
 
-- should be the same number of customers as the clean table
select
    (select count(distinct customer_id) from retail.clean_transactions) as customers_in_clean,
    (select count(*) from retail.rfm_base)                              as customers_in_rfm;

-- total spend should match too
select
    (select sum(line_revenue) from retail.clean_transactions) as revenue_clean,
    (select sum(monetary) from retail.rfm_base)               as revenue_rfm;
 
-- nulls and weird values, want all 0
select
    count(*) filter (where recency_days is null or recency_days < 0) as bad_recency,
    count(*) filter (where frequency is null or frequency < 1)       as bad_frequency,
    count(*) filter (where monetary is null or monetary <= 0)        as bad_monetary
from retail.rfm_base;
 
-- top 10 spenders, just to see if anything looks off
select * from retail.rfm_base
order by monetary desc
limit 10;

-- step 4: look at how r, f and m are spread out
-- need this to decide how to score them
 
select 'recency' as metric,
       min(recency_days)::numeric as min_value,
       round(percentile_cont(0.25) within group (order by recency_days)::numeric, 1) as p25,
       round(percentile_cont(0.50) within group (order by recency_days)::numeric, 1) as median,
       round(percentile_cont(0.75) within group (order by recency_days)::numeric, 1) as p75,
       max(recency_days)::numeric as max_value
from retail.rfm_base
union all
select 'frequency',
       min(frequency)::numeric,
       round(percentile_cont(0.25) within group (order by frequency)::numeric, 1),
       round(percentile_cont(0.50) within group (order by frequency)::numeric, 1),
       round(percentile_cont(0.75) within group (order by frequency)::numeric, 1),
       max(frequency)::numeric
from retail.rfm_base
union all
select 'monetary',
       round(min(monetary), 1),
       round(percentile_cont(0.25) within group (order by monetary)::numeric, 1),
       round(percentile_cont(0.50) within group (order by monetary)::numeric, 1),
       round(percentile_cont(0.75) within group (order by monetary)::numeric, 1),
       round(max(monetary), 1)
from retail.rfm_base;
 
-- frequency has a lot of customers with the same value (1 order, 2 orders...)
-- this shows how many customers have each order count
select
    frequency,
    count(*)                                                          as customers,
    round(100.0 * count(*) / sum(count(*)) over (), 1)                as pct,
    round(100.0 * sum(count(*)) over (order by frequency)
                / sum(count(*)) over (), 1)                           as cumulative_pct
from retail.rfm_base
group by frequency
order by frequency
limit 20;
 
-- how concentrated is the revenue? what share comes from the top 20% of customers
select
    round(100.0 * sum(monetary) filter (where grp = 1) / sum(monetary), 1) as top20_pct_revenue
from (
    select monetary, ntile(5) over (order by monetary desc) as grp
    from retail.rfm_base
) x;

-- step 5: scores from 1 to 5, 5 is always the best
 
-- recency: ntile(5) on days, most recent customers should get 5, so i sort days descending
-- monetary: ntile(5) on spend, biggest spenders get 5
-- frequency: not using ntile here. so many customers have the same number of orders
-- that ntile would give two customers with the same frequency different scores
-- so i set the cut points by hand, using the table from step 4
-- (1 order = 1, 2 = 2, 3-4 = 3, 5-8 = 4, 9+ = 5), change these if your numbers look different
-- customer_id is in the order by so the result is the same every time i run it
 
-- segment rules (case goes top to bottom, first match wins so the order matters)
-- champions: recent, buy a lot, spend a lot
-- cant lose them: used to be great, haven't bought for a long time
-- at risk: good history but going quiet
-- loyal customers: buy often, fairly recent
-- lost: one order and a long time ago
-- new customers: first order very recently
-- potential loyalists: recent, 2-3 orders
-- promising: recent but only 1 order
-- need attention: middle recency, low-ish frequency
-- hibernating: everything else that is inactive
create table retail.rfm_segments as
with scored as (
    select
        b.*,
        ntile(5) over (order by recency_days desc, customer_id) as r_score,
        case
            when frequency = 1              then 1
            when frequency = 2              then 2
            when frequency between 3 and 4  then 3
            when frequency between 5 and 8  then 4
            else 5
        end                                                      as f_score,
        ntile(5) over (order by monetary, customer_id)           as m_score
    from retail.rfm_base b
)
select
    s.*,
    r_score::text || f_score::text || m_score::text as rfm_code,
    r_score + f_score + m_score                     as rfm_total,
    case
        when r_score >= 4 and f_score >= 4 and m_score >= 4 then 'Champions'
        when r_score = 1  and f_score >= 4 and m_score >= 4 then 'Can''t Lose Them'
        when r_score <= 2 and f_score >= 3 and m_score >= 3 then 'At Risk'
        when r_score >= 3 and f_score >= 4                  then 'Loyal Customers'
        when r_score = 1  and f_score = 1                   then 'Lost'
        when r_score = 5  and f_score = 1                   then 'New Customers'
        when r_score >= 4 and f_score >= 2                  then 'Potential Loyalists'
        when r_score = 4  and f_score = 1                   then 'Promising'
        when r_score = 3                                    then 'Need Attention'
        when r_score <= 2                                   then 'Hibernating'
        else 'Other'
    end as segment
from scored s;

alter table retail.rfm_segments add primary key (customer_id);

-- step 6: check the scores
 
-- each score should cover a clean range of the real values
-- (r_score 5 should have the smallest recency_days)
select r_score, min(recency_days) as min_days, max(recency_days) as max_days, count(*) as customers
from retail.rfm_segments
group by r_score
order by r_score;
 
select f_score, min(frequency) as min_orders, max(frequency) as max_orders, count(*) as customers
from retail.rfm_segments
group by f_score
order by f_score;
 
select m_score, round(min(monetary), 2) as min_spend, round(max(monetary), 2) as max_spend, count(*) as customers
from retail.rfm_segments
group by m_score
order by m_score;
 
-- nobody should be left without a score or in 'Other'
select
    count(*) filter (where r_score is null or f_score is null or m_score is null) as missing_scores,
    count(*) filter (where segment = 'Other')                                     as in_other
from retail.rfm_segments;
 
-- every customer is in exactly one segment
select segment, count(*) as customers
from retail.rfm_segments
group by segment
order by customers desc;

-- step 7: segment summary
-- made it a view so it always follows the table, power bi can read it directly
create view retail.rfm_segment_summary as
select
    segment,
    count(*)                                                    as customers,
    round(100.0 * count(*) / sum(count(*)) over (), 1)          as pct_customers,
    round(sum(monetary), 2)                                     as revenue,
    round(100.0 * sum(monetary) / sum(sum(monetary)) over (), 1) as pct_revenue,
    round(avg(recency_days), 1)                                 as avg_recency_days,
    round(avg(frequency), 1)                                    as avg_orders,
    round(avg(monetary), 2)                                     as avg_spend,
    round(sum(monetary) / sum(frequency), 2)                    as avg_order_value
from retail.rfm_segments
group by segment;
 
select * from retail.rfm_segment_summary
order by revenue desc;

-- step 8: what to do with each segment
-- small lookup table, i'll join it in power bi
create table retail.segment_actions (
    segment           text primary key,
    priority          int,
    suggested_action  text
);
 
insert into retail.segment_actions (segment, priority, suggested_action) values
    ('Champions',           1, 'reward them, early access to new products, ask for referrals and reviews'),
    ('Can''t Lose Them',    2, 'reach out personally, big win-back offer, find out why they stopped'),
    ('At Risk',             3, 'win-back email with a personal offer before they go fully inactive'),
    ('Loyal Customers',     4, 'loyalty program, upsell higher value products'),
    ('Potential Loyalists', 5, 'push for a regular habit, recommend related products, small repeat-purchase offer'),
    ('New Customers',       6, 'welcome emails, make the second order easy'),
    ('Promising',           7, 'nudge toward a second order with a short time limited offer'),
    ('Need Attention',      8, 'reminder campaign, show what is new since their last order'),
    ('Hibernating',         9, 'cheap reactivation emails only, don''t spend much here'),
    ('Lost',               10, 'one last low cost attempt, then stop spending on them');
 
-- every segment in the data should have an action
select s.segment
from retail.rfm_segment_summary s
left join retail.segment_actions a on a.segment = s.segment
where a.segment is null;
 

-- step 9: revenue at risk
-- customers who spent a lot but are going quiet (at risk + can't lose them)
select
    count(*)                                                                    as customers,
    round(sum(monetary), 2)                                                     as revenue_at_risk,
    round(100.0 * sum(monetary) / (select sum(monetary) from retail.rfm_segments), 1) as pct_of_total_revenue
from retail.rfm_segments
where segment in ('At Risk', 'Can''t Lose Them');

-- step 10: final checks
 
-- customers and revenue should still match the clean table
select
    (select count(distinct customer_id) from retail.clean_transactions) as customers_clean,
    (select count(*) from retail.rfm_segments)                          as customers_segments,
    (select sum(line_revenue) from retail.clean_transactions)           as revenue_clean,
    (select sum(monetary) from retail.rfm_segments)                     as revenue_segments;
 
-- quick look at the final table
select customer_id, recency_days, frequency, monetary, r_score, f_score, m_score, rfm_code, segment
from retail.rfm_segments
order by rfm_total desc, monetary desc
limit 20;
 