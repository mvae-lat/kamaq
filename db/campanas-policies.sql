-- Kamaq — separación de rol admin + permisos de escritura sobre campañas.
-- Correr una vez en Supabase → SQL Editor.
--
-- POR QUÉ ESTE ARCHIVO CAMBIÓ (importante):
-- La primera versión usaba `for insert/update to authenticated with check (true)`.
-- Eso funciona hoy, pero SOLO porque `authenticated` significa "el equipo interno".
-- El día que exista login de creadores (magic link, Fase 2), cada creador heredaría
-- ese permiso y podría editar CUALQUIER campaña. Un permiso atado al rol genérico
-- `authenticated` es una bomba de tiempo que estalla el día que abres el registro.
-- Esta versión ata la escritura a una tabla explícita de administradores.

-- PRERREQUISITO: crear el usuario admin en Authentication → Users → Add user.
-- Luego cambia el email en el paso 3.

-- ─────────────────────────────────────────────────────────────
-- 1) Tabla de admins. Cero políticas a propósito: solo la service key la escribe,
--    así un admin no puede auto-promoverse ni promover a nadie desde el frontend.
create table if not exists public.usuarios_admin (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  email     text not null,
  rol       text not null default 'admin' check (rol in ('admin','operador')),
  creado_at timestamptz not null default now()
);
alter table public.usuarios_admin enable row level security;

-- ─────────────────────────────────────────────────────────────
-- 2) Chequeo reusable. security definer para que pueda leer usuarios_admin
--    aunque la tabla no tenga políticas.
create or replace function public.es_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.usuarios_admin where user_id = (select auth.uid()));
$$;
revoke execute on function public.es_admin() from public, anon;
grant  execute on function public.es_admin() to authenticated;

-- ─────────────────────────────────────────────────────────────
-- 3) Dar de alta al admin.
--    Debe coincidir EXACTO con el email del usuario que creaste en
--    Authentication → Users → Add user. Si usaste otro, cámbialo aquí.
insert into public.usuarios_admin (user_id, email)
select id, email from auth.users where email = 'marlon@mvae.lat'
on conflict (user_id) do nothing;

-- Si el insert de arriba no agregó ninguna fila, el email no coincide.
-- Para ver qué usuarios existen de verdad:
--   select id, email from auth.users;

-- ─────────────────────────────────────────────────────────────
-- 4) Políticas de campanas.
--    El SELECT público del discover ya existe y NO se toca: las políticas son
--    permisivas y se combinan con OR.
--    El (select ...) alrededor de es_admin() no es cosmético: hace que el planner
--    lo evalúe una vez por query y no una vez por fila.
alter table public.campanas enable row level security;

drop policy if exists "campanas_insert_authenticated" on public.campanas;
drop policy if exists "campanas_update_authenticated" on public.campanas;
drop policy if exists "campanas_admin_write"          on public.campanas;

create policy "campanas_admin_write" on public.campanas
  for all to authenticated
  using       ((select public.es_admin()))
  with check  ((select public.es_admin()));

-- No hay política de DELETE: el panel pausa campañas en vez de borrarlas,
-- para no perder el historial de clips asociados.

-- ─────────────────────────────────────────────────────────────
-- VERIFICACIÓN
--   select public.es_admin();   -- true con tu sesión de admin, false con cualquier otra
--   select policyname, cmd, roles from pg_policies where tablename = 'campanas';

-- ─────────────────────────────────────────────────────────────
-- PENDIENTE Y BLOQUEANTE ANTES DE ENCENDER EL LOGIN DE CREADORES
-- `creadores` y `clips` TODAVÍA tienen políticas atadas a `authenticated`
-- (SELECT/UPDATE), heredadas del esquema original. Con el login de creadores
-- encendido, cada creador podría leer la tabla completa de creadores —
-- emails y WhatsApps de todos — y editar clips ajenos.
-- Este archivo NO las toca porque hay que ver sus nombres reales primero:
--
--   select policyname, cmd, roles, qual from pg_policies
--   where tablename in ('creadores','clips');
--
-- Cada una de esas políticas debe pasar a `using ((select public.es_admin()))`
-- ANTES de que exista el primer creador con sesión. Es la migración M01 del plan.
