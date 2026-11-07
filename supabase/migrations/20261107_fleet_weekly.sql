begin;

-- The assignment is current. Operational records retain their original account.
create table private.fleet_assignments (
  vehicle_id uuid primary key references public.vehicles(id) on delete restrict,
  account_email text not null references private.employee_access(email) on delete restrict
);
alter table private.fleet_assignments enable row level security;
revoke all on private.fleet_assignments from public, anon, authenticated;

alter table public.routes
  add column fleet_account text references private.employee_access(email);
alter table public.period_costs
  add column fleet_account text references private.employee_access(email);
alter table public.fuel_payments
  add column fleet_account text references private.employee_access(email);

create table private.fleet_route_operators (
  route_id uuid primary key references public.routes(id) on delete cascade,
  operator_name text not null check (length(operator_name) between 1 and 120)
);
alter table private.fleet_route_operators enable row level security;
revoke all on private.fleet_route_operators from public, anon, authenticated;

alter table public.period_costs drop constraint period_costs_category_check;
alter table public.period_costs add constraint period_costs_category_check
  check (category in ('operator','gps','reserve','unforeseen','gas_reserve','maintenance','administration','settlement_paid'));
alter table public.period_costs add constraint fleet_cost_single_week check (
  fleet_account is null or
  date_trunc('week', period_start::timestamp) = date_trunc('week', period_end::timestamp)
);

create index routes_fleet_week_idx on public.routes (fleet_account, scheduled_at) where fleet_account is not null;
create index costs_fleet_week_idx on public.period_costs (fleet_account, period_start) where fleet_account is not null;
create index fuel_fleet_week_idx on public.fuel_payments (fleet_account, occurred_at) where fleet_account is not null;

create function public.admin_fleet_assignments()
returns table (vehicle_id uuid, account_email text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.is_admin() then raise exception 'Acceso exclusivo de administración' using errcode = '42501'; end if;
  return query select a.vehicle_id, a.account_email from private.fleet_assignments a;
end;
$$;

create function public.admin_assign_fleet_vehicle(p_vehicle uuid, p_email text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not private.is_admin() then raise exception 'Acceso exclusivo de administración' using errcode = '42501'; end if;
  -- Use the employee-management lock when checking and assigning an account.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('mexroute.employee_access',0));
  if not exists (select 1 from private.employee_access e
                 where e.email = lower(btrim(p_email)) and e.active and e.role = 'driver') then
    raise exception 'Autoriza primero el correo como cuenta de consulta' using errcode = '22023';
  end if;
  insert into private.fleet_assignments (vehicle_id, account_email)
    values (p_vehicle, lower(btrim(p_email)))
    on conflict (vehicle_id) do update set account_email = excluded.account_email;
end;
$$;

create function public.admin_set_fleet_viewer(p_email text, p_active boolean)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not private.is_admin() then raise exception 'Acceso exclusivo de administración' using errcode = '42501'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('mexroute.employee_access',0));
  if exists (select 1 from private.employee_access where email = lower(btrim(p_email)) and role = 'admin') then
    raise exception 'Esta pantalla solo gestiona cuentas de consulta' using errcode = '22023';
  end if;
  perform public.admin_set_employee_access(p_email, p_active, 'driver');
end;
$$;

create function private.capture_fleet_account()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare assigned_email text;
declare assigned_user uuid;
declare route_record public.routes;
begin
  if tg_op = 'UPDATE' and old.fleet_account is not null then
    if new.vehicle_id is distinct from old.vehicle_id or new.fleet_account is distinct from old.fleet_account then
      raise exception 'La unidad y cuenta de un movimiento vinculado son fijas' using errcode = '23514';
    end if;
    if tg_table_name = 'routes' then
      if new.driver_id is distinct from old.driver_id then
        raise exception 'La cuenta de una ruta vinculada es fija' using errcode = '23514';
      end if;
    elsif tg_table_name = 'fuel_payments' then
      if new.route_id is distinct from old.route_id or new.driver_id is distinct from old.driver_id then
        raise exception 'La ruta y cuenta de una carga vinculada son fijas' using errcode = '23514';
      end if;
    end if;
    return new;
  end if;

  -- Legacy rows are linked only by an explicit admin selection of the unit/account.
  if new.fleet_account is null then return new; end if;
  if tg_table_name = 'fuel_payments' then
    if new.route_id is not null then
      select * into route_record from public.routes where id = new.route_id for share;
      if route_record.fleet_account is distinct from new.fleet_account
         or route_record.vehicle_id is distinct from new.vehicle_id
         or route_record.driver_id is distinct from new.driver_id then
        raise exception 'La gasolina debe corresponder a la unidad y cuenta de la ruta' using errcode = '23514';
      end if;
      return new;
    end if;
  end if;
  select a.account_email, e.user_id into assigned_email, assigned_user
  from private.fleet_assignments a join private.employee_access e on e.email = a.account_email
  where a.vehicle_id = new.vehicle_id and e.active and e.role = 'driver'
  for share of a, e;
  if assigned_email is distinct from new.fleet_account then
    raise exception 'La unidad ya no está asignada a esta cuenta' using errcode = '23514';
  end if;
  if tg_table_name in ('routes','fuel_payments') then
    if assigned_user is null or new.driver_id is distinct from assigned_user then
      raise exception 'La cuenta debe iniciar sesión y coincidir con la unidad' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function private.capture_fleet_account() from public, anon, authenticated;
create trigger capture_fleet_account before insert or update on public.routes
  for each row execute function private.capture_fleet_account();
create trigger capture_fleet_account before insert or update on public.period_costs
  for each row execute function private.capture_fleet_account();
create trigger capture_fleet_account before insert or update on public.fuel_payments
  for each row execute function private.capture_fleet_account();

create function public.admin_create_fleet_route(p_code text, p_date date, p_driver uuid, p_vehicle uuid,
  p_rate numeric, p_email text, p_operator text)
returns void language plpgsql security definer set search_path = ''
as $$
declare route_id uuid;
begin
  if not private.is_admin() then raise exception 'Acceso exclusivo de administración' using errcode = '42501'; end if;
  insert into public.routes (route_code, scheduled_at, driver_id, vehicle_id, route_rate, fleet_account)
    values (btrim(p_code), p_date, p_driver, p_vehicle, p_rate, p_email) returning id into route_id;
  if nullif(btrim(p_operator), '') is not null then
    insert into private.fleet_route_operators values (route_id, btrim(p_operator));
  end if;
end;
$$;

create function public.fleet_week(p_start date, p_email text default null)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare account text;
declare admin_access boolean := private.is_admin();
begin
  if not private.is_active_employee() then raise exception 'Acceso desactivado' using errcode = '42501'; end if;
  if p_start is null or not isfinite(p_start) or extract(isodow from p_start) <> 1 then
    raise exception 'Selecciona el lunes del periodo' using errcode = '22023';
  end if;
  if admin_access then
    account := lower(btrim(p_email));
  else
    select e.email into account from private.employee_access e where e.user_id = auth.uid();
    if p_email is not null and lower(btrim(p_email)) is distinct from account then
      raise exception 'Solo puedes consultar tu cuenta' using errcode = '42501';
    end if;
  end if;
  return jsonb_build_object(
    'routes', coalesce((select jsonb_agg(jsonb_build_object(
      'date', r.scheduled_at, 'code', r.route_code, 'plate', v.plate, 'status', r.status,
      'rate', r.route_rate, 'cancellation_rate', r.cancellation_rate,
      'operator', case when admin_access then o.operator_name end) order by r.scheduled_at, r.route_code)
      from public.routes r join public.vehicles v on v.id = r.vehicle_id
      left join private.fleet_route_operators o on o.route_id = r.id
      where r.fleet_account = account and r.scheduled_at between p_start and p_start + 6), '[]'::jsonb),
    'costs', coalesce((select jsonb_agg(jsonb_build_object(
      'start', c.period_start, 'end', c.period_end, 'plate', v.plate, 'category', c.category,
      'amount', c.amount, 'notes', case when admin_access then c.notes end) order by c.period_start, c.id)
      from public.period_costs c join public.vehicles v on v.id = c.vehicle_id
      where c.fleet_account = account and c.period_start between p_start and p_start + 6
        and c.period_end <= p_start + 6), '[]'::jsonb),
    'fuel', coalesce((select jsonb_agg(jsonb_build_object(
      'date', f.occurred_at, 'plate', v.plate, 'route', r.route_code,
      'amount', f.amount, 'status', f.status) order by f.occurred_at, f.id)
      from public.fuel_payments f join public.vehicles v on v.id = f.vehicle_id
      left join public.routes r on r.id = f.route_id
      where f.fleet_account = account and f.occurred_at between p_start and p_start + 6), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.admin_fleet_assignments(), public.admin_assign_fleet_vehicle(uuid,text),
  public.admin_set_fleet_viewer(text,boolean), public.admin_create_fleet_route(text,date,uuid,uuid,numeric,text,text),
  public.fleet_week(date,text) from public, anon;
grant execute on function public.admin_fleet_assignments(), public.admin_assign_fleet_vehicle(uuid,text),
  public.admin_set_fleet_viewer(text,boolean), public.admin_create_fleet_route(text,date,uuid,uuid,numeric,text,text),
  public.fleet_week(date,text) to authenticated;

commit;
