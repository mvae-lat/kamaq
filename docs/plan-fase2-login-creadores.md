# Plan Fase 2 — Login de creadores + escala para lanzamiento con ads de Meta

> Estado: BORRADOR para revisión. Nada de esto está implementado todavía.
> Contexto: se van a lanzar campañas en Meta que mandan creadores al landing
> (`kamaq.lat`). Se espera una **acogida fuerte y concentrada en el tiempo**. El
> sistema tiene que (1) registrar a TODOS rápido sin perder gente, (2) dejar que
> los creadores entren por mail a ver su estado, y (3) darle al equipo visibilidad
> operativa del funnel a escala.

---

## 0. TL;DR — las 6 decisiones que definen todo

1. **Desacoplar registro de login.** El registro del landing se queda como está hoy
   (insert público, sin correo, captura UTM) para que un pico de ads NO dependa de
   que el email funcione. El login por mail (magic link) es un paso SEPARADO para
   cuando el creador vuelve a ver su estado / subir clips. → El funnel nunca se
   frena por infra de correo.
2. **Login por ambos:** magic link (principal, sin fricción) **+ email/contraseña**
   (opcional, sesiones persistentes). Misma `auth.users`, no cambia la capa de datos.
3. **SMTP propio (Resend) desde `@kamaq.lat`.** El SMTP por defecto de Supabase es
   inutilizable a volumen (~pocos correos/hora) y cae en spam. Bloqueante para login.
4. **Anti-bot en el registro (Cloudflare Turnstile + Edge Function).** Ads = bots y
   spam. Sin esto, la tabla `creadores` se llena de basura y no se puede "ver el estado".
5. **Panel operativo a escala** (paginación + filtros + funnel por UTM + índices).
   El panel actual carga TODO en una tabla sin paginar; se rompe con miles de filas.
6. **Supabase Pro ($25/mo) antes del lanzamiento.** El plan Free se pausa por
   inactividad y tiene límites bajos; no se arranca una campaña paga sobre Free.

---

## 1. Cómo encaja la arquitectura

Dos "mitades" que hay que conectar:

| Capa | Guarda | La maneja |
|---|---|---|
| `auth.users` (Supabase Auth) | login: email, sesión, confirmación | Supabase |
| `public.creadores` | perfil: nombre, WhatsApp, redes, **estado**, fuente/UTM | Nosotros |
| `public.clips` | clips enviados, vistas, pago, **estado** | Nosotros |

Hoy `creadores` y `clips` se crean **anónimos** (sin relación con `auth.users`). El
corazón del plan es agregar una columna `user_id` que ate "este login" con "este
perfil / estos clips".

### Modelo elegido: **registro anónimo ahora → login por mail después (Modelo B)**

- **Top del funnel (pago por ad):** el creador cae al landing y se registra como hoy
  → un solo `insert` en `creadores`, sin correo, capturando `utm_source`. Rápido,
  sin dependencias, imposible de frenar por email lento. **Captura a todos.**
- **Retorno / dashboard:** cuando el creador quiere ver su estado o subir clips, pide
  magic link con su email → entra → ve SU panel. Un trigger vincula su fila de
  `creadores` (por email) a su `auth.users.id`.

**Por qué NO auth-first (magic link en el registro):** obligar a confirmar email en
el primer paso mete la deliverability de correos en el camino crítico justo cuando
estás pagando por el clic. Un correo lento/en-spam = signup perdido = plata tirada.

---

## 2. Modelo de datos (migraciones)

### 2.1 Vincular perfiles y clips a la identidad

```sql
-- creadores: link opcional a la cuenta de auth (se setea al primer login)
alter table public.creadores
  add column if not exists user_id uuid references auth.users(id) on delete set null;

-- clips: link al creador que lo subió (se setea al enviar estando logueado)
alter table public.clips
  add column if not exists user_id uuid references auth.users(id) on delete set null;
```

### 2.2 Dedupe + email único (anti doble-registro)

Hoy `creadores.email` no es único → un pico de ads genera duplicados (misma persona
recarga y reenvía) y ensucia el "estado". Antes de vincular por email hay que dedupear.

```sql
-- 1) inspeccionar duplicados
select email, count(*) from public.creadores group by email having count(*) > 1;

-- 2) conservar la fila más reciente por email, borrar el resto (revisar antes de correr)
delete from public.creadores a
using public.creadores b
where a.email = b.email and a.ctid < b.ctid;

-- 3) índice único (case-insensitive) para que el registro haga UPSERT, no duplique
create unique index if not exists uq_creadores_email on public.creadores (lower(email));
```

Con eso, el registro pasa a `upsert on conflict (lower(email))` → reenviar el
formulario actualiza la misma fila en vez de crear basura.

### 2.3 Índices para el panel a escala

```sql
create index if not exists idx_creadores_estado  on public.creadores (estado);
create index if not exists idx_creadores_fuente  on public.creadores (fuente);
create index if not exists idx_creadores_created on public.creadores (created_at desc);
create index if not exists idx_clips_estado      on public.clips (estado);
create index if not exists idx_clips_user        on public.clips (user_id);
create index if not exists idx_clips_campana     on public.clips (campana_id);
```

### 2.4 Estados (pipeline explícito)

Definir el ciclo de vida para que "ver el estado" signifique algo concreto:

- **creadores.estado:** `nuevo` → `contactado` → `aprobado` → `activo` → `rechazado`/`pausado`
- **clips.estado:** `revision` → `aprobado` → `pagando` → `pagado` → `rechazado`

(Ajustable, pero conviene fijarlo ahora porque el panel y los filtros se construyen
sobre estos valores. Si `estado` va a ser fijo, agregar un CHECK constraint.)

---

## 3. Login de creadores (magic link)

### 3.1 Trigger que vincula/crea el perfil al autenticarse

Patrón estándar de Supabase (`handle_new_user`). **Debe ser robusto**: corre dentro
de la transacción de signup; si lanza error, el signup falla. Por eso `security
definer`, `search_path=''` y manejo de nulos.

```sql
create or replace function public.handle_nuevo_creador()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- vincular la fila anónima existente (registrada desde el landing) por email
  update public.creadores
     set user_id = new.id
   where lower(email) = lower(new.email) and user_id is null;

  -- si no existía (se registró directo por login), crear una mínima
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
```

> ⚠️ Cuidado: este trigger dispara para CUALQUIER usuario nuevo de `auth.users`,
> incluidos futuros admins. Está bien (les crea/vincula un `creadores`), pero tenerlo
> presente. El admin actual ya existe, no lo afecta.

### 3.2 RLS por creador — **lo más delicado de seguridad**

Se **AGREGAN** políticas a las de admin (son permisivas, combinan con OR). Regla de oro:

- **`creadores`:** el creador puede **LEER** solo su fila. Editar el perfil: solo
  campos no sensibles (ver 3.3). **NUNCA** puede cambiar su `estado` (se auto-aprobaría).
- **`clips`:** el creador puede **LEER** solo sus clips. **NUNCA** puede hacer UPDATE
  de `vistas` ni `estado` — eso equivaldría a **inflarse el pago solo**. El único
  UPDATE de clips sigue siendo admin (`es_admin()`).

```sql
-- creadores: leer lo propio
create policy "creadores_select_propio" on public.creadores
  for select to authenticated
  using (user_id = (select auth.uid()));

-- clips: leer lo propio (NADA de update para el creador)
create policy "clips_select_propio" on public.clips
  for select to authenticated
  using (user_id = (select auth.uid()));
```

El INSERT de clips ya es público; al enviar estando logueado, el cliente setea
`user_id = auth.uid()`. Verificar con un CHECK que un creador no pueda insertar clips
a nombre de otro:

```sql
-- reemplaza el insert público de clips por uno que exige coherencia del user_id
drop policy if exists "clips_insert_publico" on public.clips;
create policy "clips_insert_publico" on public.clips
  for insert to anon, authenticated
  with check (user_id is null or user_id = (select auth.uid()));
```

### 3.3 Impedir que el creador se auto-apruebe (guardia de columnas)

RLS es a nivel de FILA, no de columna. Para que el creador pueda editar su perfil
(nombre, redes) pero NO su `estado`, se pone un trigger que congela columnas sensibles
salvo que sea admin:

```sql
create or replace function public.creadores_guard_cols()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not public.es_admin() then
    new.estado := old.estado;   -- el creador no cambia su estado
    new.fuente := old.fuente;   -- ni su fuente/UTM
  end if;
  return new;
end;$$;

drop trigger if exists trg_creadores_guard on public.creadores;
create trigger trg_creadores_guard before update on public.creadores
  for each row execute function public.creadores_guard_cols();

-- y recién ahí, dar UPDATE acotado al creador sobre su fila
create policy "creadores_update_propio" on public.creadores
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
```

### 3.4 UI en `index.html`

- Vista "Ingresar como creador": input de email → `supabase.auth.signInWithOtp({ email })`.
- Página de retorno maneja la sesión (Supabase setea el token del magic link).
- Dashboard del creador: su estado, sus clips (vistas/pago/estado), botón subir clip.
- Reusar `esc()`/`safeUrl()` en todo lo que se renderice (ya es el patrón del repo).

---

## 4. Escala del registro bajo ads (el camino crítico)

### 4.1 Anti-bot: Cloudflare Turnstile + Edge Function

El registro es un `insert` público directo a Postgres → hoy **no hay forma de frenar
bots**. Con ads, la tabla se llena de spam y "ver el estado real" se vuelve imposible.

**Solución recomendada:** enrutar SOLO la ESCRITURA del registro por una **Supabase
Edge Function** que:
1. valida el token de **Turnstile** (widget invisible en el form),
2. aplica rate-limit por IP,
3. dedupea por email (upsert),
4. recién ahí inserta en `creadores`.

Las LECTURAS (discover de campañas) siguen directas (rápidas, cacheables). Tradeoff:
+~100-200ms en el submit, a cambio de datos limpios. Vale la pena con tráfico pago.

> Alternativa liviana si se quiere lanzar sin Edge Function: Turnstile en el form +
> el índice único de email como red mínima. Acepta algo de spam; se limpia filtrando
> en el panel. Menos robusto.

### 4.2 Rate limits de Auth (para el magic link)

En Authentication → Rate Limits, subir/ajustar los límites de envío de OTP por
email/IP según el volumen esperado, para que ni bots ni un pico legítimo te quemen la
cuota de correos.

### 4.3 Deliverability — SMTP propio (Resend)

- Conectar **Resend** (o SendGrid) como SMTP custom en Authentication → SMTP.
- Configurar **SPF + DKIM** en el DNS de `kamaq.lat` → los magic links llegan a
  inbox, no a spam, y salen desde `@kamaq.lat` (confianza de marca).
- Plantilla del magic link en español, branded.
- Resend free: ~3k correos/mes, 100/día; para más volumen, plan pago barato.

### 4.4 Velocidad para el usuario final

- El landing es estático en el CDN de Vercel → carga rápido en todo LATAM y en celu.
- Mantener `index.html` liviano (ya lo es).
- El registro es un solo round-trip. El magic link agrega latencia de email, pero solo
  para el creador que VUELVE (volumen menor, no time-critical).

---

## 5. Visibilidad operativa a escala (el panel del equipo)

El panel actual hace `select *` de `creadores`/`clips` sin paginar → **inusable con
miles de filas** (justo el escenario del lanzamiento). Cambios:

### 5.1 Paginación + filtros server-side

- Traer de a páginas (`.range()`), no todo.
- Filtros: por `estado`, por `fuente` (qué ad de Meta trae mejor gente), por rango de
  fecha, búsqueda por nombre/WhatsApp. Todos apoyados en los índices de 2.3.

### 5.2 Funnel / tablero (oro para la campaña)

Un RPC `security definer` que chequea `es_admin()` y devuelve conteos agregados:

```sql
create or replace function public.funnel_creadores()
returns table(fuente text, estado text, dia date, total bigint)
language sql stable security definer set search_path = '' as $$
  select fuente, estado, date_trunc('day', created_at)::date, count(*)
  from public.creadores
  where public.es_admin()      -- solo admin ve el agregado
  group by 1,2,3 order by 3 desc;
$$;
revoke execute on function public.funnel_creadores() from public, anon;
grant  execute on function public.funnel_creadores() to authenticated;
```

Con eso el panel muestra: registros por día, por estado, y **por `utm_source`** →
se ve en vivo qué anuncio convierte, para mover presupuesto.

### 5.3 Acciones en lote

Si el volumen lo pide: aprobar/rechazar varios creadores de una, para no revisar de a uno.

---

## 6. Infraestructura y costos

| Componente | Recomendación | Por qué |
|---|---|---|
| **Supabase** | **Pro ($25/mo)** antes del lanzamiento | Free se pausa por inactividad, límites bajos, sin backups diarios. No se lanza tráfico pago sobre Free. |
| **Email** | **Resend** (free → pago según volumen) | SMTP de Supabase no sirve a volumen; deliverability + dominio propio. |
| **Anti-bot** | **Cloudflare Turnstile** (gratis) | Filtra bots de ads sin fricción visible. |
| **Hosting** | **Vercel Hobby** (ya está) | Sitio estático; el CDN aguanta el pico sin problema. |
| **Edge Function** | Supabase (incluida en el plan) | Valida Turnstile + rate-limit + dedupe en el write de registro. |

**Capacidad real (orden de magnitud):** 10.000 registros ≈ pocos MB en Postgres e
inserts que Postgres maneja sin despeinarse. **La base de datos NO es el cuello de
botella.** Los cuellos reales, en orden: (1) deliverability de correos, (2) spam de
bots ensuciando datos, (3) panel sin paginar, (4) límites/pausa del Free. Este plan
ataca los cuatro.

---

## 7. Seguridad (checklist)

- [ ] RLS por creador airtight: leer solo lo propio; **cero** UPDATE de `vistas`/`estado`.
- [ ] Guardia de columnas para que el creador no se auto-apruebe.
- [ ] Verificar que TODO lo renderizado pase por `esc()`/`safeUrl()` (bajo ads sube el
      riesgo de XSS almacenado vía inserts públicos). Reauditar los paths del panel.
- [ ] PII (emails/WhatsApps): confirmar que ningún creador pueda leer filas ajenas.
- [ ] Redirect/Site URL en Auth apuntando a `kamaq.lat` (si no, el magic link no vuelve).
- [ ] Rate limits de Auth configurados.
- [ ] Turnstile validado **server-side** (no confiar solo en el widget).

---

## 8. Orden de ejecución (con dependencias)

**Fase A — Fundaciones (antes de tocar login):**
1. Anexar dominio `kamaq.lat` → apex + www en Vercel.
2. Subir Supabase a **Pro**.
3. Migraciones DB: `user_id` en creadores/clips, dedupe + email único, índices, estados.

**Fase B — Anti-abuso del registro (para aguantar los ads):**
4. Edge Function de registro + Cloudflare Turnstile + rate-limit.
5. Reemplazar el insert directo del landing por la llamada a la Edge Function.

**Fase C — Correo + login:**
6. Resend como SMTP + SPF/DKIM en el DNS + plantilla del magic link.
7. Redirect/Site URLs en Auth.
8. Trigger `handle_nuevo_creador` + políticas RLS por creador + guardia de columnas.
9. UI: "Ingresar como creador" (magic link) + dashboard del creador en `index.html`.

**Fase D — Operación a escala:**
10. Panel: paginación + filtros + `funnel_creadores()` + (opcional) acciones en lote.

**Fase E — Pre-lanzamiento:**
11. Prueba de carga del funnel completo (registro→estado) con datos sintéticos.
12. Verificar deliverability real (mandar magic links a Gmail/Outlook, ver inbox).
13. Tablero de UTM funcionando antes de encender el primer ad.

---

## 9. Revisión crítica — riesgos y mitigaciones

| # | Riesgo | Impacto en el lanzamiento | Mitigación |
|---|---|---|---|
| R1 | SMTP de Supabase por defecto (~pocos/hora) | Los magic links no llegan → login muerto | SMTP propio (Resend) + SPF/DKIM. **Bloqueante.** |
| R2 | Sin anti-bot en registro público | `creadores` se llena de spam de ads → no se ve el estado real | Turnstile + Edge Function con validación server-side |
| R3 | Panel carga todo sin paginar | Se cuelga con miles de filas justo en el pico | Paginación + filtros + índices |
| R4 | Supabase Free se pausa / límites bajos | Caída o throttle durante tráfico pago | Pro antes del lanzamiento |
| R5 | Creador puede hacer UPDATE de `vistas`/`estado` | **Se infla el pago solo** (fraude) | RLS: cero update de clips para creador; guardia de columnas en creadores |
| R6 | Duplicados de registro (recarga/reenvío) | Datos sucios, doble contacto | Email único + upsert |
| R7 | Trigger de signup lanza error | **Signups fallan silenciosamente** | Trigger robusto (security definer, nulos, `on conflict`) + probarlo |
| R8 | Redirect URL mal configurada | El magic link no vuelve a la app | Configurar Site/redirect URLs a `kamaq.lat` |
| R9 | `og:image` interino apunta a Vercel | Preview del ad/landing sin imagen tras anexar dominio | Revertir a `kamaq.lat/og.png` al anexar (ya anotado) |
| R10 | Sin observabilidad de errores | Si el registro falla en el pico, no te enterás | Logs de Supabase + toast de error + revisar métricas en vivo el día del lanzamiento |
| R11 | Pagos aún manuales | A volumen, el pago Yape/Plin manual se vuelve el cuello operativo | Fuera de este alcance, pero planificar antes de escalar mucho |

---

## 10. Decisiones

- ✅ **Login:** ambos — magic link + email/contraseña. *(decidido 2026-07-16)*
- ✅ **Anti-bot:** robusto — Edge Function + Turnstile con validación server-side. *(decidido)*

Pendientes de definir (no bloquean el arranque de la capa de datos):
3. **Volumen esperado:** presupuesto/estimado de clics del primer flight de Meta (para
   dimensionar cuota de correos y tier).
4. **Estados:** confirmar el pipeline propuesto de `creadores`/`clips` (por ahora se
   implementa sin CHECK constraint para no romper datos existentes).
5. **Dashboard del creador v1:** ¿solo "ver estado + mis clips", o también editar perfil?
