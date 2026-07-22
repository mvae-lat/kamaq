# Contexto del proyecto Kamaq — para pasar a cualquier Claude

> **Cómo usar este documento:** pega TODO su contenido al inicio de un chat nuevo
> (Claude.ai, otro dispositivo, un compañero) y di algo como: *"Este es el contexto
> de mi proyecto Kamaq. Léelo y confírmame que entraste en contexto."* Con esto el
> asistente arranca sabiendo qué es el proyecto, cómo está construido, qué está hecho
> y qué falta. (No incluye contraseñas ni API keys por seguridad.)

---

## 1. Qué es Kamaq
Plataforma UGC / **clipping** (estilo Whop *Content Rewards*, ContentRewards, SideShift,
8x) para **Perú → LATAM**. Las **marcas** publican campañas con un brief; los **creadores**
graban un clip, lo postean desde su propia cuenta de **TikTok/Instagram** y **cobran por
cada 1,000 vistas** (CPM), pagados por **Yape / Plin**. El creador **no necesita
seguidores**: se paga por vistas, no por fans. Marcas iniciales: **Vialex** y **Royal Home**.
Operado por **MVAE** (empresa peruana). Se está preparando para **levantar capital**.

**Modelo de pago:** tarifa S/ por 1,000 vistas (ej. S/ 0.80–0.90). Mínimo para el primer
cobro: **10,000 vistas acumuladas**. Revisión de vistas y pago **manuales** hoy (no hay
tracking automático ni pago automático todavía). 0% de comisión al creador.

## 2. Arquitectura
- **Frontend:** una sola SPA en `index.html` (JS vanilla, todo el HTML/CSS/JS inline).
  Se eligió un solo archivo por velocidad de validación. `supabase-js` v2 por CDN.
  Tipografía Inter (Google Fonts). Es además una **PWA instalable** (`manifest.json`,
  `sw.js`, íconos).
- **Backend:** **Supabase** (Postgres + RLS + Auth). No hay servidor propio; la lógica de
  seguridad vive en las políticas RLS.
- **Hosting:** **Vercel**, estático, **deploy automático desde la rama `main`**.
- **Correo:** **Resend** (SMTP conectado a Supabase Auth; dominio verificado, funcionando).

## 3. Ubicación y URLs
- **Repo local:** `/Users/magreda/Projects/Kamaq` · **GitHub:** `github.com/mvae-lat/kamaq`
- **Producción:** `https://www.kamaq.lat` (apex `kamaq.lat` → 308 → www). Deploy solo desde `main`.
- **Supabase (público, seguro para frontend):** URL `https://glyjniopfjwvmfosvlsn.supabase.co`,
  publishable key `sb_publishable_fIRJ5hQTdNe2t_j1QVqdCg_hyGQSJFu` (hardcodeadas en `index.html`).
  La *secret key*, contraseñas y API keys NO están en el repo.
- **Docs del repo:** `CLAUDE.md` (contexto técnico detallado) y `db/*.sql` (migraciones que
  se corren a mano en el SQL Editor de Supabase).

## 4. Base de datos (tablas y reglas)
Tablas: `creadores`, `campanas`, `clips`, `usuarios_admin`.
- **RLS clave:** INSERT **público/anónimo** en `creadores` y `clips` (registro y envío de
  clip desde la landing). SELECT/UPDATE de `creadores`/`clips` y escritura de `campanas`
  atados a la función `es_admin()` (tabla `usuarios_admin`), NO al rol genérico `authenticated`.
- `campanas.brief_json` (jsonb): brief estructurado (objetivo, guión, duración, menciones,
  dos[], donts[], refs[], docUrl). La columna vieja `brief` se conserva como resumen/fallback.
- `clips.estado`: `revision → aprobado → pagando → pagado` (+ `rechazado`). `pagado_at`/`pago_ref`
  para auditoría. Gasto por campaña = suma de clips aprobados/pagando/pagado (derivado, no la
  columna `gastado`).
- `creadores.estado`: `nuevo/contactado/aprobado/activo/pausado/rechazado`. `creadores.user_id`
  vincula al usuario Auth (trigger `on_auth_creador` al signup).
- **Migraciones ya corridas:** `campanas-policies.sql`, `creadores-clips-policies.sql`,
  `gastado-trigger.sql`, `fase2-login-creadores.sql`, `pagos.sql`, `brief-json.sql`.

### GOTCHAS de seguridad (importantes)
- **Escapar SIEMPRE con `esc()`** todo lo que venga de `creadores`/`clips` (INSERT público →
  posible XSS almacenado que correría en la sesión del admin). Las URLs de clips pasan por
  `safeUrl()` (solo https de tiktok/instagram); los links del brief (admin) por `safeHttps()`.
- INSERT públicos usan `return=minimal` (sin `.select()`), porque el anónimo no tiene SELECT.
- Los permisos de escritura van atados a `es_admin()`, nunca a `authenticated` (cada creador
  logueado hereda `authenticated`).

## 5. Estado actual (todo esto está VIVO en producción)
- Landing con calculadora de ganancias, franja de confianza, FAQ, cards "money-forward".
- Registro de creador (3 pasos) que **crea la cuenta con contraseña** y lleva al dashboard.
- **Dashboard del creador:** balance héroe + barra de progreso al mínimo + stat-cards + mis
  clips + editar perfil.
- **Panel de marca** (login Supabase Auth, solo admins): Resumen (funnel por UTM), Creadores
  (aprobar/rechazar/pausar + WhatsApp), Clips (editar vistas + ciclo de vida), **Por pagar**
  (agrupa por creador, total S/, Yape/WhatsApp, "Marcar pagado" en bloque), Campañas
  (formulario en 4 secciones con **brief estructurado** e interactivo).
- **Resend** enviando correos end-to-end. **2 admins:** `marlon@mvae.lat`, `ugc@mvae.lat`.
- **PWA instalable** (en iPhone: Safari → Compartir → "Añadir a pantalla de inicio").
- Auditoría pre-fundraise (bugs de datos arreglados; copy/UX alineado a las referencias).

## 6. Decisiones clave tomadas
- Login de creador por **ambos**: magic link + contraseña.
- **"Confirm email" = OFF** temporal en Supabase Auth (onboarding sin fricción; Resend ya
  funciona, se puede volver a ON si se quiere exigir verificación).
- Promesas de pago **honestas**: sin "en 24h" (el modelo es revisión manual + mínimo 10k).
- **App:** web-first + PWA ahora; app nativa en el roadmap (gatillada por retención, no por FOMO).
- Un solo `index.html`; migrar a Next.js solo si el proyecto crece (mismo esquema de DB).

## 7. Pendientes
**Necesitan assets/decisiones del dueño:**
- Prueba social real: logos de Vialex/Royal Home, screenshot de pago Yape, testimonios reales
  (nombre+ciudad+monto). Dejarlos en `assets/` → se arma la franja anti-estafa.
- Portadas reales en las cards de campaña (hoy son gradientes).

**Antes de prender ads pagados:**
- **Turnstile** (Cloudflare) anti-bot en el registro público.
- **Supabase Pro / Resend Pro** para volumen (free = 100 correos/día).

**Producto/infra a futuro:**
- **Push notifications** (el service worker ya recibe push; falta VAPID + guardar suscripción
  + Edge Function para enviar).
- Tracking automático de vistas (APIs TikTok/IG) y pagos automáticos (hoy manual).
- Multi-marca / multi-tenant para abrir a otras marcas.

## 8. Flujo de trabajo
- Editar código = editar `index.html`. Deploy = commit + push a `main` (Vercel despliega solo).
- Cambios de DB = escribir un archivo en `db/` y correrlo a mano en Supabase → SQL Editor.
- Verificar deploy: `curl` a `https://www.kamaq.lat` y comparar con el último commit.
