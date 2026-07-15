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

## Base de datos (ver db/schema.sql)
Tablas: `creadores`, `campanas`, `clips`.

Reglas RLS clave:
- `creadores`: INSERT público (registro desde la landing), SELECT/UPDATE solo `authenticated`.
- `campanas`: SELECT público (para el discover).
- `clips`: INSERT público (enviar clip), SELECT/UPDATE solo `authenticated`.

### GOTCHA importante
Los INSERT públicos deben usar `return=minimal`, es decir `supabase.from('...').insert(obj)` SIN encadenar `.select()`. Como el público NO tiene permiso de SELECT sobre `creadores`/`clips`, pedir la fila de vuelta provoca error de RLS (42501). Ya está resuelto así en el código.

## Flujos implementados en index.html
- Registro de creador (3 pasos con validación) -> insert en `creadores` con estado `nuevo` y `fuente` (captura utm_source de la URL para medir de qué ad vino).
- Discover: lee `campanas` activas.
- Detalle de campaña + enviar clip -> insert en `clips`.
- Panel de marca (login por Supabase Auth):
  - Creadores: aprobar / rechazar.
  - Clips + Vistas: editar vistas (recalcula el pago = vistas/1000 * tarifa_1k), aprobar / rechazar.
  - Campañas: listado.

## Pendiente (Fase 2 y siguientes)
- [ ] Crear un usuario admin en Supabase (Authentication -> Users -> Add user) para poder entrar al panel de marca.
- [ ] Limpiar la fila de prueba en `creadores` (WHERE fuente = 'test-api').
- [ ] Formulario real de "nueva campaña" en el panel (hoy es un alert de demo).
- [ ] Pagos: hoy es tracking manual. Automatizar pagos Yape/Plin.
- [ ] Tracking de vistas automático vía APIs de TikTok/Instagram (hoy se ingresan a mano).
- [ ] Dominio kamaq.lat (comprar + apuntar a Vercel en Settings -> Domains).
- [ ] Multi-marca / multi-tenant para abrir la plataforma a otras marcas (visión LATAM).
- [ ] Mover credenciales a variables de entorno; considerar rate-limit / captcha en el registro público.
- [ ] Reclutamiento por ads: la landing ya captura UTM; falta montar/medir campañas en Meta/TikTok/Google apuntando a kamaq.lat/?utm_source=...

## Sugerencia de evolución
Si el proyecto crece, migrar de este único `index.html` a Next.js + componentes, con las llamadas a Supabase en el server donde aplique. Mantener el mismo esquema de base de datos.
