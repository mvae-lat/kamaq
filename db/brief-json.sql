-- Kamaq — Brief estructurado de campañas.
-- Correr una vez en Supabase → SQL Editor. No depende de nada previo.
--
-- POR QUÉ:
-- El formulario de campaña pasó de un solo campo "brief" a un brief rico que la marca
-- define: objetivo, guión/plan, do's & don'ts, duración, menciones, ejemplos y una guía
-- enlazada. Todo eso se guarda en una sola columna jsonb `brief_json`.
-- La columna vieja `brief` se conserva (guarda el objetivo en texto plano como resumen
-- y como fallback para las campañas creadas antes de esta migración).
--
-- Forma del JSON:
--   { "objetivo": "...", "guion": "...", "duracion": "15–30s", "menciones": "@marca",
--     "dos": ["..."], "donts": ["..."], "refs": ["https://..."], "docUrl": "https://..." }

alter table public.campanas
  add column if not exists brief_json jsonb;

-- ─────────────────────────────────────────────────────────────
-- VERIFICACIÓN
--   select column_name from information_schema.columns
--   where table_schema='public' and table_name='campanas' and column_name='brief_json';
--   -- esperado: 1 fila.
