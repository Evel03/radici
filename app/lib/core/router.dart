// Router (go_router). Las redirecciones según la sesión están en routes.dart.
//
// go_router 18 detecta MaterialApp de package:material_ui, no el de
// package:flutter/material.dart que usa esta app: sin un pageBuilder propio
// armaría páginas sin transición. Por eso cada ruta construye su MaterialPage.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/platform.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/presentation/client_area_screen.dart';
import 'package:radici/features/auth/presentation/login_screen.dart';
import 'package:radici/features/auth/presentation/session_screen.dart';
import 'package:radici/features/bookings/presentation/confirm_booking_screen.dart';
import 'package:radici/features/home/presentation/home_screen.dart';
import 'package:radici/features/more/presentation/more_screen.dart';
import 'package:radici/features/quote/presentation/quote_calculator_screen.dart';
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
import 'package:radici/l10n/app_localizations.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');
  final refresh = _RouterRefresh();
  // El router no se reconstruye con la sesión: se le avisa que reevalúe.
  ref.listen(sessionControllerProvider, (_, _) => refresh.notify());
  final isWeb = ref.watch(isWebProvider);

  final router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: AppRoutes.home,
    refreshListenable: refresh,
    redirect: (context, state) => resolveRedirect(
      session: ref.read(sessionControllerProvider),
      location: state.uri,
      isWeb: isWeb,
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
            path: AppRoutes.quote.substring(1),
            pageBuilder: (context, state) =>
                _page(state, const QuoteCalculatorScreen()),
          ),
          GoRoute(
            path: AppRoutes.login.substring(1),
            pageBuilder: (context, state) => _page(state, const LoginScreen()),
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.session,
        pageBuilder: (context, state) => _page(state, const SessionScreen()),
      ),
      GoRoute(
        path: AppRoutes.clientArea,
        pageBuilder: (context, state) =>
            _page(state, const ClientAreaScreen()),
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
        ],
      ),
      StatefulShellRoute.indexedStack(
        pageBuilder: (context, state, navigationShell) =>
            _page(state, ChefShell(navigationShell: navigationShell)),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.requests,
                pageBuilder: (context, state) =>
                    _page(state, const InboxScreen()),
                routes: [
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
                            requestId: state.pathParameters['id']!,
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

/// Una fecha "AAAA-MM-DD" de la URL, o null si falta o no es una fecha.
CalendarDate? _dateOrNull(String? value) {
  if (value == null) return null;
  try {
    return CalendarDate.parse(value);
  } on FormatException {
    return null;
  }
}

/// La ruta de la ficha de una sesión (su hoja «Sposta» cuelga de ella).
const String _sessionPath = '${AppRoutes.sessions}/:id';

/// Hay en la pila de [router], a la vista o tapada por otra pantalla (por
/// ejemplo, un pedido abierto desde el aviso), una hoja «Conferma
/// prenotazione» o la ficha de una sesión (sola o con su hoja «Sposta»). Un
/// go las sacaría sin pasar por ningún PopScope, con lo que tengan a medias:
/// la hoja de reserva, con lo escrito o, mientras se manda, con la pantalla
/// final y su WhatsApp; la ficha, con la hoja «Sposta» a medio mover (y el
/// resultado del que sale «Annulla»), el aviso con «Annulla» después de
/// mover, el diálogo de la dirección con lo escrito o una cancelación que
/// todavía espera la respuesta (la ficha avisa cómo terminó).
bool bookingOrSessionInStack(GoRouter router) {
  bool inStack(List<RouteMatchBase> matches) => matches.any(
    (match) => switch (match) {
      ShellRouteMatch(:final matches) => inStack(matches),
      ImperativeRouteMatch(:final matches) => inStack(matches.matches),
      _ => switch (match.route) {
        GoRoute(
          path:
              AppRoutes.bookingSegment ||
              _sessionPath ||
              AppRoutes.sessionMoveSegment,
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
