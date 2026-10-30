-- Drivers retain their existing RLS-scoped SELECT access, but cannot write.
-- Add restrictive guards instead of deleting previous policies, for a narrow rollback.
begin;
do $migration$
declare t text; policy_name text;
begin
 foreach t in array array['profiles','vehicles','routes','fuel_payments','evidences','period_costs','workbook_history'] loop
  foreach policy_name in array array['mr_admin_insert','mr_admin_update','mr_admin_delete'] loop
   if not exists(select 1 from pg_policies where schemaname='public' and tablename=t and policyname=policy_name) then
    if policy_name='mr_admin_insert' then
     execute format('create policy %I on public.%I as restrictive for insert to authenticated with check ((select private.is_admin()))',policy_name,t);
    elsif policy_name='mr_admin_update' then
     execute format('create policy %I on public.%I as restrictive for update to authenticated using ((select private.is_admin())) with check ((select private.is_admin()))',policy_name,t);
    else
     execute format('create policy %I on public.%I as restrictive for delete to authenticated using ((select private.is_admin()))',policy_name,t);
    end if;
   end if;
  end loop;
 end loop;
 if not exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='mr_operations_admin_insert') then
  create policy mr_operations_admin_insert on storage.objects as restrictive for insert to authenticated
   with check(bucket_id <> 'operation-files' or (select private.is_admin()));
 end if;
 if not exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='mr_operations_admin_update') then
  create policy mr_operations_admin_update on storage.objects as restrictive for update to authenticated
   using(bucket_id <> 'operation-files' or (select private.is_admin()))
   with check(bucket_id <> 'operation-files' or (select private.is_admin()));
 end if;
 if not exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='mr_operations_admin_delete') then
  create policy mr_operations_admin_delete on storage.objects as restrictive for delete to authenticated
   using(bucket_id <> 'operation-files' or (select private.is_admin()));
 end if;
end $migration$;

-- A SECURITY DEFINER RPC bypasses table RLS, so it must enforce the role itself.
create or replace function private.set_route_progress(p_route uuid,p_status text,p_km numeric)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v public.routes;
begin
 if auth.uid() is null then raise exception 'Inicia sesión para actualizar la ruta.' using errcode='42501'; end if;
 if not private.is_admin() then raise exception 'La cuenta de chofer es de solo lectura. Solo administración puede modificar rutas.' using errcode='42501'; end if;
 select * into v from public.routes where id=p_route for update;
 if not found then raise exception 'La ruta no existe.'; end if;
 if p_km is null or p_km<0 or p_km>99999999 then raise exception 'Kilometraje inválido.'; end if;
 if p_status='in_progress' and v.status='assigned' then update public.routes set status='in_progress',km_start=p_km where id=p_route;
 elsif p_status='completed' and v.status='in_progress' then
  if p_km<coalesce(v.km_start,0) then raise exception 'El kilometraje final debe ser mayor o igual al inicial.'; end if;
  update public.routes set status='completed',km_end=p_km where id=p_route;
 else raise exception 'El estado de la ruta cambió. Actualiza e intenta otra vez.';
 end if;
end; $$;
revoke all on function private.set_route_progress(uuid,text,numeric) from public;
grant execute on function private.set_route_progress(uuid,text,numeric) to authenticated;
commit;
