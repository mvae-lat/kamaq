-- Kamaq — Fase 2: fundación de datos para login de creadores + escala.
-- Correr una vez en el SQL Editor. Depende de campanas-policies.sql (es_admin()).
--
-- Notas del esquema real (verificado 2026-07-16):
--  - IDs son uuid. `clips.creador_id` YA existe y es FK → creadores.id (se reusa).
--  - creadores.nombre y creadores.email son NOT NULL sin default → el trigger los provee.
--  - No había duplicados ni emails vacíos → el índice único es seguro.

-- 0) Guarda: es_admin() debe existir.
do $$
begin
  if to_regprocedure('public.es_admin()') is null then
    raise exception 'Falta public.es_admin(). Corre db/campanas-policies.sql primero.';
  end if;
end$$;

-- 1) Vincular creadores a auth.users (se setea al primer login).
alter table public.creadores
  add column if not exists user_id uuid references auth.users(id) on delete set null;

-- 2) Índices para el panel a escala + los links.
create index if not exists idx_creadores_estado  on public.creadores (estado);
create index if not exists idx_creadores_fuente  on public.creadores (fuente);
create index if not exists idx_creadores_created on public.creadores (created_at desc);
create index if not exists idx_creadores_user    on public.creadores (user_id);
create index if not exists idx_clips_estado      on public.clips (estado);
create index if not exists idx_clips_creador     on public.clips (creador_id);
create index if not exists idx_clips_campana     on public.clips (campana_id);

-- 3) Email único (case-insensitive) → habilita UPSERT y frena doble-registro.
create unique index if not exists uq_creadores_email on public.creadores (lower(email));

-- 4) Trigger: al crear cuenta de auth, vincular por email o crear perfil mínimo.
--    security definer + provee NOT NULLs → nunca hace fallar un signup.
create or replace function public.handle_nuevo_creador()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.creadores
     set user_id = new.id
   where lower(email) = lower(new.email) and user_id is null;
  if not found then
    insert into public.creadores (user_id, email, nombre, estado, fuente)
    values (new.id, new.email,
            coalesce(new.raw_user_meta_data->>'nombre',''), 'nuevo', 'login')
    on conflict (lower(email)) do update set user_id = excluded.user_id;
  end if;
  return new;
end;$$;

drop trigger if exists on_auth_creador on auth.users;
create trigger on_auth_creador
  after insert on auth.users
  for each row execute function public.handle_nuevo_creador();

-- 5) Guardia de columnas: un creador autenticado NO puede cambiar estado/fuente/user_id
--    (anti auto-aprobación). Admin y contexto service/postgres pasan libres.
create or replace function public.creadores_guard_cols()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is not null and not public.es_admin() then
    new.estado  := old.estado;
    new.fuente  := old.fuente;
    new.user_id := old.user_id;
  end if;
  return new;
end;$$;

drop trigger if exists trg_creadores_guard on public.creadores;
create trigger trg_creadores_guard before update on public.creadores
  for each row execute function public.creadores_guard_cols();

-- 6) RLS por creador (se AGREGA a las políticas de admin; combinan con OR).
-- creadores: leer/editar (acotado por la guardia) solo lo propio.
drop policy if exists "creadores_select_propio" on public.creadores;
create policy "creadores_select_propio" on public.creadores
  for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "creadores_update_propio" on public.creadores;
create policy "creadores_update_propio" on public.creadores
  for update to authenticated
  using      (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- clips: leer solo los propios (via creador_id). NADA de update para el creador
--        (si no, se inflaría vistas/pago solo). El update de clips sigue siendo admin.
drop policy if exists "clips_select_propio" on public.clips;
create policy "clips_select_propio" on public.clips
  for select to authenticated
  using (creador_id in (select id from public.creadores where user_id = (select auth.uid())));

-- clips insert: público, pero no se puede insertar a nombre de otro creador.
drop policy if exists "clips_insert_publico" on public.clips;
create policy "clips_insert_publico" on public.clips
  for insert to anon, authenticated
  with check (creador_id is null
              or creador_id in (select id from public.creadores where user_id = (select auth.uid())));

-- 7) Funnel operativo (solo admin): conteos por fuente/estado/día para medir los ads.
create or replace function public.funnel_creadores()
returns table(fuente text, estado text, dia date, total bigint)
language sql stable security definer set search_path = '' as $$
  select coalesce(fuente,'(directo)'), estado, date_trunc('day', created_at)::date, count(*)
  from public.creadores
  where public.es_admin()
  group by 1,2,3 order by 3 desc, 4 desc;
$$;
revoke execute on function public.funnel_creadores() from public, anon;
grant  execute on function public.funnel_creadores() to authenticated;

-- ─────────────────────────────────────────────────────────────
-- VERIFICACIÓN
--   select policyname, cmd, roles from pg_policies where tablename in ('creadores','clips') order by tablename, cmd;
--   select tgname from pg_trigger where tgrelid in ('public.creadores'::regclass, 'auth.users'::regclass);
--   select indexname from pg_indexes where tablename in ('creadores','clips');
