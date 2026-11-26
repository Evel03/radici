// «Vai al login» de /accesso/: lleva al login del área de la clienta, /app/, con el email de la cuenta.
// - El email va en la ruta de la app (Flutter web usa rutas con #: /app/#/accedi), o sea en el fragmento: no llega a
//   ningún servidor. La app lo precarga desde PR17; hasta entonces lo ignora y muestra el login vacío.
// - Es el ÚNICO archivo de la web que nombra /app/ antes del lanzamiento (web/src/build/no-app-links.test.ts lo
//   permite a propósito): a /accesso/ solo se llega desde un email de Auth, y las altas siguen cerradas hasta PR20.

/** La ruta del login en la app (app/lib/core/routes.dart: AppRoutes.login). */
export const APP_LOGIN_ROUTE = "/accedi";

export function loginHref(email: string): string {
  const base = `/app/#${APP_LOGIN_ROUTE}`;
  return email ? `${base}?email=${encodeURIComponent(email)}` : base;
}
