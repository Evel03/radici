// Rutas de la app y a dónde redirigir según la sesión. Dart puro: lo usa
// router.dart y se prueba sin widgets.
//
// En la web (/gestione/) las rutas van en el fragmento: /gestione/#/richieste.
// Así un enlace directo (el botón del email a Evelyn: INBOX_URL#/richieste/<id>)
// funciona sin reglas de reescritura en Cloudflare Pages.
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/auth/application/session_controller.dart';

/// Rutas (en italiano, como las de la web).
abstract final class AppRoutes {
  static const String home = '/';
  static const String quote = '/preventivo';
  static const String login = '/accedi';

  /// Mientras se carga la cuenta (o si falló).
  static const String session = '/caricamento';
  static const String clientArea = '/area-clienti';
  static const String requests = '/richieste';
  static const String agenda = '/agenda';

  /// Impostazioni de la cocinera (idioma de la app y cuenta).
  static const String settings = '/impostazioni';

  /// Pestaña «Altro» de la cocinera: platos, impostazioni y salir.
  static const String more = '/altro';

  /// Catálogo de platos, dentro de «Altro».
  static const String recipes = '$more/piatti';

  /// Editor de un plato nuevo.
  static const String recipeNew = '$recipes/nuovo';

  /// Parámetro de [recipeNew] con el id del plato que se copia (Duplica).
  static const String copyParam = 'copia';

  static String requestDetail(String id) =>
      '$requests/${Uri.encodeComponent(id)}';

  /// Hoja «Conferma prenotazione» de un pedido (a pantalla completa, sobre
  /// el detalle).
  static const String bookingSegment = 'prenota';

  static String requestBooking(String id) =>
      '${requestDetail(id)}/$bookingSegment';

  static String recipeEdit(String id) => '$recipes/${Uri.encodeComponent(id)}';

  static String recipeCopy(String id) =>
      Uri(path: recipeNew, queryParameters: {copyParam: id}).toString();

  /// Ficha de una sesión de cocina (a pantalla completa, sobre la agenda).
  static const String sessions = '/sessioni';

  static String sessionDetail(String id) =>
      '$sessions/${Uri.encodeComponent(id)}';

  /// Hoja «Sposta la sessione» (a pantalla completa, sobre la ficha).
  static const String sessionMoveSegment = 'sposta';

  /// Parámetro con la fecha nueva ya elegida ("AAAA-MM-DD").
  static const String dateParam = 'data';

  static String sessionMove(String id, {CalendarDate? date}) =>
      '${sessionDetail(id)}/$sessionMoveSegment'
      '${date == null ? '' : '?$dateParam=${date.toIso()}'}';

  /// Parámetro con la ruta a la que volver después de entrar.
  static const String fromParam = 'from';
}

/// Rutas del área de la cocinera.
bool isChefPath(String path) =>
    path == AppRoutes.requests ||
    path.startsWith('${AppRoutes.requests}/') ||
    path == AppRoutes.agenda ||
    path.startsWith('${AppRoutes.sessions}/') ||
    path == AppRoutes.settings ||
    path == AppRoutes.more ||
    path.startsWith('${AppRoutes.more}/');

/// A dónde redirigir [location] según [session], o null para quedarse.
///
/// - Sin sesión: el área de la cocinera pide login (recordando a dónde iba).
///   En la web no hay inicio público: `/` es el login.
/// - Cargando la cuenta (o con error): pantalla de carga.
/// - Cocinera: su área (o a donde iba antes del login).
/// - Cualquier otro usuario: área de clientes.
/// La calculadora (`/preventivo`) es pública siempre.
String? resolveRedirect({
  required SessionState session,
  required Uri location,
  required bool isWeb,
}) {
  final path = location.path;
  if (path == AppRoutes.quote) return null;
  final chefRoute = isChefPath(path);
  final from = _safeFrom(location.queryParameters[AppRoutes.fromParam]);

  switch (session) {
    case SignedOut():
      if (chefRoute) return _withFrom(AppRoutes.login, location.toString());
      if (path == AppRoutes.session || path == AppRoutes.clientArea) {
        return isWeb ? AppRoutes.login : AppRoutes.home;
      }
      if (path == AppRoutes.home && isWeb) return AppRoutes.login;
      return null;
    case SessionLoading() || SessionFailed():
      if (path == AppRoutes.session) return null;
      return _withFrom(
        AppRoutes.session,
        chefRoute ? location.toString() : from,
      );
    case ChefSession():
      if (chefRoute) return null;
      return from ?? AppRoutes.requests;
    case ClientSession():
      if (path == AppRoutes.clientArea) return null;
      return AppRoutes.clientArea;
  }
}

/// Solo se vuelve a rutas internas de la cocinera (nada de URLs externas).
String? _safeFrom(String? from) {
  if (from == null || from.isEmpty) return null;
  final uri = Uri.tryParse(from);
  if (uri == null || uri.hasScheme || uri.hasAuthority) return null;
  return isChefPath(uri.path) ? uri.toString() : null;
}

String _withFrom(String base, String? from) => from == null
    ? base
    : Uri(path: base, queryParameters: {AppRoutes.fromParam: from}).toString();
