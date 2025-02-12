{{
    config(
        materialized='incremental',
        unique_key='daily_unique_key',
        partition_by={"field": "event_day", "data_type": "date"} if target.type not in ('spark','databricks') else ['event_day'],
        incremental_strategy = 'merge' if target.type not in ('postgres', 'redshift') else 'delete+insert',
        file_format = 'delta' 
    )
}}

with event_enhanced as (

    select * 
    from {{ ref('amplitude__event_enhanced') }}
),

date_spine as (
    
    select *
    from {{ ref('int_amplitude__date_spine') }}

    {% if is_incremental() %}

    where event_day >=  ( select max(event_day) from {{ this }})

    {% endif %}
), 

agg_event_data as (

    select
        event_day,
        event_type,
        count(distinct unique_event_id) as number_events,
        count(distinct unique_session_id) as number_sessions,
        count(distinct amplitude_user_id) as number_users,
        count(distinct 
                (case when cast( {{ dbt_utils.date_trunc('day', 'user_creation_time') }} as date) = event_day
            then amplitude_user_id end)) as number_new_users 
    from event_enhanced
    group by 1,2
),

spine_joined as (

    select
        date_spine.event_day,
        date_spine.event_type,
        agg_event_data.number_events,
        agg_event_data.number_sessions,
        agg_event_data.number_users,
        agg_event_data.number_new_users
    from date_spine
    left join agg_event_data
        on date_spine.event_day = agg_event_data.event_day
        and date_spine.event_type = agg_event_data.event_type
),

final as (

    select
        event_day,
        event_type,
        coalesce(number_events,0) as number_events,
        coalesce(number_sessions,0) as number_sessions,
        coalesce(number_users,0) as number_users,
        coalesce(number_new_users,0) as number_new_users,
        {{ dbt_utils.surrogate_key(['event_day', 'event_type']) }} as daily_unique_key
    from spine_joined

    {% if is_incremental() %}
    -- only return the most recent day of data
    where event_day >= coalesce( (select max(event_day)  from {{ this }} ), '2020-01-01')

    {% endif %}
)

select *
from final