// «Vai al login» de /accesso/: lleva al login del área de la clienta, /app/, con el email de la cuenta.
// - El email va en la ruta de la app (Flutter web usa rutas con #: /app/#/accedi), o sea en el fragmento: no llega a
//   ningún servidor. La app lo precarga desde PR17; hasta entonces lo ignora y muestra el login vacío.
// - Es uno de los links a /app/ que permite web/src/build/no-app-links.test.ts (con «Accedi» del encabezado y del pie).

/** La ruta del login en la app (app/lib/core/routes.dart: AppRoutes.login). */
export const APP_LOGIN_ROUTE = "/accedi";

export function loginHref(email: string): string {
  const base = `/app/#${APP_LOGIN_ROUTE}`;
  return email ? `${base}?email=${encodeURIComponent(email)}` : base;
}
