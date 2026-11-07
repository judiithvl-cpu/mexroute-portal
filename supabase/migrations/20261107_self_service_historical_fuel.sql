begin;

create table private.fleet_historical_fuel (
  id bigint generated always as identity primary key,
  vehicle_id uuid not null references public.vehicles(id) on delete restrict,
  account_email text not null references private.employee_access(email) on delete restrict,
  occurred_at date not null,
  amount numeric(12,2) not null check (amount > 0),
  liters numeric(10,3) not null check (liters > 0),
  source_hash text not null check (source_hash ~ '^[0-9a-f]{64}$'),
  source_row integer not null check (source_row > 1),
  imported_by uuid not null references public.profiles(id) on delete restrict,
  imported_at timestamptz not null default now(),
  unique (source_hash, vehicle_id, source_row),
  unique (vehicle_id, occurred_at, amount, liters)
);
create index historical_fuel_account_week_idx on private.fleet_historical_fuel(account_email, occurred_at);
alter table private.fleet_historical_fuel enable row level security;
revoke all on private.fleet_historical_fuel from public, anon, authenticated;

create function public.admin_import_historical_fuel(p_plate text, p_email text, p_source_hash text, p_rows jsonb)
returns integer language plpgsql security definer set search_path = ''
as $$
declare unit_id uuid;
declare account text := lower(btrim(p_email));
declare normalized_plate text := upper(btrim(p_plate));
declare imported integer;
begin
  if not private.is_admin() then raise exception 'Acceso exclusivo de administración' using errcode = '42501'; end if;
  if account is null or normalized_plate is null or normalized_plate !~ '^[A-Z0-9-]{4,15}$'
     or p_source_hash is null or p_source_hash !~ '^[0-9a-f]{64}$'
     or jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'Archivo o destino inválido' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) not between 1 and 500 then
    raise exception 'El lote debe tener de 1 a 500 cargas de una unidad' using errcode = '22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('mexroute.employee_access',0));
  if not exists (select 1 from private.employee_access e where e.email = account and e.active and e.role = 'driver') then
    raise exception 'Autoriza primero el correo como cuenta de consulta' using errcode = '22023';
  end if;

  insert into public.vehicles(plate) values(normalized_plate) on conflict (plate) do nothing;
  select id into strict unit_id from public.vehicles where plate = normalized_plate and active for share;
  if exists(select 1 from private.fleet_assignments a where a.vehicle_id = unit_id and a.account_email <> account) then
    raise exception 'La unidad ya tiene otra cuenta asignada. Revisa la asignación antes de importar.' using errcode = '22023';
  end if;

  if exists (
    select 1 from jsonb_to_recordset(p_rows) r(plate text, row integer, date date, amount_mxn numeric, liters numeric)
    where r.plate is distinct from normalized_plate or r.row is null or r.row < 2
      or r.date is null or not isfinite(r.date) or r.date > timezone('America/Mexico_City', now())::date
      or r.amount_mxn is null or not (r.amount_mxn > 0 and r.amount_mxn < 10000000000)
      or r.liters is null or not (r.liters > 0 and r.liters < 10000000)
      or r.amount_mxn <> round(r.amount_mxn,2) or r.liters <> round(r.liters,3)
  ) then raise exception 'Hay una carga con placa, fecha, importe o litros inválidos' using errcode = '22023'; end if;
  if exists (
    select 1 from jsonb_to_recordset(p_rows) r(row integer)
    group by r.row having count(*) > 1
  ) then raise exception 'Hay filas de origen repetidas dentro del lote' using errcode = '22023'; end if;

  if exists (
    select 1 from jsonb_to_recordset(p_rows) r(row integer, date date, amount_mxn numeric, liters numeric)
    join private.fleet_historical_fuel f on f.vehicle_id = unit_id and
      ((f.source_hash = p_source_hash and f.source_row = r.row) or
       (f.occurred_at = r.date and f.amount = r.amount_mxn and f.liters = r.liters))
    where f.account_email <> account or f.occurred_at <> r.date or f.amount <> r.amount_mxn or f.liters <> r.liters
  ) then raise exception 'El lote contiene una carga ya registrada con otra cuenta o datos diferentes' using errcode = '22023'; end if;

  insert into private.fleet_assignments(vehicle_id, account_email) values(unit_id, account)
    on conflict (vehicle_id) do nothing;
  insert into private.fleet_historical_fuel(vehicle_id, account_email, occurred_at, amount, liters, source_hash, source_row, imported_by)
    select unit_id, account, r.date, r.amount_mxn, r.liters, p_source_hash, r.row, auth.uid()
    from jsonb_to_recordset(p_rows) r(row integer, date date, amount_mxn numeric, liters numeric)
    on conflict do nothing;
  get diagnostics imported = row_count;
  return imported;
end;
$$;

create function public.fleet_week_historical_fuel(p_start date, p_email text default null)
returns table (date date, plate text, amount numeric, liters numeric)
language plpgsql stable security definer set search_path = ''
as $$
declare account text;
begin
  if not private.is_active_employee() then raise exception 'Acceso desactivado' using errcode = '42501'; end if;
  if p_start is null or not isfinite(p_start) or extract(isodow from p_start) <> 1 then
    raise exception 'Selecciona el lunes del periodo' using errcode = '22023';
  end if;
  if private.is_admin() then
    account := lower(btrim(p_email));
  else
    select e.email into account from private.employee_access e where e.user_id = auth.uid();
    if p_email is not null and lower(btrim(p_email)) is distinct from account then
      raise exception 'Solo puedes consultar tu cuenta' using errcode = '42501';
    end if;
  end if;
  return query select f.occurred_at, v.plate, f.amount, f.liters
    from private.fleet_historical_fuel f join public.vehicles v on v.id = f.vehicle_id
    where f.account_email = account and f.occurred_at between p_start and p_start + 6
    order by f.occurred_at, v.plate, f.id;
end;
$$;
revoke all on function public.admin_import_historical_fuel(text,text,text,jsonb),
  public.fleet_week_historical_fuel(date,text) from public, anon;
grant execute on function public.admin_import_historical_fuel(text,text,text,jsonb),
  public.fleet_week_historical_fuel(date,text) to authenticated;

commit;
