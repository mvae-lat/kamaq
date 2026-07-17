# Contexto para Claude Code — Proyecto Kamaq

## Qué es
Plataforma UGC (estilo Content Rewards / SideShift) para Perú, escalando a LATAM. Las marcas publican campañas; los creadores se registran, postean clips desde sus propias redes y cobran por vistas verificadas (Yape/Plin). Marcas iniciales: Vialex y Royal Home. Uso interno primero; visión: abrir a otras marcas.

## Arquitectura actual (Fase 1)
- `index.html`: app completa de una sola página (SPA en JS vanilla). Todo el CSS y JS están inline. Se eligió un solo archivo por velocidad de validación; se puede migrar a un framework más adelante.
- `supabase-js` v2 cargado por CDN. Cliente creado con la URL del proyecto + publishable key.
- Supabase: Postgres con RLS + Auth (para el panel interno).
- Vercel: hosting estático. La "Deployment Protection" (Vercel Authentication) está DESACTIVADA para que el sitio sea público.

## Credenciales (públicas, seguras para el frontend)
- SUPABASE_URL: `https://glyjniopfjwvmfosvlsn.supabase.co`
- SUPABASE_PUBLISHABLE_KEY: `sb_publishable_fIRJ5hQTdNe2t_j1QVqdCg_hyGQSJFu`
- La *secret key* NO está en el repo; se maneja solo dentro de Supabase.
- Están hardcodeadas en `index.html` (constantes SB_URL y SB_KEY). Para producción seria conviene moverlas a variables de entorno.

## Base de datos
Tablas: `creadores`, `campanas`, `clips`.

NO existe un `db/schema.sql` — el esquema vive solo en Supabase. En `db/` hay
migraciones sueltas que se corren a mano en el SQL Editor.

Columnas de `campanas` (verificadas contra la API):
`id`, `marca`, `categoria`, `titulo`, `plataforma`, `tarifa_1k`, `presupuesto`,
`gastado`, `brief`, `hashtag`, `estado`, `created_at`.

Reglas RLS clave:
- `creadores`: INSERT público (registro desde la landing), SELECT/UPDATE solo `authenticated`.
- `campanas`: SELECT público (para el discover) + escritura solo para admins
  (ver `db/campanas-policies.sql` — hay que correrlo una vez).
- `clips`: INSERT público (enviar clip), SELECT/UPDATE solo `authenticated`.

### GOTCHA: `authenticated` NO es sinónimo de "el equipo"
Hoy lo parece, porque el único usuario de Auth es el admin. Pero cualquier permiso
escrito como `to authenticated ... with check (true)` se lo hereda **cada creador**
el día que se encienda el login de creadores. Por eso la escritura de campañas está
atada a la tabla `usuarios_admin` vía la función `es_admin()`, no al rol genérico.

`creadores` y `clips` YA fueron migrados a `es_admin()` (M01, corrido el 2026-07-16;
ver `db/creadores-clips-policies.sql`): hoy SELECT/UPDATE de ambas tablas solo lo
puede el admin. Cuando se encienda el login de creadores habrá que AGREGAR una
política extra `using (creador_id = auth.uid())` para que cada creador vea lo suyo
(requiere una columna `creador_id` que aún no existe) — ampliar, no revertir.

### GOTCHA: escapar todo lo que venga de la DB
El HTML se arma con template literals e `innerHTML`, y `creadores`/`clips` tienen
INSERT **público**: cualquier anónimo escribe esas filas y el panel las renderiza en
la sesión del admin. Pasar SIEMPRE por `esc()` al interpolar — no es cosmético, es
la única barrera contra XSS almacenado. Sin eso, un `nombre` con `<img onerror>`
corre con los permisos del admin, que lee la tabla entera de creadores.

Las URLs necesitan `safeUrl()` además de `esc()`: solo deja pasar https de
tiktok.com/instagram.com. `esc()` no detiene un `javascript:` dentro de un `href`.

### Gasto por campaña
La columna `campanas.gastado` tiene datos de siembra y **no se usa en la UI**. El
panel deriva el gasto real sumando los clips en estado `aprobado`/`pagando`
(`vistas/1000 * tarifa_1k`) en `gastadoPorCampana()`. Por eso una campaña puede
mostrar S/ 0.00 aunque su columna `gastado` diga otra cosa: el número derivado es
el correcto. El arreglo de fondo ya está escrito en `db/gastado-trigger.sql`
(trigger sobre `clips` + backfill): una vez corrido, la columna `gastado` queda
sincronizada y sí es confiable. Mientras NO se haya corrido, no confiar en `gastado`
y seguir usando el número derivado del cliente.

### GOTCHA importante
Los INSERT públicos deben usar `return=minimal`, es decir `supabase.from('...').insert(obj)` SIN encadenar `.select()`. Como el público NO tiene permiso de SELECT sobre `creadores`/`clips`, pedir la fila de vuelta provoca error de RLS (42501). Ya está resuelto así en el código.

## Flujos implementados en index.html
- Registro de creador (3 pasos con validación) -> insert en `creadores` con estado `nuevo` y `fuente` (captura utm_source de la URL para medir de qué ad vino).
- Discover: lee `campanas` activas.
- Detalle de campaña + enviar clip -> insert en `clips`.
- Panel de marca (login por Supabase Auth):
  - Creadores: aprobar / rechazar.
  - Clips + Vistas: editar vistas (recalcula el pago = vistas/1000 * tarifa_1k), aprobar / rechazar.
  - Campañas: listado + crear (formulario inline) + editar + pausar/activar, y
    columna Gastado/Presupuesto derivada de los clips. Pausar saca la campaña del
    discover porque `loadCamps()` filtra por `estado='activa'`.
    La validación reusa el helper `showErr()`, que mapea el id del error al del
    input con `replace('e_','r_')` — por eso los campos del formulario se llaman
    `r_nc*` y sus errores `e_nc*`. Respetar ese par al agregar campos.

## Pendiente (Fase 2 y siguientes)

### Setup de Supabase — HECHO y verificado (2026-07-16)
Todo corrido en el SQL Editor con la sesión del proyecto. Estado final verificado:
- [x] **Usuario admin creado** (`marlon@mvae.lat`, provider Email) en Authentication.
- [x] **`db/campanas-policies.sql` corrido.** `usuarios_admin` + `es_admin()` creados,
  admin dado de alta (`usuarios_admin` = 1 fila).
- [x] **`db/creadores-clips-policies.sql` (M01) corrido.** `creadores` y `clips`
  quedaron con 3 políticas c/u: INSERT público + SELECT/UPDATE atados a `es_admin()`.
- [x] **`db/gastado-trigger.sql` corrido.** Trigger `clips_recompute_gastado` activo +
  backfill hecho. La columna `campanas.gastado` ya es confiable.
- [x] **BUG DE SEGURIDAD encontrado y corregido:** `campanas` tenía una política vieja
  del esquema original llamada **`equipo gestiona campanas`** (ALL, `authenticated`,
  `using true`) que dejaba escribir campañas a cualquier autenticado — la bomba de
  tiempo descrita arriba, ya viva. Se borró. `campanas` quedó con 2 políticas:
  `campanas_admin_write` (es_admin) + `ver campanas` (SELECT anon, discover). El
  `drop` ya está agregado a `db/campanas-policies.sql` para futuras corridas limpias.
- [x] **`campanas.estado` NO tiene CHECK constraint** → `'pausada'` es válido, el botón
  Pausar funciona. (Único estado en uso hoy: `activa`.)
- [x] **Filas de prueba QA limpiadas** (`fuente qa-kamaq`/`test-api` + clip QA).

### Resuelto en código (working tree)
- [x] CRUD de campañas en el panel (crear/editar/pausar/activar + columna Gastado).
- [x] Saneo del `href` de clips con `safeUrl()` (ya no pasa `javascript:`; solo https de TikTok/Instagram).
- [x] Open Graph + `og.png` para preview al compartir el link.

### Fase 2 — Login de creadores (en progreso)
Plan completo en `docs/plan-fase2-login-creadores.md`. Decidido: login por **ambos**
(magic link + contraseña) y anti-bot **robusto** (Edge Function + Turnstile).
- [x] **Capa de datos corrida** (`db/fase2-login-creadores.sql`, 2026-07-16):
  `creadores.user_id` → auth.users; índices (estado/fuente/created/user + clips);
  email único; trigger `on_auth_creador` (vincula/crea perfil al signup); guardia de
  columnas (creador no cambia su estado → anti auto-aprobación); RLS por creador
  (lee/edita lo propio; **clips: solo lectura, sin UPDATE = anti-fraude**);
  RPC `funnel_creadores()` para métricas por UTM. `clips.creador_id` ya existía (FK a creadores.id).
- [ ] Edge Function de registro + Turnstile (necesita keys de Cloudflare).
- [ ] Resend como SMTP + SPF/DKIM en DNS de kamaq.lat (necesita cuenta Resend + dominio).
- [ ] Supabase Pro antes del lanzamiento (billing).
- [ ] Auth config: habilitar password + magic link, redirect/Site URLs (agregar la
  URL del deploy + kamaq.lat), y "Confirm email" según se decida. **Bloquea el login
  por email en el sitio en vivo.**
- [x] **Código: login de creador (magic link + password) + dashboard** (balance hero,
  stat-cards, mis clips, editar perfil) + wire clip→creador_id + panel de marca
  rechaza no-admins. Probado local (sin errores, dashboard renderiza). Desplegado a
  PREVIEW (no a prod): el login por email necesita la Auth config de arriba primero.
- [x] **Panel de marca a escala** (probado local): tab "Resumen" con funnel por UTM
  (`funnel_creadores()`) + stat-cards; Creadores con filtro por estado/búsqueda +
  paginación server-side; Clips con filtro + paginación. En el mismo preview.
- [ ] Edge Function anti-bot en el registro (necesita keys de Turnstile).

### Dominio kamaq.lat — ANEXADO Y VIVO (2026-07-17)
- [x] `kamaq.lat` (apex) + `www.kamaq.lat` anexados en Vercel, DNS en Namecheap
  (A `@` → 216.198.79.1), estado **Valid** + SSL. **Canónico = `www.kamaq.lat`**
  (el apex hace 308 → www, preservando el path/UTM).
- [x] `og:image`/`twitter:image`/canonical/og:url apuntando a `https://www.kamaq.lat/`.
- [x] **Producción despliega sola desde `main`** (la integración GitHub↔Vercel se
  recuperó de la caída del 2026-07-16). Prod ya tiene login de creador + dashboard +
  panel a escala. `kamaq.lat` está en los redirect URLs de Supabase.
- Nota: si prefieren el apex como canónico en vez de www, se cambia el dominio
  primario en Vercel → Domains (kamaq.lat como Production, www redirige).

### Antes de prender los ads (pendiente)
- [ ] **Resend (SMTP)** + verificar dominio (SPF/DKIM en Namecheap) → magic links
  desde `@kamaq.lat` a inbox. Hoy usa el SMTP default de Supabase (limitado): el
  login por **contraseña** funciona; el **magic link** solo aguanta pruebas.
- [ ] **Turnstile + Edge Function** anti-bot en el registro (keys de Cloudflare).

### Producto / infra
- [ ] Pagos: hoy es tracking manual. Automatizar pagos Yape/Plin.
- [ ] Tracking de vistas automático vía APIs de TikTok/Instagram (hoy se ingresan a mano).
- [ ] Dominio kamaq.lat (comprar + apuntar a Vercel en Settings -> Domains).
- [ ] Multi-marca / multi-tenant para abrir la plataforma a otras marcas (visión LATAM).
- [ ] Mover credenciales a variables de entorno; considerar rate-limit / captcha en el registro público.
- [ ] Reclutamiento por ads: la landing ya captura UTM; falta montar/medir campañas en Meta/TikTok/Google apuntando a kamaq.lat/?utm_source=...

## Sugerencia de evolución
Si el proyecto crece, migrar de este único `index.html` a Next.js + componentes, con las llamadas a Supabase en el server donde aplique. Mantener el mismo esquema de base de datos.
