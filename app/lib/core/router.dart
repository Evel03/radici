// Router (go_router). Las redirecciones según la sesión están en routes.dart.
//
// go_router 18 detecta MaterialApp de package:material_ui, no el de
// package:flutter/material.dart que usa esta app: sin un pageBuilder propio
// armaría páginas sin transición. Por eso cada ruta construye su MaterialPage.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/app_entry.dart';
import 'package:radici/core/open_dialogs.dart';
import 'package:radici/core/platform.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/auth/application/auth_link_error.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/presentation/change_password_screen.dart';
import 'package:radici/features/auth/presentation/login_screen.dart';
import 'package:radici/features/auth/presentation/session_screen.dart';
import 'package:radici/features/auth/presentation/wrong_entry_screen.dart';
import 'package:radici/features/bookings/application/booking_seed.dart';
import 'package:radici/features/bookings/application/confirm_booking_controller.dart';
import 'package:radici/features/bookings/presentation/confirm_booking_screen.dart';
import 'package:radici/features/bookings/presentation/new_booking_client_screen.dart';
import 'package:radici/features/bookings/presentation/new_client_screen.dart';
import 'package:radici/features/client/presentation/client_shell.dart';
import 'package:radici/features/home/presentation/home_screen.dart';
import 'package:radici/features/marketing/presentation/marketing_contacts_screen.dart';
import 'package:radici/features/more/presentation/more_screen.dart';
import 'package:radici/features/recipes/application/recipe_editor_controller.dart';
import 'package:radici/features/recipes/presentation/recipe_editor_screen.dart';
import 'package:radici/features/recipes/presentation/recipes_screen.dart';
import 'package:radici/features/requests/presentation/agenda_screen.dart';
import 'package:radici/features/requests/presentation/chef_shell.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart';
import 'package:radici/features/requests/presentation/request_detail_screen.dart';
import 'package:radici/features/sessions/presentation/cooking_session_screen.dart';
import 'package:radici/features/sessions/presentation/move_session_screen.dart';
import 'package:radici/features/settings/presentation/settings_screen.dart';
import 'package:radici/features/today/presentation/today_screen.dart';
import 'package:radici/features/week_menu/application/week_menu_editor_controller.dart';
import 'package:radici/features/week_menu/presentation/week_menu_screen.dart';
import 'package:radici/l10n/app_localizations.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');
  final refresh = _RouterRefresh();
  // El router no se reconstruye con la sesión: se le avisa que reevalúe.
  ref.listen(sessionControllerProvider, (_, _) => refresh.notify());
  // Los errores de los links de Auth pueden llegar antes de abrir el login
  // (la URL de arranque): se escuchan desde ya.
  ref.listen(authLinkErrorProvider, (_, _) {});
  final isWeb = ref.watch(isWebProvider);
  final entry = ref.watch(appEntryProvider);

  final router = GoRouter(
    navigatorKey: rootNavigatorKey,
    // Los del navegador raíz, adonde van los diálogos: mientras haya uno
    // abierto, los avisos de /gestione/ se esconden.
    observers: [OpenDialogsObserver(ref.watch(openDialogsProvider.notifier))],
    initialLocation: AppRoutes.home,
    refreshListenable: refresh,
    redirect: (context, state) => resolveRedirect(
      session: ref.read(sessionControllerProvider),
      location: state.uri,
      isWeb: isWeb,
      entry: entry,
    ),
    errorPageBuilder: (context, state) =>
        _page(state, const NotFoundScreen()),
    routes: [
      GoRoute(
        path: AppRoutes.home,
        pageBuilder: (context, state) => _page(state, const HomeScreen()),
        routes: [
          // Hijas de `/`: apilan sobre el inicio y dejan el botón de volver.
          GoRoute(
            path: AppRoutes.login.substring(1),
            pageBuilder: (context, state) => _page(
              state,
              LoginScreen(
                initialEmail: state.uri.queryParameters[AppRoutes.emailParam],
              ),
            ),
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.session,
        pageBuilder: (context, state) => _page(state, const SessionScreen()),
      ),
      GoRoute(
        path: AppRoutes.wrongEntry,
        pageBuilder: (context, state) =>
            _page(state, const WrongEntryScreen()),
      ),
      // El área de la clienta (entrada /app/). Provisoria: sus pantallas
      // cuelgan de acá en los PRs siguientes.
      GoRoute(
        path: AppRoutes.area,
        pageBuilder: (context, state) => _page(state, const ClientShell()),
        routes: [
          GoRoute(
            path: AppRoutes.areaPasswordSegment,
            pageBuilder: (context, state) =>
                _page(state, const ChangePasswordScreen()),
          ),
        ],
      ),
      // Fuera de la estructura con pestañas: tapa la barra de navegación y
      // se abre con push desde el menú de la cuenta.
      GoRoute(
        path: AppRoutes.settings,
        pageBuilder: (context, state) => _page(state, const SettingsScreen()),
      ),
      // La ficha de una sesión, también fuera de las pestañas (tapa la barra;
      // se abre con push desde la agenda).
      GoRoute(
        path: _sessionPath,
        pageBuilder: (context, state) => _page(
          state,
          CookingSessionScreen(sessionId: state.pathParameters['id']!),
        ),
        routes: [
          // «Sposta la sessione», a pantalla completa (con X).
          GoRoute(
            path: AppRoutes.sessionMoveSegment,
            pageBuilder: (context, state) => MaterialPage<void>(
              key: state.pageKey,
              fullscreenDialog: true,
              child: MoveSessionScreen(
                sessionId: state.pathParameters['id']!,
                date: _dateOrNull(
                  state.uri.queryParameters[AppRoutes.dateParam],
                ),
              ),
            ),
          ),
          // «Rinnova prenotazione», a pantalla completa (con X). Con push
          // desde Hoy se apila solo la hoja: al cerrarla, vuelve a Hoy.
          GoRoute(
            path: AppRoutes.sessionRenewSegment,
            pageBuilder: (context, state) => MaterialPage<void>(
              key: state.pageKey,
              fullscreenDialog: true,
              child: ConfirmBookingScreen(source: _renewalSource(state)),
            ),
            onExit: (context, state) =>
                _canLeaveBooking(ref, _renewalSource(state)),
          ),
          // El menú de la semana. Con push desde un pedido o desde la hoja de
          // reserva confirmada se apila solo el menú. Su «Nuevo plato» se
          // abre encima sin ruta (Navigator.push): no deja una entrada en el
          // historial del navegador entre el menú y el editor de platos.
          GoRoute(
            path: AppRoutes.sessionMenuSegment,
            pageBuilder: (context, state) => _page(
              state,
              WeekMenuScreen(sessionId: state.pathParameters['id']!),
            ),
            onExit: (context, state) =>
                _canLeaveMenu(context, ref, state.pathParameters['id']!),
          ),
        ],
      ),
      StatefulShellRoute.indexedStack(
        pageBuilder: (context, state, navigationShell) =>
            _page(state, ChefShell(navigationShell: navigationShell)),
        // En el orden de la barra: Oggi, Richieste, Agenda y Altro.
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.today,
                pageBuilder: (context, state) =>
                    _page(state, const TodayScreen()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.requests,
                pageBuilder: (context, state) =>
                    _page(state, const InboxScreen()),
                routes: [
                  // «Nuova prenotazione»: elegir la clienta, a pantalla
                  // completa (con X). Va antes que «:id».
                  GoRoute(
                    path: AppRoutes.newBookingSegment,
                    parentNavigatorKey: rootNavigatorKey,
                    pageBuilder: (context, state) => MaterialPage<void>(
                      key: state.pageKey,
                      fullscreenDialog: true,
                      child: const NewBookingClientScreen(),
                    ),
                    routes: [
                      // «Nuova cliente», con la flecha de volver al elegir.
                      GoRoute(
                        path: AppRoutes.newClientSegment,
                        parentNavigatorKey: rootNavigatorKey,
                        pageBuilder: (context, state) =>
                            _page(state, const NewClientScreen()),
                      ),
                      // La hoja a mano: la ficha de la URL o, sin ella, la
                      // ficha nueva del formulario.
                      GoRoute(
                        path: AppRoutes.bookingSegment,
                        parentNavigatorKey: rootNavigatorKey,
                        pageBuilder: (context, state) => MaterialPage<void>(
                          key: state.pageKey,
                          fullscreenDialog: true,
                          child: ConfirmBookingScreen(
                            source: _manualSource(state),
                          ),
                        ),
                        onExit: (context, state) =>
                            _canLeaveBooking(ref, _manualSource(state)),
                      ),
                    ],
                  ),
                  // El detalle tapa la barra de navegación.
                  GoRoute(
                    path: ':id',
                    parentNavigatorKey: rootNavigatorKey,
                    pageBuilder: (context, state) => _page(
                      state,
                      RequestDetailScreen(
                        requestId: state.pathParameters['id']!,
                      ),
                    ),
                    routes: [
                      // «Conferma prenotazione», a pantalla completa (con X).
                      GoRoute(
                        path: AppRoutes.bookingSegment,
                        parentNavigatorKey: rootNavigatorKey,
                        pageBuilder: (context, state) => MaterialPage<void>(
                          key: state.pageKey,
                          fullscreenDialog: true,
                          child: ConfirmBookingScreen(
                            source: BookingSource.request(
                              state.pathParameters['id']!,
                            ),
                          ),
                        ),
                      ),
                      // «Preparar presupuesto», la misma hoja (con X). Al
                      // crearlo se reemplaza por el menú de la semana 1.
                      GoRoute(
                        path: AppRoutes.requestQuoteSegment,
                        parentNavigatorKey: rootNavigatorKey,
                        pageBuilder: (context, state) => MaterialPage<void>(
                          key: state.pageKey,
                          fullscreenDialog: true,
                          child: ConfirmBookingScreen(
                            source: BookingSource.quote(
                              state.pathParameters['id']!,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.agenda,
                pageBuilder: (context, state) =>
                    _page(state, const AgendaScreen()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.more,
                pageBuilder: (context, state) =>
                    _page(state, const MoreScreen()),
                routes: [
                  // Dentro de la pestaña: la barra sigue a la vista.
                  GoRoute(
                    path: AppRoutes.marketing.substring(
                      AppRoutes.more.length + 1,
                    ),
                    pageBuilder: (context, state) =>
                        _page(state, const MarketingContactsScreen()),
                  ),
                  GoRoute(
                    path: AppRoutes.recipes.substring(AppRoutes.more.length + 1),
                    pageBuilder: (context, state) =>
                        _page(state, const RecipesScreen()),
                    routes: [
                      // El editor tapa la barra de navegación. «nuovo» va
                      // antes que «:id».
                      GoRoute(
                        path: AppRoutes.recipeNew.substring(
                          AppRoutes.recipes.length + 1,
                        ),
                        parentNavigatorKey: rootNavigatorKey,
                        pageBuilder: (context, state) {
                          final copyOf =
                              state.uri.queryParameters[AppRoutes.copyParam];
                          return _page(
                            state,
                            RecipeEditorScreen(
                              target: copyOf == null
                                  ? const RecipeEditorTarget.create()
                                  : RecipeEditorTarget.copy(copyOf),
                            ),
                          );
                        },
                      ),
                      GoRoute(
                        path: ':id',
                        parentNavigatorKey: rootNavigatorKey,
                        pageBuilder: (context, state) => _page(
                          state,
                          RecipeEditorScreen(
                            target: RecipeEditorTarget.edit(
                              state.pathParameters['id']!,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
});

Page<void> _page(GoRouterState state, Widget child) =>
    MaterialPage<void>(key: state.pageKey, child: child);

/// La fuente de la hoja a mano: la ficha de la URL o, sin ella, la ficha
/// nueva del formulario.
BookingSource _manualSource(GoRouterState state) {
  final query = state.uri.queryParameters;
  final clientId = query[AppRoutes.clientParam];
  return clientId == null
      ? const BookingSource.newClient()
      : BookingSource.client(
          clientId,
          fromForm: query[AppRoutes.fromFormParam] == '1',
        );
}

/// La fuente de la hoja «Rinnova»: la sesión de la URL.
BookingSource _renewalSource(GoRouterState state) =>
    BookingSource.renewal(state.pathParameters['id']!);

/// El onExit de las hojas que crean el pedido (a mano y «Rinnova»): go_router
/// lo consulta por todos los caminos, también el atrás del navegador en
/// /gestione/ (el botón, el gesto de Safari o el atrás de Android en la PWA),
/// que entra por setNewRoutePath y no pasa por PopScope. La hoja no sale
/// mientras se manda o espera el reintento de una confirmación sin respuesta
/// (ConfirmBookingState.holdsOpen). Sin la sesión de la cocinera, sí: la
/// redirección al login la saca (la hoja ya no podría confirmar nada).
bool _canLeaveBooking(Ref ref, BookingSource source) {
  if (ref.read(sessionControllerProvider) is! ChefSession) return true;
  final provider = confirmBookingProvider(source);
  return !ref.exists(provider) || !ref.read(provider).holdsOpen;
}

/// El onExit del menú de la semana: con cambios sin guardar pregunta antes
/// de descartarlos, también por el atrás del navegador en /gestione/ (que no
/// pasa por PopScope). Mientras guarda no sale. Si ya se eligió descartar en
/// la pantalla (WeekMenuEditorState.leaving) o ya no se puede guardar nada
/// (la sesión no admite menú), sale sin preguntar. Sin la sesión de la
/// cocinera, también: la redirección al login la saca.
///
/// No marca nada en el editor: si el menú siguiera en la pila de destino (una
/// entrada del historial rearmada por go_router cuenta como salida aunque la
/// página quede), seguiría protegido.
Future<bool> _canLeaveMenu(
  BuildContext context,
  Ref ref,
  String sessionId,
) async {
  if (ref.read(sessionControllerProvider) is! ChefSession) return true;
  final provider = weekMenuEditorProvider(sessionId);
  if (!ref.exists(provider)) return true;
  final state = ref.read(provider).value;
  if (state == null || state.leaving || state.locked) return true;
  if (state.busy) return false;
  if (!state.dirty) return true;
  return confirmDiscardMenuChanges(context);
}

/// Una fecha "AAAA-MM-DD" de la URL, o null si falta o no es una fecha.
CalendarDate? _dateOrNull(String? value) {
  if (value == null) return null;
  try {
    return CalendarDate.parse(value);
  } on FormatException {
    return null;
  }
}

/// La ruta de la ficha de una sesión (sus hojas «Sposta» y «Rinnova» cuelgan
/// de ella).
const String _sessionPath = '${AppRoutes.sessions}/:id';

/// Hay en la pila de [router], a la vista o tapada por otra pantalla (por
/// ejemplo, un pedido abierto desde el aviso), una hoja «Conferma
/// prenotazione» (desde un pedido, a mano, «Rinnova» o «Preparar
/// presupuesto»), el elegir de «Nuova
/// prenotazione», su formulario «Nuova cliente» o la ficha de una sesión
/// (sola, con su hoja «Sposta» o con el menú de la semana, que cuelga de ella
/// también cuando se apila solo desde un pedido o una hoja de reserva). Un go
/// las sacaría sin pasar por ningún PopScope, con lo que tengan a medias: la
/// hoja de reserva, con lo escrito o, mientras se manda, con la pantalla
/// final y su WhatsApp; el elegir y el formulario, con la búsqueda y el
/// borrador de la ficha nueva; la ficha, con la hoja «Sposta» a medio mover
/// (y el resultado del que sale «Annulla») o el aviso con «Annulla» después
/// de mover; el menú de la semana pregunta antes con su onExit.
///
/// Con la ficha en la pila, hoy a «Apri» solo se llega desde la hoja
/// «Sposta» o desde un pedido o una hoja de reserva abiertos encima: sobre la
/// ficha y sus diálogos el aviso no se ve (la ficha tiene su propio
/// ScaffoldMessenger y, en el navegador raíz, tapa el Scaffold de la barra,
/// que es donde sale). Así también queda una cancelación de otras semanas que
/// espera la respuesta: con la semana de la ficha cobrada, el aviso de semanas
/// cobradas cancela solo las no cobradas y «Sposta» sigue habilitado. El
/// diálogo de la dirección con lo escrito y una cancelación que incluye la
/// semana de la ficha quedan cubiertos por si el aviso algún día sale sobre la
/// ficha: eso sí es preventivo.
bool bookingOrSessionInStack(GoRouter router) {
  bool inStack(List<RouteMatchBase> matches) => matches.any(
    (match) => switch (match) {
      ShellRouteMatch(:final matches) => inStack(matches),
      ImperativeRouteMatch(:final matches) => inStack(matches.matches),
      _ => switch (match.route) {
        GoRoute(
          path: AppRoutes.bookingSegment ||
              AppRoutes.requestQuoteSegment ||
              AppRoutes.newBookingSegment ||
              AppRoutes.newClientSegment ||
              _sessionPath ||
              AppRoutes.sessionMoveSegment ||
              AppRoutes.sessionRenewSegment,
        ) =>
          true,
        _ => false,
      },
    },
  );
  return inStack(router.routerDelegate.currentConfiguration.matches);
}

class _RouterRefresh extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// Ruta desconocida.
class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTitle)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.routeNotFound, key: const ValueKey('route-not-found')),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go(AppRoutes.home),
                child: Text(l10n.routeGoHome),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
