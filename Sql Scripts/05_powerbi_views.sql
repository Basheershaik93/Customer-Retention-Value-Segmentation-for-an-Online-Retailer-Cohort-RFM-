drop view if exists retail.v_monthly_revenue;
drop view if exists retail.v_buyer_type;
drop view if exists retail.v_retention_curve;
drop view if exists retail.v_second_order_timing;

 -- monthly revenue for the trend line on page 1
-- the last month in the data (dec 2011) stops on the 9th, so i flag it
-- otherwise the line drops at the end and looks like a real decline
create view retail.v_monthly_revenue as
select
    invoice_month,
    round(sum(line_revenue), 2)                                  as revenue,
    count(distinct invoice)                                      as orders,
    count(distinct customer_id)                                  as active_customers,
    round(sum(line_revenue) / count(distinct invoice), 2)        as avg_order_value,
    invoice_month = (select date_trunc('month', max(invoice_date))::date
                     from retail.clean_transactions)             as is_partial_month
from retail.clean_transactions
group by invoice_month;

-- customers vs revenue by how many orders they made 
-- sort_order is there so power bi shows 1 order, 2-3, 4+ in the right order
create view retail.v_buyer_type as
select
    case
        when frequency = 1              then 1
        when frequency between 2 and 3  then 2
        else 3
    end                                                          as sort_order,
    case
        when frequency = 1              then '1 order'
        when frequency between 2 and 3  then '2-3 orders'
        else '4+ orders'
    end                                                          as buyer_type,
    count(*)                                                     as customers,
    round(sum(monetary), 2)                                      as revenue,
    round(100.0 * count(*) / sum(count(*)) over (), 1)           as pct_customers,
    round(100.0 * sum(monetary) / sum(sum(monetary)) over (), 1) as pct_revenue
from retail.rfm_segments
group by 1, 2;

-- average retention curve for the line chart 
-- leaving out dec 2009 because it has old customers in it
create view retail.v_retention_curve as
select
    month_number,
    sum(active_customers)                                         as active_customers,
    sum(cohort_size)                                              as cohort_customers,
    round(100.0 * sum(active_customers) / sum(cohort_size), 1)    as retention_pct
from retail.cohort_retention
where cohort_month > date '2009-12-01'
  and month_number <= 12
group by month_number;

-- how long until the second order
-- only customers who had at least 180 days to come back
-- cumulative_pct = share of customers who already came back by that point
create view retail.v_second_order_timing as
with ld as (
    select max(invoice_date)::date as last_day
    from retail.clean_transactions
),
bucketed as (
    select
        case
            when days_to_second_order is null  then 6
            when days_to_second_order <= 30    then 1
            when days_to_second_order <= 60    then 2
            when days_to_second_order <= 90    then 3
            when days_to_second_order <= 180   then 4
            else                                    5
        end as sort_order
    from retail.second_order
    cross join ld
    where first_order_date <= ld.last_day - 180
)
select
    sort_order,
    case sort_order
        when 1 then 'within 30 days'
        when 2 then '31-60 days'
        when 3 then '61-90 days'
        when 4 then '91-180 days'
        when 5 then 'after 180 days'
        else        'never placed a second order'
    end                                                                    as timing,
    count(*)                                                               as customers,
    round(100.0 * count(*) / sum(count(*)) over (), 1)                     as pct_customers,
    case when sort_order = 6 then null
         else round(100.0 * sum(count(*)) over (order by sort_order)
                          / sum(count(*)) over (), 1)
    end                                                                    as cumulative_pct
from bucketed
group by sort_order;

-- quick look at each view, they should match the numbers i saved from 04
select * from retail.v_monthly_revenue order by invoice_month;
select * from retail.v_buyer_type order by sort_order;
select * from retail.v_retention_curve order by month_number;
select * from retail.v_second_order_timing order by sort_order;