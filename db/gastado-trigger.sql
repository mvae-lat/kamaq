-- Kamaq — mantener `campanas.gastado` sincronizado en Postgres.
-- Correr una vez en Supabase → SQL Editor.
--
-- HOY el gasto real se deriva en el cliente (gastadoPorCampana() en index.html):
-- suma de clips en estado 'aprobado'/'pagando', vistas/1000 * tarifa_1k. La columna
-- `campanas.gastado` traía datos de siembra y no reflejaba eso. Este trigger la
-- vuelve confiable: cada cambio en `clips` recalcula el gastado de su campaña.
--
-- El cliente puede seguir derivando el número (es un fallback inofensivo), pero a
-- partir de aquí la columna `gastado` también es correcta y ya se puede consultar
-- directo, ordenar/filtrar por ella, o usarla en reportes sin recomputar.

-- ─────────────────────────────────────────────────────────────
-- 1) Función de trigger. security definer para poder escribir `campanas`
--    aunque la sesión que movió el clip no tenga permiso de UPDATE sobre campañas.
--    Recalcula tanto la campaña nueva como la vieja: cubre el caso raro en que un
--    clip cambie de `campana_id`, y el DELETE (donde solo hay OLD).
create or replace function public.trg_recompute_gastado()
returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.campanas c
  set gastado = coalesce((
        select sum(cl.vistas)::numeric / 1000 * c.tarifa_1k
        from public.clips cl
        where cl.campana_id = c.id
          and cl.estado in ('aprobado','pagando')
      ), 0)
  where c.id in (
    coalesce(new.campana_id, old.campana_id),
    coalesce(old.campana_id, new.campana_id)
  );
  return null; -- AFTER trigger: el valor de retorno se ignora.
end;$$;

-- ─────────────────────────────────────────────────────────────
-- 2) Trigger. Cubre insertar un clip, editar sus vistas, aprobarlo/rechazarlo
--    (cambio de estado) y borrarlo.
drop trigger if exists clips_recompute_gastado on public.clips;
create trigger clips_recompute_gastado
  after insert or update or delete on public.clips
  for each row execute function public.trg_recompute_gastado();

-- ─────────────────────────────────────────────────────────────
-- 3) Backfill: sincronizar de una vez todas las campañas con lo que ya hay en clips.
--    Deja en 0 las campañas sin clips aprobados/pagando (borra el dato de siembra).
update public.campanas c
set gastado = coalesce((
      select sum(cl.vistas)::numeric / 1000 * c.tarifa_1k
      from public.clips cl
      where cl.campana_id = c.id
        and cl.estado in ('aprobado','pagando')
    ), 0);

-- ─────────────────────────────────────────────────────────────
-- VERIFICACIÓN
--   select id, titulo, gastado, presupuesto from public.campanas order by created_at;
-- Debe coincidir con lo que muestra la columna Gastado del panel (gastadoPorCampana()).
