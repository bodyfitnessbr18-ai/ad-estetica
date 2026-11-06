-- AD Estética Automotiva: regras de combinação para order bump
-- Regras direcionais: quando um serviço principal é escolhido, quais complementos podem ser oferecidos.
create table if not exists public.service_bump_rules (
  source_service_id uuid not null references public.services(id) on delete cascade,
  bump_service_id uuid not null references public.services(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (source_service_id, bump_service_id),
  check (source_service_id <> bump_service_id)
);
alter table public.service_bump_rules enable row level security;
drop policy if exists "Public reads service bump rules" on public.service_bump_rules;
create policy "Public reads service bump rules" on public.service_bump_rules
  for select to anon, authenticated using (true);
drop policy if exists "Admins manage service bump rules" on public.service_bump_rules;
create policy "Admins manage service bump rules" on public.service_bump_rules
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Por padrão, nenhum serviço novo entra automaticamente na oferta.
alter table public.services
  add column if not exists bump_eligible boolean not null default false;

create index if not exists services_bump_eligible_idx
  on public.services (bump_eligible)
  where active = true and bump_eligible = true;

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
  p_bump_service_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking_id uuid;
  v_service_count integer;
  v_duration integer;
  v_main_price numeric(10,2);
  v_total_price numeric(10,2);
  v_bump public.services%rowtype;
  v_has_null_price boolean;
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

  select count(*), coalesce(sum(duration_minutes),0),
         coalesce(bool_or(price is null),false),
         case when bool_or(price is null) then null else sum(price) end,
         string_agg(name, ', ' order by name)
    into v_service_count, v_duration, v_has_null_price, v_main_price, v_names
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

  insert into public.bookings (
    service_id, service_name, price, duration_minutes,
    customer_name, customer_phone, postal_code, property_type,
    street, street_number, complement, district, city, state, reference,
    service_date, start_time, end_time, status
  ) values (
    p_service_ids[1], v_names, v_total_price, v_duration,
    p_customer_name, p_customer_phone, p_postal_code, p_property_type,
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

revoke all on function public.create_booking(uuid[],text,text,text,text,text,text,text,text,text,text,text,date,time,uuid) from public;
grant execute on function public.create_booking(uuid[],text,text,text,text,text,text,text,text,text,text,text,date,time,uuid) to anon, authenticated;
