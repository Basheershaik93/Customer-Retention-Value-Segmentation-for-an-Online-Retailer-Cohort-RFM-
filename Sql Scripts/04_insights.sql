-- 04_insights.sql
-- online retail II project (cohort + RFM)
-- this file answers the business questions using the tables from 01, 02 and 03
-- the problem i'm solving: lots of customers buy once and never come back,
-- so who are the best customers, who is leaving, and where should marketing money go
-- i write down the numbers from every query for the readme
 
 
-- question 1: how many customers buy only once
-- i group customers by how many orders they made
select
    case
        when frequency = 1              then '1 order'
        when frequency between 2 and 3  then '2-3 orders'
        else '4+ orders'
    end                                                          as buyer_type,
    count(*)                                                     as customers,
    round(100.0 * count(*) / sum(count(*)) over (), 1)           as pct_customers,
    round(sum(monetary), 2)                                      as revenue,
    round(100.0 * sum(monetary) / sum(sum(monetary)) over (), 1) as pct_revenue
from retail.rfm_segments
group by 1
order by min(frequency);

-- question 2: do a few customers bring most of the money
-- split customers into 10 equal groups by spend, group 1 is the biggest spenders
with deciles as (
    select monetary, ntile(10) over (order by monetary desc) as decile
    from retail.rfm_segments
)
select
    round(100.0 * sum(monetary) filter (where decile = 1)  / sum(monetary), 1) as top10_pct_of_revenue,
    round(100.0 * sum(monetary) filter (where decile <= 2) / sum(monetary), 1) as top20_pct_of_revenue,
    round(100.0 * sum(monetary) filter (where decile >= 6) / sum(monetary), 1) as bottom50_pct_of_revenue
from deciles;

-- question 3: which segments matter most
-- gap = share of revenue minus share of customers
-- a big positive gap means a small group is carrying a lot of the revenue
select
    s.segment,
    s.customers,
    s.pct_customers,
    s.revenue,
    s.pct_revenue,
    round(s.pct_revenue - s.pct_customers, 1) as gap,
    s.avg_recency_days,
    s.avg_orders,
    s.avg_spend,
    a.suggested_action
from retail.rfm_segment_summary s
join retail.segment_actions a on a.segment = s.segment
order by a.priority;
 
 
-- question 4a: how much money is at risk
-- at risk + can't lose them = good customers who are going quiet
with risk as (
    select customer_id, monetary, avg_order_value
    from retail.rfm_segments
    where segment in ('At Risk', 'Can''t Lose Them')
)
select
    count(*)                                                                        as customers,
    round(sum(monetary), 2)                                                         as past_spend,
    round(100.0 * sum(monetary) / (select sum(monetary) from retail.rfm_segments), 1) as pct_of_total_revenue
from risk;
 
-- question 4b: what if i win some of them back?
-- i don't want to make up a big number, so i assume each customer i win back
-- places just ONE more order, worth their own average order value
-- the win back rates (5, 10, 20%) are my guesses, the real rate would come from a test
with risk as (
    select avg_order_value
    from retail.rfm_segments
    where segment in ('At Risk', 'Can''t Lose Them')
)
select
    r.rate                                              as win_back_rate_pct,
    round(r.rate / 100.0 * count(*))                    as customers_won_back,
    round(r.rate / 100.0 * sum(avg_order_value), 2)     as extra_revenue_one_order
from risk
cross join (values (5), (10), (20)) as r(rate)
group by r.rate
order by r.rate;

-- question 5: when do customers stop coming back
-- average retention over all cohorts, without dec 2009 because it has old customers in it
-- change = how many points we lose compared to the month before
with curve as (
    select
        month_number,
        round(100.0 * sum(active_customers) / sum(cohort_size), 1) as retention_pct
    from retail.cohort_retention
    where cohort_month > date '2009-12-01'
      and month_number <= 12
    group by month_number
)
select
    month_number,
    retention_pct,
    round(retention_pct - lag(retention_pct) over (order by month_number), 1) as change_vs_prev_month
from curve
order by month_number;
 
 
-- question 6: how fast do people place the second order
-- only customers who had at least 180 days to come back, so it's fair
with ld as (
    select max(invoice_date)::date as last_day
    from retail.clean_transactions
)
select
    case
        when days_to_second_order is null  then '6 never came back (within 180 days)'
        when days_to_second_order <= 30    then '1 within 30 days'
        when days_to_second_order <= 60    then '2 31-60 days'
        when days_to_second_order <= 90    then '3 61-90 days'
        when days_to_second_order <= 180   then '4 91-180 days'
        else                                    '5 after 180 days'
    end                                                          as second_order_timing,
    count(*)                                                     as customers,
    round(100.0 * count(*) / sum(count(*)) over (), 1)           as pct_customers
from retail.second_order
cross join ld
where first_order_date <= ld.last_day - 180
group by 1
order by 1;
-- note: i put a number in front of each label just so it sorts in the right order