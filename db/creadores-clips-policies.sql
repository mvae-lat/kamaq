-- Kamaq — Migración M01: atar la lectura/escritura de `creadores` y `clips`
-- al rol admin real (es_admin()), no al rol genérico `authenticated`.
-- Correr una vez en Supabase → SQL Editor.
--
-- PRERREQUISITO: haber corrido antes `db/campanas-policies.sql`, que crea la
-- tabla `usuarios_admin` y la función `public.es_admin()`. Sin ella, este archivo
-- falla en el `create policy` porque referencia una función inexistente.
--
-- POR QUÉ ES BLOQUEANTE ANTES DEL LOGIN DE CREADORES:
-- `creadores` y `clips` heredaron del esquema original políticas SELECT/UPDATE
-- atadas a `authenticated`. Hoy no importa porque el único usuario de Auth es el
-- admin. El día que se encienda el login de creadores (magic link, Fase 2), cada
-- creador con sesión heredaría ese `authenticated` y podría leer la tabla completa
-- de `creadores` (emails y WhatsApps de TODOS) y editar clips ajenos.
-- Las políticas RLS son permisivas y se combinan con OR: una sola política vieja
-- atada a `authenticated` que sobreviva basta para filtrar los datos. Por eso este
-- script BORRA todas las políticas existentes de ambas tablas y las recrea limpias.

-- ─────────────────────────────────────────────────────────────
-- 0) Guarda: no continuar si `es_admin()` no existe todavía.
do $$
begin
  if to_regprocedure('public.es_admin()') is null then
    raise exception 'Falta public.es_admin(). Corre db/campanas-policies.sql primero.';
  end if;
end$$;

-- ─────────────────────────────────────────────────────────────
-- 1) Borrar TODAS las políticas actuales de `creadores` y `clips`.
--    Se hace por loop porque los nombres originales del esquema no están
--    documentados y cualquier sobrante permisivo reabre la fuga.
do $$
declare p record;
begin
  for p in
    select policyname, tablename from pg_policies
    where schemaname = 'public' and tablename in ('creadores','clips')
  loop
    execute format('drop policy if exists %I on public.%I', p.policyname, p.tablename);
  end loop;
end$$;

alter table public.creadores enable row level security;
alter table public.clips     enable row level security;

-- ─────────────────────────────────────────────────────────────
-- 2) `creadores`
--    - INSERT público: el registro desde la landing lo hace el rol anónimo.
--      No hay USING; el INSERT solo evalúa WITH CHECK.
--    - SELECT/UPDATE: solo admin. El público NO puede leer de vuelta la fila que
--      insertó — por eso el frontend inserta con return=minimal (sin .select()).
create policy "creadores_insert_publico" on public.creadores
  for insert to anon, authenticated
  with check (true);

create policy "creadores_select_admin" on public.creadores
  for select to authenticated
  using ((select public.es_admin()));

create policy "creadores_update_admin" on public.creadores
  for update to authenticated
  using      ((select public.es_admin()))
  with check ((select public.es_admin()));

-- ─────────────────────────────────────────────────────────────
-- 3) `clips`
--    Mismo patrón: enviar clip es público, revisarlo/editarlo es solo admin.
create policy "clips_insert_publico" on public.clips
  for insert to anon, authenticated
  with check (true);

create policy "clips_select_admin" on public.clips
  for select to authenticated
  using ((select public.es_admin()));

create policy "clips_update_admin" on public.clips
  for update to authenticated
  using      ((select public.es_admin()))
  with check ((select public.es_admin()));

-- No hay políticas de DELETE a propósito: creadores y clips no se borran desde
-- el frontend; se cambia su `estado`. Así el admin tampoco borra por accidente.

-- ─────────────────────────────────────────────────────────────
-- CUANDO LLEGUE EL LOGIN DE CREADORES (Fase 2), este archivo se AMPLÍA, no se
-- revierte: hay que agregar una política extra que deje a cada creador ver/editar
-- SOLO sus propias filas, p.ej.:
--   create policy "clips_select_propio" on public.clips
--     for select to authenticated using (creador_id = (select auth.uid()));
-- Eso requiere una columna `creador_id uuid` en clips/creadores ligada a auth.uid(),
-- que hoy no existe. Mientras no exista, admin es el único lector: correcto y seguro.

-- ─────────────────────────────────────────────────────────────
-- VERIFICACIÓN
--   select policyname, cmd, roles, qual, with_check
--   from pg_policies where tablename in ('creadores','clips') order by tablename, cmd;
-- Esperado: INSERT (anon,authenticated) con with_check=true; SELECT/UPDATE
-- (authenticated) con es_admin() en qual/with_check. NINGUNA política sin es_admin()
-- sobre SELECT/UPDATE.
