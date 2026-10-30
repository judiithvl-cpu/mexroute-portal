-- Backend only: no changes to auth.js or the collaborator's PR.
begin;
create table private.employee_access (
 email text primary key check(email=lower(btrim(email)) and length(email)<=254),
 user_id uuid unique references auth.users(id) on delete set null,
 role public.app_role not null default 'driver',
 active boolean not null default true,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 changed_by uuid
);
create table private.employee_access_audit (
 id bigint generated always as identity primary key,
 occurred_at timestamptz not null default now(), actor_id uuid,
 email text not null, previous_value jsonb, new_value jsonb not null
);
alter table private.employee_access enable row level security;
alter table private.employee_access_audit enable row level security;
revoke all on private.employee_access,private.employee_access_audit from public,anon,authenticated;
-- Preserve existing confirmed employees and their existing roles. No promotion by email.
insert into private.employee_access(email,user_id,role,active)
select lower(btrim(u.email)),u.id,p.role,u.email_confirmed_at is not null
from auth.users u join public.profiles p on p.id=u.id;

create function private.is_active_employee() returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.employee_access e join auth.users u on u.id=e.user_id
 where e.user_id=auth.uid() and e.active and u.email_confirmed_at is not null
 and lower(btrim(u.email))=e.email
 and exists(select 1 from auth.identities i where i.user_id=u.id and i.provider='google'));
$$;
revoke all on function private.is_active_employee() from public,anon;
grant execute on function private.is_active_employee() to authenticated;
create or replace function private.is_admin() returns boolean
language sql stable security definer set search_path='' as $$
 select private.is_active_employee() and exists(
 select 1 from private.employee_access e join public.profiles p on p.id=e.user_id
 where e.user_id=auth.uid() and e.active and e.role='admin' and p.role='admin');
$$;
revoke all on function private.is_admin() from public,anon;
grant execute on function private.is_admin() to authenticated;

create or replace function private.handle_new_user() returns trigger
language plpgsql security definer set search_path='' as $$
declare membership private.employee_access;
begin
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('mexroute.employee_access',0));
 select * into membership from private.employee_access where email=lower(btrim(new.email)) for update;
 if not found or not membership.active or membership.user_id is not null
 or coalesce(new.raw_app_meta_data->>'provider','')<>'google' then
  raise exception 'Acceso no autorizado. Administración debe autorizar tu correo antes del primer ingreso con Google.' using errcode='42501';
 end if;
 update private.employee_access set user_id=new.id,updated_at=now() where email=membership.email;
 insert into public.profiles(id,full_name,role)
 values(new.id,coalesce(new.raw_user_meta_data->>'full_name',''),membership.role);
 return new;
end; $$;
revoke all on function private.handle_new_user() from public,anon,authenticated;

-- A public Auth hook with no anon/authenticated execution permission.
-- The AFTER INSERT trigger above is the authoritative fallback even if the hook is not enabled.
create function public.hook_employee_signup(event jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if coalesce(event->'user'->'app_metadata'->>'provider','')<>'google'
 or not exists(select 1 from private.employee_access e
 where e.email=lower(btrim(event->'user'->>'email')) and e.active and e.user_id is null) then
  return jsonb_build_object('error',jsonb_build_object('http_code',403,'message','Acceso no autorizado. Solicita a administración el alta de tu correo para ingresar con Google.'));
 end if;
 return '{}'::jsonb;
end; $$;
revoke all on function public.hook_employee_signup(jsonb) from public,anon,authenticated;
grant execute on function public.hook_employee_signup(jsonb) to supabase_auth_admin;

-- Role writes must agree with the private authorization record, including direct REST updates.
create function private.enforce_employee_role() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from private.employee_access where user_id=new.id and role=new.role) then
  raise exception 'El rol debe modificarse con admin_set_employee_access.' using errcode='42501';
 end if;
 return new;
end; $$;
revoke all on function private.enforce_employee_role() from public,anon,authenticated;
create trigger enforce_employee_role before insert or update of role on public.profiles
for each row execute function private.enforce_employee_role();
create policy mr_profiles_no_client_delete on public.profiles as restrictive for delete to authenticated using(false);

-- Restrict existing SELECT/write policies without replacing their ownership rules.
do $policies$
declare t text;
begin
 foreach t in array array['profiles','vehicles','routes','fuel_payments','evidences','period_costs','workbook_history'] loop
  execute format('create policy mr_active_employee on public.%I as restrictive for all to authenticated using ((select private.is_active_employee())) with check ((select private.is_active_employee()))',t);
 end loop;
end $policies$;
create policy mr_active_employee_files on storage.objects as restrictive for all to authenticated
using(bucket_id<>'operation-files' or (select private.is_active_employee()))
with check(bucket_id<>'operation-files' or (select private.is_active_employee()));

create function public.my_employee_access() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('active',private.is_active_employee(),'role',
 (select e.role from private.employee_access e where e.user_id=auth.uid()));
$$;
create function public.admin_list_employee_access()
returns table(email text,user_id uuid,full_name text,role public.app_role,active boolean,updated_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_admin() then raise exception 'Solo administración puede consultar empleados.' using errcode='42501'; end if;
 return query select e.email,e.user_id,coalesce(p.full_name,''),e.role,e.active,e.updated_at
 from private.employee_access e left join public.profiles p on p.id=e.user_id order by e.email;
end; $$;

create function public.admin_set_employee_access(p_email text,p_active boolean,p_role text default 'driver')
returns jsonb language plpgsql security definer set search_path='' as $$
declare normalized text:=lower(btrim(p_email)); old_entry private.employee_access;
 target_user uuid; desired_role public.app_role; new_entry private.employee_access;
begin
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('mexroute.employee_access',0));
 if not private.is_admin() then raise exception 'Solo administración puede autorizar empleados.' using errcode='42501'; end if;
 if normalized is null or length(normalized)>254 or normalized !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
 or p_active is null or p_role is null or p_role not in ('admin','driver') then
  raise exception 'Correo, estado o rol inválido.' using errcode='22023';
 end if;
 desired_role:=p_role::public.app_role;
 select * into old_entry from private.employee_access where employee_access.email=normalized for update;
 if old_entry.active and old_entry.role='admin' and old_entry.user_id is not null
 and (not p_active or desired_role<>'admin') and not exists(
  select 1 from private.employee_access e join public.profiles p on p.id=e.user_id join auth.users u on u.id=e.user_id
  where e.email<>normalized and e.active and e.role='admin' and p.role='admin' and u.email_confirmed_at is not null
  and lower(btrim(u.email))=e.email and exists(select 1 from auth.identities i where i.user_id=u.id and i.provider='google')) then
  raise exception 'No puedes desactivar ni degradar al último administrador activo.' using errcode='23514';
 end if;
 select u.id into target_user from auth.users u where lower(btrim(u.email))=normalized;
 insert into private.employee_access as e(email,user_id,role,active,changed_by)
 values(normalized,target_user,desired_role,p_active,auth.uid())
 on conflict(email) do update set user_id=excluded.user_id,role=excluded.role,active=excluded.active,changed_by=excluded.changed_by,updated_at=now()
 returning * into new_entry;
 if target_user is not null then update public.profiles set role=desired_role where id=target_user; end if;
 insert into private.employee_access_audit(actor_id,email,previous_value,new_value)
 values(auth.uid(),normalized,case when old_entry.email is null then null else to_jsonb(old_entry) end,to_jsonb(new_entry));
 return jsonb_build_object('email',new_entry.email,'user_id',new_entry.user_id,'role',new_entry.role,'active',new_entry.active);
end; $$;

create function public.admin_employee_access_audit(p_limit integer default 50)
returns table(id bigint,occurred_at timestamptz,actor_id uuid,email text,previous_value jsonb,new_value jsonb)
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_admin() then raise exception 'Solo administración puede consultar la bitácora.' using errcode='42501'; end if;
 return query select a.id,a.occurred_at,a.actor_id,a.email,a.previous_value,a.new_value
 from private.employee_access_audit a order by a.id desc limit greatest(1,least(coalesce(p_limit,50),200));
end; $$;
revoke all on function public.my_employee_access(),public.admin_list_employee_access(),public.admin_set_employee_access(text,boolean,text),public.admin_employee_access_audit(integer) from public,anon;
grant execute on function public.my_employee_access(),public.admin_list_employee_access(),public.admin_set_employee_access(text,boolean,text),public.admin_employee_access_audit(integer) to authenticated;

-- Lock down future function defaults in the private schema as well.
alter default privileges in schema private revoke execute on functions from public;
commit;
