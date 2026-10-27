-- Run as database owner in the SQL editor. All test records are rolled back.
begin;
create temp table mr_permission_checks(test text,passed boolean,detail text) on commit drop;
grant select,insert on mr_permission_checks to authenticated;
select set_config('mr.test_driver',(select id::text from public.profiles where role='driver' order by created_at limit 1),true);
select set_config('mr.test_admin',(select id::text from public.profiles where role='admin' order by created_at limit 1),true);
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('mr.test_driver'),true);
do $tests$
declare command text; t text; n bigint; route uuid;
begin
 if auth.uid() is null then raise exception 'A registered driver is required for this test.'; end if;
 insert into mr_permission_checks values('driver can read own profile',exists(select 1 from public.profiles where id=auth.uid()),'SELECT preserved');
 insert into mr_permission_checks values('driver cannot read other routes',not exists(select 1 from public.routes where driver_id<>auth.uid()),'RLS preserved');
 insert into mr_permission_checks values('driver cannot read administrative costs',not exists(select 1 from public.period_costs),'RLS preserved');
 select id into route from public.routes where driver_id=auth.uid() limit 1;
 foreach command in array array[
  format('insert into public.fuel_payments(driver_id,amount,liters,station) values(%L,1,1,''QA ROLLBACK - NO OPERATIVO'')',auth.uid()),
  format('insert into public.routes(route_code,driver_id) values(''QA-READONLY-ROLLBACK'',%L)',auth.uid()),
  'insert into public.period_costs(period_start,period_end,category,amount) values(current_date,current_date,''operator'',1)'
 ] loop
  begin execute command;insert into mr_permission_checks values('driver INSERT denied',false,command);
  exception when insufficient_privilege then insert into mr_permission_checks values('driver INSERT denied',true,'42501');end;
 end loop;
 if route is not null then
  begin insert into public.evidences(route_id,driver_id,file_path) values(route,auth.uid(),auth.uid()||'/qa-not-uploaded.png');
   insert into mr_permission_checks values('driver evidence INSERT denied',false,'Unexpectedly inserted');
  exception when insufficient_privilege then insert into mr_permission_checks values('driver evidence INSERT denied',true,'42501');end;
 end if;
 foreach t in array array['profiles','vehicles','routes','fuel_payments','evidences','period_costs'] loop
  execute format('update public.%I set id=id',t);get diagnostics n=row_count;
  insert into mr_permission_checks values('driver UPDATE denied: '||t,n=0,n||' affected');
  execute format('delete from public.%I',t);get diagnostics n=row_count;
  insert into mr_permission_checks values('driver DELETE denied: '||t,n=0,n||' affected');
 end loop;
 begin perform public.set_route_progress(coalesce(route,gen_random_uuid()),'in_progress',1);
  insert into mr_permission_checks values('driver RPC denied',false,'Unexpectedly permitted');
 exception when insufficient_privilege then insert into mr_permission_checks values('driver RPC denied',true,'42501');end;
 begin perform private.set_route_progress(coalesce(route,gen_random_uuid()),'in_progress',1);
  insert into mr_permission_checks values('driver private RPC denied',false,'Unexpectedly permitted');
 exception when insufficient_privilege then insert into mr_permission_checks values('driver private RPC denied',true,'42501');end;
 -- Test insert permission on metadata only. No physical file is uploaded or deleted.
 begin insert into storage.objects(bucket_id,name) values('operation-files',auth.uid()||'/qa-readonly-rollback.png');
  insert into mr_permission_checks values('driver storage INSERT denied',false,'Unexpectedly permitted');
 exception when insufficient_privilege then insert into mr_permission_checks values('driver storage INSERT denied',true,'42501');end;
end $tests$;
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('mr.test_admin'),true);
do $tests$
declare route uuid; payment uuid; n bigint;
begin
 if not private.is_admin() then raise exception 'A registered administrator is required for this test.'; end if;
 insert into public.routes(route_code,driver_id) values('QA-ADMIN-READONLY-ROLLBACK',current_setting('mr.test_driver')::uuid) returning id into route;
 perform public.set_route_progress(route,'in_progress',100);
 perform public.set_route_progress(route,'completed',105);
 insert into mr_permission_checks values('admin route RPC preserved',exists(select 1 from public.routes where id=route and status='completed' and km_end=105),'Rollback only');
 insert into public.fuel_payments(driver_id,route_id,amount,liters,station) values(current_setting('mr.test_driver')::uuid,route,1,1,'QA ROLLBACK - NO OPERATIVO') returning id into payment;
 update public.fuel_payments set status='approved',reviewed_by=auth.uid(),reviewed_at=now() where id=payment;get diagnostics n=row_count;
 insert into mr_permission_checks values('admin fuel INSERT/UPDATE preserved',n=1,'Rollback only');
 insert into public.period_costs(period_start,period_end,category,amount) values(current_date,current_date,'operator',1);
 insert into mr_permission_checks values('admin costs INSERT preserved',true,'Rollback only');
 delete from public.fuel_payments where id=payment;get diagnostics n=row_count;
 insert into mr_permission_checks values('admin DELETE preserved',n=1,'Rollback only');
end $tests$;
select jsonb_build_object('checks',count(*),'passed',count(*) filter(where passed),'failures',coalesce(jsonb_agg(test||': '||detail) filter(where not passed),'[]'::jsonb)) as results from mr_permission_checks;
rollback;
