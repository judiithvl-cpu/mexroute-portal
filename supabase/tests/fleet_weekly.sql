begin;

do $$
declare admin_uid uuid;
declare first_account record;
declare second_account record;
declare first_unit uuid;
declare second_unit uuid;
declare first_route uuid;
begin
  select e.user_id into strict admin_uid from private.employee_access e
    where e.active and e.role = 'admin' and e.user_id is not null limit 1;
  select e.email,e.user_id into strict first_account from private.employee_access e
    where e.active and e.role = 'driver' and e.user_id is not null order by e.email limit 1;
  select e.email,e.user_id into strict second_account from private.employee_access e
    where e.active and e.role = 'driver' and e.user_id is not null order by e.email offset 1 limit 1;
  perform set_config('request.jwt.claim.sub',admin_uid::text,true);
  perform set_config('mexroute.test.first_uid',first_account.user_id::text,true);
  perform set_config('mexroute.test.second_uid',second_account.user_id::text,true);
  perform set_config('mexroute.test.second_email',second_account.email,true);

  insert into public.vehicles (plate) values ('QA-FLEET-ONE') returning id into first_unit;
  insert into public.vehicles (plate) values ('QA-FLEET-TWO') returning id into second_unit;
  perform public.admin_assign_fleet_vehicle(first_unit,first_account.email);
  perform public.admin_assign_fleet_vehicle(second_unit,first_account.email);
  perform public.admin_create_fleet_route('QA-FLEET-01','2026-11-02',first_account.user_id,first_unit,1500,first_account.email,'Operador de prueba A');
  perform public.admin_create_fleet_route('QA-FLEET-02','2026-11-08',first_account.user_id,second_unit,1200,first_account.email,'Operador de prueba B');
  select id into strict first_route from public.routes where route_code = 'QA-FLEET-01';
  update public.routes set status = 'completed' where id = first_route;
  insert into public.period_costs (vehicle_id, fleet_account, period_start, period_end, category, amount, notes)
    values (first_unit,first_account.email,'2026-11-02','2026-11-08','operator',250,'Referencia privada'),
           (second_unit,first_account.email,'2026-11-02','2026-11-08','settlement_paid',500,null);
  insert into public.fuel_payments (vehicle_id,fleet_account,driver_id,route_id,occurred_at,amount,liters,status)
    values (first_unit,first_account.email,first_account.user_id,first_route,'2026-11-03',300,12,'approved');
  assert public.fleet_week('2026-11-02',first_account.email)#>>'{routes,0,operator}' = 'Operador de prueba A';
  assert public.fleet_week('2026-11-02',first_account.email)#>>'{costs,0,notes}' is not null
      or public.fleet_week('2026-11-02',first_account.email)#>>'{costs,1,notes}' is not null;

  perform public.admin_assign_fleet_vehicle(first_unit,second_account.email);
  begin
    insert into public.period_costs (vehicle_id,fleet_account,period_start,period_end,category,amount)
      values (first_unit,first_account.email,'2026-11-02','2026-11-08','gps',1);
    raise exception 'La asignación anterior sigue aceptando gastos nuevos';
  exception when check_violation then null; end;
  begin
    insert into public.period_costs (vehicle_id,fleet_account,period_start,period_end,category,amount)
      values (first_unit,second_account.email,'2026-11-02','2026-11-09','gps',1);
    raise exception 'Se aceptó un costo que cruza de semana';
  exception when check_violation then null; end;
  assert public.fleet_week('2026-11-02',second_account.email) = '{"routes":[],"costs":[],"fuel":[]}'::jsonb;
end;
$$;

set local role authenticated;
do $$
declare report jsonb;
begin
  perform set_config('request.jwt.claim.sub',current_setting('mexroute.test.first_uid'),true);
  report := public.fleet_week('2026-11-02');
  assert jsonb_array_length(report->'routes') = 2;
  assert jsonb_array_length(report->'costs') = 2;
  assert jsonb_array_length(report->'fuel') = 1;
  assert report#>>'{routes,0,operator}' is null;
  assert report#>>'{costs,0,notes}' is null and report#>>'{costs,1,notes}' is null;
  assert public.fleet_week('2026-11-09') = '{"routes":[],"costs":[],"fuel":[]}'::jsonb;
  begin
    perform public.fleet_week('2026-11-02',current_setting('mexroute.test.second_email'));
    raise exception 'El usuario pudo seleccionar otra cuenta';
  exception when insufficient_privilege then null; end;
  begin
    perform public.admin_fleet_assignments();
    raise exception 'El usuario pudo listar asignaciones ajenas';
  exception when insufficient_privilege then null; end;
  begin
    perform public.admin_set_fleet_viewer('qa-fleet@example.invalid',true);
    raise exception 'El usuario pudo dar de alta a otro';
  exception when insufficient_privilege then null; end;
  begin
    perform public.admin_create_fleet_route('QA-DENY','2026-11-02',auth.uid(),null,1,null,null);
    raise exception 'El usuario pudo registrar una ruta';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',current_setting('mexroute.test.second_uid'),true);
  assert public.fleet_week('2026-11-02') = '{"routes":[],"costs":[],"fuel":[]}'::jsonb;
end;
$$;
reset role;
select 'Desglose, reasignación y permisos verificados' as resultado;
rollback;
