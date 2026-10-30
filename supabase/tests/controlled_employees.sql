-- Every change in this test is rolled back. No email is sent and no real employee is authorized.
begin;
create temp table mr_employee_checks(test text,passed boolean) on commit drop;
grant select,insert on mr_employee_checks to authenticated;
select set_config('mr.admin',(select id::text from public.profiles where role='admin' order by created_at limit 1),true);
select set_config('mr.driver',(select id::text from public.profiles where role='driver' order by created_at limit 1),true);
select set_config('mr.driver_email',(select email from auth.users where id=current_setting('mr.driver')::uuid),true);
select set_config('mr.admin_email',(select email from auth.users where id=current_setting('mr.admin')::uuid),true);
select set_config('mr.baseline',(select jsonb_build_array((select count(*) from public.routes),(select count(*) from public.fuel_payments),(select count(*) from public.evidences),(select count(*) from public.workbook_history))::text),true);

-- Server-only hook rejects arbitrary emails, Email-provider registrations and malformed payloads.
insert into mr_employee_checks values('Auth service may execute hook',has_function_privilege('supabase_auth_admin','public.hook_employee_signup(jsonb)','EXECUTE'));
insert into mr_employee_checks values('anonymous cannot execute hook',not has_function_privilege('anon','public.hook_employee_signup(jsonb)','EXECUTE'));
-- Hosted Supabase does not permit SET ROLE supabase_auth_admin; call as function owner.
insert into mr_employee_checks values('unknown Google signup denied',public.hook_employee_signup('{"user":{"email":"qa-unknown@example.invalid","app_metadata":{"provider":"google"}}}') ? 'error');
insert into mr_employee_checks values('empty signup denied',public.hook_employee_signup('{}') ? 'error');
reset role;

-- Trigger must reject even when someone forgets to enable the Auth hook.
do $$ begin
 begin
  insert into auth.users(id,email,raw_app_meta_data,raw_user_meta_data) values(gen_random_uuid(),'qa-unknown@example.invalid','{"provider":"google"}','{}');
  insert into mr_employee_checks values('fallback trigger rejects unknown user',false);
 exception when insufficient_privilege then insert into mr_employee_checks values('fallback trigger rejects unknown user',true);end;
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('mr.driver'),true);
insert into mr_employee_checks values('existing driver remains active',(public.my_employee_access()->>'active')::boolean);
insert into mr_employee_checks values('driver reads own profile',exists(select 1 from public.profiles where id=auth.uid()));
do $$ begin
 begin perform public.admin_set_employee_access('qa-member@example.invalid',true,'admin');
  insert into mr_employee_checks values('driver cannot authorize or promote',false);
 exception when insufficient_privilege then insert into mr_employee_checks values('driver cannot authorize or promote',true);end;
 begin perform * from public.admin_list_employee_access();
  insert into mr_employee_checks values('driver cannot list employees',false);
 exception when insufficient_privilege then insert into mr_employee_checks values('driver cannot list employees',true);end;
 begin perform * from private.employee_access;
  insert into mr_employee_checks values('private allowlist is inaccessible',false);
 exception when insufficient_privilege then insert into mr_employee_checks values('private allowlist is inaccessible',true);end;
 begin perform public.hook_employee_signup('{}');
  insert into mr_employee_checks values('driver cannot call server hook',false);
 exception when insufficient_privilege then insert into mr_employee_checks values('driver cannot call server hook',true);end;
end $$;

select set_config('request.jwt.claim.sub',current_setting('mr.admin'),true);
insert into mr_employee_checks values('existing administrator preserved',private.is_admin());
do $$ declare n bigint; begin
 begin perform public.admin_set_employee_access(current_setting('mr.admin_email'),false,'admin');
  insert into mr_employee_checks values('last administrator cannot be disabled',false);
 exception when check_violation then insert into mr_employee_checks values('last administrator cannot be disabled',true);end;
 begin perform public.admin_set_employee_access(current_setting('mr.admin_email'),true,'driver');
  insert into mr_employee_checks values('last administrator cannot be demoted',false);
 exception when check_violation then insert into mr_employee_checks values('last administrator cannot be demoted',true);end;
 begin update public.profiles set role='driver' where id=auth.uid();
  insert into mr_employee_checks values('direct role update cannot bypass registry',false);
 exception when insufficient_privilege then insert into mr_employee_checks values('direct role update cannot bypass registry',true);end;
 delete from public.profiles where id=auth.uid();get diagnostics n=row_count;
 insert into mr_employee_checks values('administrator cannot delete profile via client',n=0);
 begin perform public.admin_set_employee_access('invalid',true,'driver');
  insert into mr_employee_checks values('invalid email rejected',false);
 exception when invalid_parameter_value then insert into mr_employee_checks values('invalid email rejected',true);end;
end $$;
select public.admin_set_employee_access('  QA-MEMBER@EXAMPLE.INVALID  ',true,'driver');
reset role;
insert into mr_employee_checks values('email normalized',exists(select 1 from private.employee_access where email='qa-member@example.invalid' and user_id is null and role='driver'));
-- Hosted Supabase does not permit SET ROLE supabase_auth_admin; call as function owner.
insert into mr_employee_checks values('authorized Google signup allowed',public.hook_employee_signup('{"user":{"email":"qa-member@example.invalid","app_metadata":{"provider":"google"},"user_metadata":{"role":"admin"}}}')='{}'::jsonb);
insert into mr_employee_checks values('authorized Email signup still denied',public.hook_employee_signup('{"user":{"email":"qa-member@example.invalid","app_metadata":{"provider":"email"}}}') ? 'error');
reset role;
do $$ declare created_user uuid:=gen_random_uuid(); begin
 insert into auth.users(id,email,raw_app_meta_data,raw_user_meta_data,email_confirmed_at)
 values(created_user,'qa-member@example.invalid','{"provider":"google","providers":["google"]}','{"role":"admin","full_name":"QA ROLLBACK"}',now());
 insert into mr_employee_checks values('trigger uses authorized role, not metadata',exists(select 1 from public.profiles where id=created_user and role='driver'));
 insert into mr_employee_checks values('trigger binds authorized user ID',exists(select 1 from private.employee_access where email='qa-member@example.invalid' and user_id=created_user));
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('mr.admin'),true);
select public.admin_set_employee_access(current_setting('mr.driver_email'),false,'driver');
select set_config('request.jwt.claim.sub',current_setting('mr.driver'),true);
insert into mr_employee_checks values('disabled employee reports inactive',not (public.my_employee_access()->>'active')::boolean);
insert into mr_employee_checks values('disabled employee cannot read profile',not exists(select 1 from public.profiles));
insert into mr_employee_checks values('disabled employee cannot read routes',not exists(select 1 from public.routes));
insert into mr_employee_checks values('disabled employee cannot read gasoline',not exists(select 1 from public.fuel_payments));
insert into mr_employee_checks values('disabled employee cannot read evidences',not exists(select 1 from public.evidences));
insert into mr_employee_checks values('disabled employee cannot request new file access',not exists(select 1 from storage.objects where bucket_id='operation-files'));
select set_config('request.jwt.claim.sub',current_setting('mr.admin'),true);
select public.admin_set_employee_access(current_setting('mr.driver_email'),true,'driver');
insert into mr_employee_checks values('administrator sees access audit',(select count(*)>=3 from public.admin_employee_access_audit(200)));
select set_config('request.jwt.claim.sub',current_setting('mr.driver'),true);
insert into mr_employee_checks values('reactivated driver can read profile',exists(select 1 from public.profiles where id=auth.uid()));
reset role;
insert into mr_employee_checks values('business records were not changed',current_setting('mr.baseline')=(select jsonb_build_array((select count(*) from public.routes),(select count(*) from public.fuel_payments),(select count(*) from public.evidences),(select count(*) from public.workbook_history))::text));
select jsonb_build_object('checks',count(*),'passed',count(*) filter(where passed),'failures',coalesce(jsonb_agg(test) filter(where not passed),'[]'::jsonb)) as employee_tests from mr_employee_checks;
rollback;
