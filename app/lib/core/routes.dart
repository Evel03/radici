// Rutas de la app y a dónde redirigir según la sesión. Dart puro: lo usa
// router.dart y se prueba sin widgets.
//
// En la web (/gestione/) las rutas van en el fragmento: /gestione/#/richieste.
// Así un enlace directo (el botón del email a Evelyn: INBOX_URL#/richieste/<id>)
// funciona sin reglas de reescritura en Cloudflare Pages.
//
// Las rutas de la clienta (/area/*) se sirven en /app/ (y en las apps) y las
// de la cocina en /gestione/; cada entrada (app_entry.dart) abre solo las
// suyas y manda a la otra cuenta a «entrá por la otra puerta».
import 'package:radici/core/app_entry.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/auth/application/session_controller.dart';

/// Rutas (en italiano, como las de la web).
abstract final class AppRoutes {
  static const String home = '/';
  static const String login = '/accedi';

  /// Mientras se carga la cuenta (o si falló).
  static const String session = '/caricamento';

  /// El área de la clienta (ClientShell; sus pantallas cuelgan de acá).
  static const String area = '/area';

  /// «Cambia password» de la clienta, sobre su área.
  static const String areaPasswordSegment = 'password';
  static const String areaPassword = '$area/$areaPasswordSegment';

  /// Parámetro de [login] con el email ya escrito (el «Vai al login» de
  /// /accesso/: `/app/#/accedi?email=…`).
  static const String emailParam = 'email';

  /// «Esta cuenta es de la otra entrada»: la de la cocina en /app/ y la de
  /// una clienta en /gestione/.
  static const String wrongEntry = '/ingresso';

  /// Hoy, el inicio de la cocinera (después del login y al abrir la app).
  static const String today = '/oggi';
  static const String requests = '/richieste';
  static const String agenda = '/agenda';

  /// Impostazioni de la cocinera (idioma de la app y cuenta).
  static const String settings = '/impostazioni';

  /// Pestaña «Altro» de la cocinera: platos, impostazioni y salir.
  static const String more = '/altro';

  /// Catálogo de platos, dentro de «Altro».
  static const String recipes = '$more/piatti';

  /// «Contatti per le offerte»: la lista de ofertas y novedades, dentro de
  /// «Altro» (contrato public-request §13).
  static const String marketing = '$more/contatti';

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

  /// Hoja «Preparar presupuesto» de un pedido (a pantalla completa, sobre el
  /// detalle): la de «Conferma prenotazione» con el precio de todo el
  /// presupuesto (SPEC 5.8).
  static const String requestQuoteSegment = 'preventivo';

  static String requestQuote(String id) =>
      '${requestDetail(id)}/$requestQuoteSegment';

  /// «Nuova prenotazione»: elegir la clienta de una reserva a mano (a
  /// pantalla completa, con X). Va antes que el detalle de un pedido.
  static const String newBookingSegment = 'nuova';
  static const String newBooking = '$requests/$newBookingSegment';

  /// El formulario «Nuova cliente», sobre el elegir.
  static const String newClientSegment = 'cliente';
  static const String newBookingNewClient = '$newBooking/$newClientSegment';

  /// Parámetros de la hoja a mano: la ficha elegida y si se eligió desde
  /// «Nuova cliente» (el teléfono ya era de esa ficha).
  static const String clientParam = 'cliente';
  static const String fromFormParam = 'modulo';

  /// La hoja «Conferma prenotazione» a mano: para la ficha [clientId] o, sin
  /// ella, para la ficha nueva del formulario. En la URL van solo ids, nunca
  /// el nombre, el teléfono ni la dirección: en /gestione/ la ruta queda en
  /// el historial del navegador.
  static String newBookingSheet({String? clientId, bool fromForm = false}) =>
      Uri(
        path: '$newBooking/$bookingSegment',
        queryParameters: clientId == null
            ? null
            : {clientParam: clientId, if (fromForm) fromFormParam: '1'},
      ).toString();

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

  /// Hoja «Rinnova prenotazione» de la reserva de una sesión (a pantalla
  /// completa, sobre la ficha o, con push, sobre Hoy).
  static const String sessionRenewSegment = 'rinnova';

  static String sessionRenew(String id) =>
      '${sessionDetail(id)}/$sessionRenewSegment';

  /// El menú de la semana de una sesión (sobre la ficha o, con push, sobre
  /// el pedido o la hoja de reserva confirmada).
  static const String sessionMenuSegment = 'menu';

  static String sessionMenu(String id) =>
      '${sessionDetail(id)}/$sessionMenuSegment';

  /// Parámetro con la ruta a la que volver después de entrar.
  static const String fromParam = 'from';
}

/// Rutas del área de la clienta.
bool isClientPath(String path) =>
    path == AppRoutes.area || path.startsWith('${AppRoutes.area}/');

/// Rutas del área de la cocinera.
bool isChefPath(String path) =>
    path == AppRoutes.today ||
    path == AppRoutes.requests ||
    path.startsWith('${AppRoutes.requests}/') ||
    path == AppRoutes.agenda ||
    path.startsWith('${AppRoutes.sessions}/') ||
    path == AppRoutes.settings ||
    path == AppRoutes.more ||
    path.startsWith('${AppRoutes.more}/');

/// Las rutas que abre [entry]: las de la cocina en /gestione/, las de la
/// clienta en /app/ y, en la app nativa (sin cuenta todavía), las dos.
bool isEntryPath(AppEntry entry, String path) => switch (entry) {
  AppEntry.kitchen => isChefPath(path),
  AppEntry.client => isClientPath(path),
  AppEntry.auto => isChefPath(path) || isClientPath(path),
};

/// La entrada que ve una cuenta: en la app nativa (`auto`) es la de su rol.
AppEntry _accountEntry(AppEntry entry, AppEntry role) =>
    entry == AppEntry.auto ? role : entry;

/// A dónde redirigir [location] según [session], o null para quedarse.
///
/// - Sin sesión: el área de la entrada pide login (recordando a dónde iba);
///   las del otro lado, no se abren. En la web no hay inicio público: `/` es
///   el login.
/// - Cargando la cuenta (o con error): pantalla de carga.
/// - La cuenta de la entrada (la cocinera o un colaborador suyo en /gestione/,
///   una clienta en /app/): su área, que empieza en Hoy o en el inicio de la
///   clienta (o a donde iba antes del login, como el pedido del botón del
///   email).
/// - La cuenta de la otra entrada (una clienta en /gestione/, la cocina en
///   /app/): `/ingresso`, que lo explica y deja salir. Nunca se mezclan.
/// - En la app nativa (`auto`) no hay otra entrada: cada cuenta va a su área
///   según su rol y nunca abre la del otro rol.
String? resolveRedirect({
  required SessionState session,
  required Uri location,
  required bool isWeb,
  AppEntry entry = AppEntry.kitchen,
}) {
  final path = location.path;
  final ownRoute = isEntryPath(entry, path);
  final fromParam = location.queryParameters[AppRoutes.fromParam];
  final from = _safeFrom(entry, fromParam);

  switch (session) {
    case SignedOut():
      if (ownRoute) return _withFrom(AppRoutes.login, location.toString());
      // Las rutas de la otra entrada y las de «ya con sesión» no tienen nada
      // que mostrar sin sesión.
      if (path == AppRoutes.session ||
          path == AppRoutes.wrongEntry ||
          isChefPath(path) ||
          isClientPath(path)) {
        return isWeb ? AppRoutes.login : AppRoutes.home;
      }
      if (path == AppRoutes.home && isWeb) return AppRoutes.login;
      return null;
    case SessionLoading() || SessionFailed():
      if (path == AppRoutes.session) return null;
      return _withFrom(
        AppRoutes.session,
        ownRoute ? location.toString() : from,
      );
    case ChefSession():
      final own = _accountEntry(entry, AppEntry.kitchen);
      return _forAccount(
        ownEntry: own == AppEntry.kitchen,
        ownRoute: isChefPath(path),
        path: path,
        from: _safeFrom(own, fromParam),
        home: AppRoutes.today,
      );
    case ClientSession():
      final own = _accountEntry(entry, AppEntry.client);
      return _forAccount(
        ownEntry: own == AppEntry.client,
        ownRoute: isClientPath(path),
        path: path,
        from: _safeFrom(own, fromParam),
        home: AppRoutes.area,
      );
  }
}

/// Con la cuenta ya cargada: en su entrada, su área; en la otra, `/ingresso`.
String? _forAccount({
  required bool ownEntry,
  required bool ownRoute,
  required String path,
  required String? from,
  required String home,
}) {
  if (!ownEntry) {
    return path == AppRoutes.wrongEntry ? null : AppRoutes.wrongEntry;
  }
  if (ownRoute) return null;
  return from ?? home;
}

/// Solo se vuelve a rutas internas del área de [entry] (nada de URLs
/// externas ni de la otra entrada).
String? _safeFrom(AppEntry entry, String? from) {
  if (from == null || from.isEmpty) return null;
  final uri = Uri.tryParse(from);
  if (uri == null || uri.hasScheme || uri.hasAuthority) return null;
  return isEntryPath(entry, uri.path) ? uri.toString() : null;
}

String _withFrom(String base, String? from) => from == null
    ? base
    : Uri(path: base, queryParameters: {AppRoutes.fromParam: from}).toString();
