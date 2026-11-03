-- AD Estetica Automotiva: schema inicial Supabase
-- Execute no SQL Editor do projeto ayxgfmzwdkqeidqurbpz.
-- O primeiro administrador deve ser criado em Authentication > Users (invite)
-- com o e-mail jonassilva2006@gmail.com; depois associe o UUID em admin_users.

create extension if not exists pgcrypto;

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.services (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text not null default '',
  category text not null default 'Personalizados',
  price numeric(10,2),
  duration_hours integer not null check (duration_hours between 1 and 24),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.business_hours (
  weekday smallint primary key check (weekday between 1 and 6),
  opens_at time not null,
  closes_at time not null,
  check (opens_at < closes_at)
);

create table if not exists public.blocked_slots (
  id uuid primary key default gen_random_uuid(),
  service_date date not null,
  start_time time not null,
  created_at timestamptz not null default now(),
  unique(service_date, start_time)
);

create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  service_id uuid references public.services(id) on delete set null,
  service_name text not null,
  price numeric(10,2),
  duration_hours integer not null check (duration_hours between 1 and 24),
  customer_name text not null,
  customer_phone text not null,
  postal_code text,
  property_type text,
  street text,
  street_number text,
  complement text,
  district text,
  city text,
  state text,
  reference text,
  service_date date not null,
  start_time time not null,
  end_time time not null,
  status text not null default 'Pendente'
    check (status in ('Pendente','Confirmado','Cancelado')),
  created_at timestamptz not null default now(),
  check (end_time > start_time)
);

create index if not exists bookings_date_idx on public.bookings(service_date);
create index if not exists bookings_status_idx on public.bookings(status);
create index if not exists blocked_slots_date_idx on public.blocked_slots(service_date);

create or replace function public.is_admin()
returns boolean language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.admin_users a
    where a.user_id = (select auth.uid())
  );
$$;

alter table public.admin_users enable row level security;
alter table public.services enable row level security;
alter table public.business_hours enable row level security;
alter table public.blocked_slots enable row level security;
alter table public.bookings enable row level security;

-- Visitantes podem consultar apenas serviços ativos e horários publicados.
drop policy if exists "Public reads active services" on public.services;
create policy "Public reads active services" on public.services
for select to anon, authenticated using (active or public.is_admin());

drop policy if exists "Admins manage services" on public.services;
create policy "Admins manage services" on public.services
for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Public reads business hours" on public.business_hours;
create policy "Public reads business hours" on public.business_hours
for select to anon, authenticated using (true);
drop policy if exists "Admins manage business hours" on public.business_hours;
create policy "Admins manage business hours" on public.business_hours
for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Public reads blocked slots" on public.blocked_slots;
create policy "Public reads blocked slots" on public.blocked_slots
for select to anon, authenticated using (true);
drop policy if exists "Admins manage blocked slots" on public.blocked_slots;
create policy "Admins manage blocked slots" on public.blocked_slots
for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Dados pessoais dos clientes nunca ficam disponíveis para visitantes.
drop policy if exists "Admins read bookings" on public.bookings;
create policy "Admins read bookings" on public.bookings
for select to authenticated using (public.is_admin());
drop policy if exists "Admins update bookings" on public.bookings;
create policy "Admins update bookings" on public.bookings
for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "Admins delete bookings" on public.bookings;
create policy "Admins delete bookings" on public.bookings
for delete to authenticated using (public.is_admin());

-- A criação de agendamento é feita por RPC. A trava consultiva evita dois
-- agendamentos simultâneos no mesmo dia; a função também verifica conflitos.
create or replace function public.create_booking(
  p_service_id uuid,
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
  p_start_time time
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_service public.services%rowtype;
  v_start timestamp;
  v_end timestamp;
  v_id uuid;
begin
  if p_service_date < current_date then
    raise exception 'A data escolhida já passou.';
  end if;

  select * into v_service
  from public.services
  where id = p_service_id and active = true;

  if not found then
    raise exception 'Serviço indisponível.';
  end if;

  if extract(dow from p_service_date) = 0 then
    raise exception 'Não há atendimento aos domingos.';
  end if;

  v_start := p_service_date + p_start_time;
  v_end := v_start + make_interval(hours => v_service.duration_hours);

  perform pg_advisory_xact_lock(hashtext(p_service_date::text));

  if exists (
    select 1 from public.blocked_slots b
    where b.service_date = p_service_date
      and b.start_time >= p_start_time
      and b.start_time < v_end::time
  ) then
    raise exception 'Este horário está bloqueado.';
  end if;

  if exists (
    select 1 from public.bookings b
    where b.service_date = p_service_date
      and b.status <> 'Cancelado'
      and p_start_time < b.end_time
      and b.start_time < v_end::time
  ) then
    raise exception 'Este horário acabou de ser reservado. Escolha outro.';
  end if;

  insert into public.bookings (
    service_id, service_name, price, duration_hours,
    customer_name, customer_phone, postal_code, property_type,
    street, street_number, complement, district, city, state, reference,
    service_date, start_time, end_time
  ) values (
    v_service.id, v_service.name, v_service.price, v_service.duration_hours,
    trim(p_customer_name), trim(p_customer_phone), p_postal_code, p_property_type,
    p_street, p_street_number, p_complement, p_district, p_city, p_state, p_reference,
    p_service_date, p_start_time, v_end::time
  ) returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.create_booking(uuid,text,text,text,text,text,text,text,text,text,text,text,date,time) from public;
grant execute on function public.create_booking(uuid,text,text,text,text,text,text,text,text,text,text,text,date,time) to anon, authenticated;

-- Não há políticas de INSERT público em bookings: somente a RPC pode criar reservas.
-- Após criar o usuário no Auth, execute:
-- insert into public.admin_users(user_id,email)
-- select id, email from auth.users
-- where lower(email) = lower('jonassilva2006@gmail.com')
-- on conflict (user_id) do update set email = excluded.email;
