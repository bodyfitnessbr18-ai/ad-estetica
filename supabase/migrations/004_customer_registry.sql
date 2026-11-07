-- AD Estética Automotiva: cadastro automático de clientes no primeiro agendamento.
-- Não cria login/senha: cria um registro de cliente e associa cada reserva ao cadastro.
create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  phone text not null,
  phone_normalized text not null unique,
  email text,
  postal_code text,
  property_type text,
  street text,
  street_number text,
  complement text,
  district text,
  city text,
  state text,
  reference text,
  first_booking_at timestamptz not null default now(),
  last_booking_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (length(trim(full_name)) between 2 and 120),
  check (length(phone_normalized) between 8 and 15)
);

alter table public.bookings
  add column if not exists customer_id uuid references public.customers(id) on delete set null;


-- Migra o histórico existente para a nova carteira de clientes, sem apagar agendamentos.
insert into public.customers (
  full_name, phone, phone_normalized, postal_code, property_type,
  street, street_number, complement, district, city, state, reference,
  first_booking_at, last_booking_at
)
select distinct on (regexp_replace(coalesce(customer_phone,''), '[^0-9]', '', 'g'))
  customer_name,
  customer_phone,
  regexp_replace(coalesce(customer_phone,''), '[^0-9]', '', 'g'),
  postal_code, property_type, street, street_number, complement, district,
  city, state, reference,
  min(created_at) over (partition by regexp_replace(coalesce(customer_phone,''), '[^0-9]', '', 'g')),
  max(created_at) over (partition by regexp_replace(coalesce(customer_phone,''), '[^0-9]', '', 'g'))
from public.bookings
where length(regexp_replace(coalesce(customer_phone,''), '[^0-9]', '', 'g')) between 8 and 15
order by regexp_replace(coalesce(customer_phone,''), '[^0-9]', '', 'g'), created_at desc
on conflict (phone_normalized) do nothing;

update public.bookings b
set customer_id = c.id
from public.customers c
where c.phone_normalized = regexp_replace(coalesce(b.customer_phone,''), '[^0-9]', '', 'g')
  and b.customer_id is null;


create index if not exists customers_name_idx on public.customers (full_name);
create index if not exists customers_phone_idx on public.customers (phone_normalized);
create index if not exists bookings_customer_id_idx on public.bookings (customer_id);

alter table public.customers enable row level security;
drop policy if exists "Admins manage customers" on public.customers;
create policy "Admins manage customers" on public.customers
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop function if exists public.create_booking(uuid[],text,text,text,text,text,text,text,text,text,text,text,date,time,uuid);

create or replace function public.create_booking(
  p_service_ids uuid[],
  p_customer_name text,
  p_customer_phone text,
  p_postal_code text,
  p_property_type text,
  p_street text,
  p_street_number text,
  p_complement text,
  p_district text,
  p_city text,
  p_state text,
  p_reference text,
  p_service_date date,
  p_start_time time,
  p_bump_service_id uuid default null,
  p_customer_email text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking_id uuid;
  v_customer_id uuid;
  v_phone_normalized text;
  v_service_count integer;
  v_duration integer;
  v_main_price numeric(10,2);
  v_total_price numeric(10,2);
  v_bump public.services%rowtype;
  v_start timestamp;
  v_end timestamp;
  v_open time;
  v_close time;
  v_weekday integer;
  v_names text;
begin
  if p_service_ids is null or cardinality(p_service_ids) = 0 then
    raise exception 'Selecione pelo menos um serviço.';
  end if;
  if cardinality(p_service_ids) <> (select count(distinct x) from unnest(p_service_ids) x) then
    raise exception 'Há serviços duplicados no pedido.';
  end if;
  if nullif(trim(coalesce(p_customer_name,'')), '') is null
     or length(trim(p_customer_name)) < 2
     or nullif(regexp_replace(coalesce(p_customer_phone,''), '\\D', '', 'g'), '') is null then
    raise exception 'Informe nome e telefone válidos.';
  end if;

  v_phone_normalized := regexp_replace(coalesce(p_customer_phone,''), '\\D', '', 'g');
  if length(v_phone_normalized) < 8 or length(v_phone_normalized) > 15 then
    raise exception 'Informe um telefone válido com DDD.';
  end if;

  select count(*), coalesce(sum(duration_minutes),0),
         case when bool_or(price is null) then null else sum(price) end,
         string_agg(name, ', ' order by name)
    into v_service_count, v_duration, v_main_price, v_names
    from public.services
   where id = any(p_service_ids) and active = true;

  if v_service_count <> cardinality(p_service_ids) then
    raise exception 'Um ou mais serviços não estão disponíveis.';
  end if;

  v_total_price := v_main_price;
  if p_bump_service_id is not null then
    if p_bump_service_id = any(p_service_ids) then
      raise exception 'A oferta adicional já está nos serviços selecionados.';
    end if;
    select * into v_bump from public.services
     where id = p_bump_service_id and active = true;
    if not found or v_bump.price is null then
      raise exception 'A oferta adicional não está disponível.';
    end if;
    if not exists (
      select 1 from public.service_bump_rules r
       where r.bump_service_id = p_bump_service_id
         and r.source_service_id = any(p_service_ids)
    ) then
      raise exception 'Esta oferta adicional não está permitida para os serviços escolhidos.';
    end if;
    v_duration := v_duration + v_bump.duration_minutes;
    if v_total_price is not null then
      v_total_price := v_total_price + round(v_bump.price * 0.85, 2);
    end if;
    v_names := v_names || ' + ' || v_bump.name || ' (oferta -15%)';
  end if;

  v_weekday := extract(isodow from p_service_date)::integer;
  select opens_at, closes_at into v_open, v_close
    from public.business_hours where weekday = v_weekday;
  if not found then raise exception 'Não há expediente cadastrado para esta data.'; end if;

  v_start := p_service_date + p_start_time;
  v_end := v_start + make_interval(mins => v_duration);
  if p_start_time < v_open or v_end::time > v_close or v_end::date <> p_service_date then
    raise exception 'O horário não comporta a duração total dos serviços.';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_service_date::text));
  if exists (
    select 1 from public.blocked_slots b
     where b.service_date = p_service_date
       and p_start_time < b.end_time
       and b.start_time < v_end::time
  ) then raise exception 'Este horário está bloqueado.'; end if;

  if exists (
    select 1 from public.bookings b
     where b.service_date = p_service_date
       and b.status <> 'Cancelado'
       and p_start_time < b.end_time
       and b.start_time < v_end::time
  ) then raise exception 'Este horário já está reservado.'; end if;

  insert into public.customers (
    full_name, phone, phone_normalized, email, postal_code, property_type,
    street, street_number, complement, district, city, state, reference,
    last_booking_at, updated_at
  ) values (
    trim(p_customer_name), trim(p_customer_phone), v_phone_normalized,
    nullif(trim(coalesce(p_customer_email,'')),''), p_postal_code, p_property_type,
    p_street, p_street_number, p_complement, p_district, p_city, p_state, p_reference,
    now(), now()
  )
  on conflict (phone_normalized) do update set
    full_name = excluded.full_name,
    phone = excluded.phone,
    email = coalesce(excluded.email, public.customers.email),
    postal_code = excluded.postal_code,
    property_type = excluded.property_type,
    street = excluded.street,
    street_number = excluded.street_number,
    complement = excluded.complement,
    district = excluded.district,
    city = excluded.city,
    state = excluded.state,
    reference = excluded.reference,
    last_booking_at = now(),
    updated_at = now()
  returning id into v_customer_id;

  insert into public.bookings (
    customer_id, service_id, service_name, price, duration_minutes,
    customer_name, customer_phone, postal_code, property_type,
    street, street_number, complement, district, city, state, reference,
    service_date, start_time, end_time, status
  ) values (
    v_customer_id, p_service_ids[1], v_names, v_total_price, v_duration,
    trim(p_customer_name), trim(p_customer_phone), p_postal_code, p_property_type,
    p_street, p_street_number, p_complement, p_district, p_city, p_state, p_reference,
    p_service_date, p_start_time, v_end::time, 'Pendente'
  ) returning id into v_booking_id;

  insert into public.booking_items (
    booking_id, service_id, service_name, price, duration_minutes, is_bump, discount_percent
  )
  select v_booking_id, s.id, s.name, s.price, s.duration_minutes, false, 0
    from public.services s where s.id = any(p_service_ids);

  if p_bump_service_id is not null then
    insert into public.booking_items (
      booking_id, service_id, service_name, price, duration_minutes, is_bump, discount_percent
    ) values (
      v_booking_id, v_bump.id, v_bump.name, round(v_bump.price * 0.85, 2),
      v_bump.duration_minutes, true, 15
    );
  end if;

  return v_booking_id;
end;
$$;

revoke all on function public.create_booking(uuid[],text,text,text,text,text,text,text,text,text,text,text,date,time,uuid,text) from public;
grant execute on function public.create_booking(uuid[],text,text,text,text,text,text,text,text,text,text,text,date,time,uuid,text) to anon, authenticated;
