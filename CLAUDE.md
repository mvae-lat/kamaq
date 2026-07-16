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

`creadores` y `clips` todavía tienen políticas atadas a `authenticated` (SELECT/UPDATE)
del esquema original. **Migrarlas a `es_admin()` es bloqueante antes de cualquier
login de creador**, o cada creador podría leer los emails y WhatsApps de todos.

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

### Acciones manuales en Supabase (SQL listo en `db/`, falta correrlo)
Estos scripts ya están escritos y revisados; solo hay que ejecutarlos en el SQL
Editor con la sesión del proyecto. Orden obligatorio:
- [ ] **1. Crear el usuario admin** en Authentication -> Users -> Add user
  (email `marlon@mvae.lat`). Bloquea todo lo demás: sin él no se entra al panel
  ni sirve el SQL de abajo.
- [ ] **2. Correr `db/campanas-policies.sql`.** Crea `usuarios_admin` + `es_admin()`
  y da de alta al admin. Sin esto, crear/editar/pausar campañas falla con 42501.
- [ ] **3. Correr `db/creadores-clips-policies.sql` (migración M01).** Ata SELECT/UPDATE
  de `creadores`/`clips` a `es_admin()`. **Bloqueante antes de cualquier login de
  creador.** Depende del paso 2 (usa `es_admin()`; el script aborta si no existe).
- [ ] **4. Correr `db/gastado-trigger.sql`.** Trigger que mantiene `campanas.gastado`
  sincronizado + backfill. Después de esto la columna `gastado` ya es confiable.
- [ ] Verificar que `campanas.estado` acepte `'pausada'`. Si hay un CHECK constraint
  que solo permita `'activa'`, el botón Pausar falla — no se pudo inspeccionar con
  la publishable key. Query: `select conname, pg_get_constraintdef(oid) from pg_constraint where conrelid='public.campanas'::regclass;`
- [ ] Limpiar filas de prueba (requiere admin/SQL, el público no puede borrar):
  `delete from creadores where fuente in ('test-api','qa-kamaq');`
  `delete from clips where link ilike '%qa.kamaq%';`
  (la fila `qa-kamaq` y el clip QA se crearon en el test end-to-end del 2026-07-16.)

### Resuelto en código (working tree)
- [x] CRUD de campañas en el panel (crear/editar/pausar/activar + columna Gastado).
- [x] Saneo del `href` de clips con `safeUrl()` (ya no pasa `javascript:`; solo https de TikTok/Instagram).

### Producto / infra
- [ ] Pagos: hoy es tracking manual. Automatizar pagos Yape/Plin.
- [ ] Tracking de vistas automático vía APIs de TikTok/Instagram (hoy se ingresan a mano).
- [ ] Dominio kamaq.lat (comprar + apuntar a Vercel en Settings -> Domains).
- [ ] Multi-marca / multi-tenant para abrir la plataforma a otras marcas (visión LATAM).
- [ ] Mover credenciales a variables de entorno; considerar rate-limit / captcha en el registro público.
- [ ] Reclutamiento por ads: la landing ya captura UTM; falta montar/medir campañas en Meta/TikTok/Google apuntando a kamaq.lat/?utm_source=...

## Sugerencia de evolución
Si el proyecto crece, migrar de este único `index.html` a Next.js + componentes, con las llamadas a Supabase en el server donde aplique. Mantener el mismo esquema de base de datos.
