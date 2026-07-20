-- Kamaq — Auditoría de pagos en clips.
-- Correr una vez en Supabase → SQL Editor. No depende de nada previo.
--
-- POR QUÉ:
-- El panel opera el desembolso moviendo el clip a estado 'pagado'. Para tener
-- rastro de CUÁNDO se pagó (y opcionalmente el código de operación Yape/Plin),
-- se agregan dos columnas de auditoría. El frontend ya funciona sin ellas
-- (marca 'pagado' igual), pero con estas columnas queda el registro del pago.
--
-- Nota: `clips.estado` NO tiene CHECK constraint, así que 'aprobado'/'pagando'/
-- 'pagado'/'rechazado'/'revision' son todos válidos sin tocar el esquema.

alter table public.clips
  add column if not exists pagado_at timestamptz,
  add column if not exists pago_ref  text;

-- Índice para filtrar/reportar pagos por fecha (cierre de caja, etc.).
create index if not exists idx_clips_pagado_at on public.clips (pagado_at desc);

-- ─────────────────────────────────────────────────────────────
-- VERIFICACIÓN
--   select column_name from information_schema.columns
--   where table_schema='public' and table_name='clips'
--     and column_name in ('pagado_at','pago_ref');
--   -- esperado: 2 filas.
--
-- Reporte rápido de pagos ya registrados:
--   select date_trunc('day', pagado_at)::date dia, count(*) clips,
--          sum(vistas/1000.0 * (select tarifa_1k from public.campanas c where c.id=clips.campana_id)) soles
--   from public.clips where estado='pagado' and pagado_at is not null group by 1 order by 1 desc;
