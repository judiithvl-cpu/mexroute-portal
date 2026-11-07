begin;
do $$
declare owner_account record;
declare other_account record;
declare admin_uid uuid;
declare payload jsonb := '[{"plate":"QA-HIST-01","row":2,"date":"2026-04-07","amount_mxn":"500.10","liters":"20.123"}]';
begin
  select user_id into strict admin_uid from private.employee_access
    where active and role = 'admin' and user_id is not null limit 1;
  select email, user_id into strict owner_account from private.employee_access
    where active and role = 'driver' and user_id is not null order by email limit 1;
  select email, user_id into strict other_account from private.employee_access
    where active and role = 'driver' and user_id is not null order by email offset 1 limit 1;
  perform set_config('request.jwt.claim.sub',admin_uid::text,true);
  perform set_config('mexroute.test.history_owner',owner_account.user_id::text,true);
  perform set_config('mexroute.test.history_other',other_account.user_id::text,true);
  assert public.admin_import_historical_fuel('QA-HIST-01',owner_account.email,repeat('a',64),payload) = 1;
  assert public.admin_import_historical_fuel('QA-HIST-01',owner_account.email,repeat('a',64),payload) = 0;
  assert public.admin_import_historical_fuel('QA-HIST-01',owner_account.email,repeat('b',64),payload) = 0;
  begin
    perform public.admin_import_historical_fuel('QA-HIST-01',other_account.email,repeat('a',64),payload);
    raise exception 'Se aceptó una cuenta distinta';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.admin_import_historical_fuel('QA-HIST-02',owner_account.email,repeat('a',64),payload);
    raise exception 'Se aceptó una placa distinta';
  exception when invalid_parameter_value then null; end;
  assert not exists (select 1 from public.vehicles where plate = 'QA-HIST-02');
  assert exists (select 1 from public.fleet_week_historical_fuel('2026-04-06',owner_account.email)
    where plate = 'QA-HIST-01' and amount = 500.10 and liters = 20.123);
  assert not exists (select 1 from public.fuel_payments f join public.vehicles v on v.id = f.vehicle_id
    where v.plate = 'QA-HIST-01');
end;
$$;
set local role authenticated;
do $$
begin
  perform set_config('request.jwt.claim.sub',current_setting('mexroute.test.history_owner'),true);
  assert exists (select 1 from public.fleet_week_historical_fuel('2026-04-06') where plate = 'QA-HIST-01');
  begin
    perform public.admin_import_historical_fuel('QA-HIST-01',null,repeat('a',64),'[]');
    raise exception 'La cuenta de consulta pudo importar';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',current_setting('mexroute.test.history_other'),true);
  assert not exists (select 1 from public.fleet_week_historical_fuel('2026-04-06') where plate = 'QA-HIST-01');
end;
$$;
reset role;
select 'Importación, duplicados y permisos verificados' as resultado;
rollback;
