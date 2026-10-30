# Backend de empleados: contrato para la interfaz

Este bloque no modifica `auth.js`, `access.mjs` ni el PR #1.

## Estado al 29 de octubre de 2026

Migración aplicada en Supabase. Se conservaron las tres cuentas existentes y sus roles. Proveedor Email deshabilitado; Google y las altas globales permanecen habilitados. Hook Before User Created activado con `public.hook_employee_signup`. Pasaron 31 comprobaciones del bloque y las 26 pruebas anteriores de choferes de solo lectura, todas con rollback. No se fusionó el PR de interfaz ni se activó limpieza de archivos.

## Flujo

1. Un administrador autoriza un correo con `admin_set_employee_access`.
2. El empleado usa Continuar con Google con ese mismo correo.
3. El trigger vincula el UUID de Auth y crea el perfil con el rol autorizado. `user_metadata.role` no otorga privilegios.
4. Si el correo no está autorizado, está desactivado o usa el proveedor Email, el alta se rechaza. El trigger es la barrera obligatoria; el hook previo mejora el mensaje de rechazo.

Las cuentas existentes conservan sus roles. Los choferes siguen en solo lectura. Un empleado desactivado pierde las consultas y escrituras en la siguiente petición a la base, aunque conserve un JWT aún válido. Los archivos ya descargados no se pueden retirar y una URL firmada anterior sigue viva hasta su vencimiento (el portal actual usa 120 segundos).

## RPC

Usar el cliente Supabase con la sesión del usuario. Nunca incluir `service_role` en el navegador.

| Función | Parámetros | Uso |
| --- | --- | --- |
| `my_employee_access` | ninguno | Devuelve `{active, role}` para la propia sesión, incluso si está desactivada. |
| `admin_list_employee_access` | ninguno | Lista administrativa: email, user_id, full_name, role, active, updated_at. |
| `admin_set_employee_access` | `p_email`, `p_active`, `p_role` (`driver` o `admin`; por defecto `driver`) | Autorizar, desactivar, reactivar o cambiar rol. Solo administrador activo. No envía correo ni crea una contraseña. |
| `admin_employee_access_audit` | `p_limit` (por defecto 50, máximo 200) | Bitácora del control de acceso. Solo administrador activo. |

No escribir directamente `profiles.role`; la base lo rechaza si no coincide con la autorización privada. No ofrecer borrado de perfiles: usar desactivar. No se permite desactivar o degradar al último administrador activo. Las mutaciones se serializan para que dos administradores no eludan esa condición simultáneamente.

## Integración que corresponde al desarrollador de interfaz

- Llamar `my_employee_access` al abrir la sesión y al refrescar. Si `active=false`, vaciar las vistas en memoria y mostrar Acceso desactivado. No dejar visible información antigua como si siguiera autorizada.
- Crear un módulo exclusivo de administración para listar/autorizar/desactivar empleados y consultar la bitácora.
- No mostrar los botones de cambio de rol a choferes. La base también bloquea las llamadas manipuladas.
- Manejar errores 42501 (sin permiso), 23514 (último administrador) y 22023 (entrada inválida).
- Evitar reintentos automáticos de cambios de rol; refrescar la lista tras cada operación.
- Validar integración con las cuentas reales antes de fusionar.

## Configuración y mantenimiento

Global Allow new users to sign up debe permanecer habilitado para que un empleado autorizado pueda entrar por primera vez con Google. La autorización se controla en la base, no por ese interruptor. El proveedor Email se deshabilita por separado. Google OAuth en estado Prueba limita adicionalmente las cuentas que Google deja entrar: autorizar un correo en la base no lo agrega a los usuarios de prueba de Google.

La autorización está en `private.employee_access` y la bitácora en `private.employee_access_audit`, con RLS activado y sin acceso directo para `anon`/`authenticated`. Los correos no se publican en GitHub. La asignación inicial usa los roles existentes, nunca un correo administrador codificado.

No cambiar correos de empleados mediante Auth sin planificar la reasignación: la identidad queda asociada a su correo autorizado y un cambio de correo cierra el acceso hasta revisión del responsable de base de datos.

La migración se ejecuta como una sola transacción. Si falla, se revierte. Para recuperación posterior, el propietario de Supabase puede revisar/corregir la autorización privada; no se debe volver a abrir el registro general ni restaurar el antiguo privilegio por correo como solución rápida.

## Fuera de este bloque

No se activa limpieza v2 ni se modifica Storage DELETE. Respaldos operativos, liquidaciones y auditoría financiera completa requieren cambios separados. Esta bitácora cubre solamente autorizaciones y roles.
