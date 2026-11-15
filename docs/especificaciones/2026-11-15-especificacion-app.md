> Especificación de la app que mandó el dueño el 15/11/2026, copiada sin cambios debajo de este encabezado. Queda como historia: no se actualiza.
> Manda [SPEC.md](../../SPEC.md), que la integra con las decisiones del dueño de ese mismo día; donde difieren, vale SPEC.md.

# Radici — Especificación de la app

Servicio de cocina a domicilio de Evelyn en Bergamo. Web actual: radicicucina.app (solo calculadora y solicitud de presupuesto). Objetivo: pasar de la web a una app con área de clientes y tablero de administración.

## Stack

- **Cloudflare:** hosting y dominio.
- **Supabase:** autenticación y base de datos.
- **Resend:** emails transaccionales.
- Pendiente de revisar en el código: cómo se guardan y notifican hoy las solicitudes de presupuesto.

## Parte pública

- Se mantiene la calculadora y la solicitud de presupuesto.
- Sección de eventos privados (cenas privadas, etc.) para pedir un evento.

## Usuarios y acceso

- El cliente se registra y hace login; su perfil se crea automáticamente, sin intervención de Evelyn.
- Estados del perfil: **prospecto** y **cliente activo**.
- La lista de platos y la elección semanal solo se ven cuando el perfil es cliente activo (por ejemplo, después de aceptar el primer presupuesto).

## Menú semanal

- Lista fija de unos 20 platos que Evelyn rota según la temporada.
- El cliente tilda exactamente tantos platos como días contratados por semana (por ejemplo, 3 o 5).
- Abajo hay un campo libre para pedir cambios o sugerir platos.
- Los pedidos especiales quedan **pendientes** hasta que Evelyn los aprueba o propone una alternativa.
- **Plazo de elección:** hasta un día antes de la primera sesión de cocina de la semana.
- **Si no elige a tiempo:** se repite el menú de la semana anterior.
- **Cliente nuevo sin historial:** Evelyn le arma el menú.

## Eventos privados

- Flujo separado del menú semanal.
- El cliente envía una solicitud con fecha, cantidad de invitados e idea del evento.
- El menú es especial y se acuerda con el cliente; no usa la lista semanal.
- No se muestra un precio estimado automático: Evelyn pasa el presupuesto después de hablar con el cliente.
- Estados sugeridos: nueva, en charla, presupuestada, confirmada, rechazada.

## Tablero de administración (Evelyn)

Pensado primero para el celular.

- **Inicio:** lista de pendientes (solicitudes nuevas, pedidos especiales para aprobar, clientes que no eligieron a tiempo, sesiones próximas). Cada acción se resuelve con uno o dos toques.
- **Solicitudes:** presupuestos y eventos, con su estado.
- **Clientes:** perfiles con alergias, preferencias e historial; activar un prospecto como cliente.
- **Menús de la semana:** elecciones de cada cliente y aprobación de pedidos especiales.
- **Catálogo de platos:** alta, baja y rotación por temporada.
- **Agenda:** sesiones semanales y eventos por día.
- **Notificaciones push:** una por cada solicitud nueva.

## Temas pendientes

- Pagos: cuándo se paga el servicio y cuándo los ingredientes (idea original: pago anticipado de ingredientes).
- Agenda y disponibilidad.
- Control de insumos con vencimiento.
- Web actual: quitar `noindex, nofollow` si ya es pública, agregar contacto directo (WhatsApp/email) y texto alternativo en las imágenes.
