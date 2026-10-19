// Rutas de la app. Las rutas hijas de `/` apilan sobre el inicio, así
// `context.go` deja el botón de volver.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mestolo/features/auth/presentation/login_screen.dart';
import 'package:mestolo/features/home/presentation/home_screen.dart';
import 'package:mestolo/features/quote/presentation/quote_calculator_screen.dart';

/// Rutas públicas (en italiano, como las de la web).
abstract final class AppRoutes {
  static const String home = '/';
  static const String quote = '/$_quoteSegment';
  static const String login = '/$_loginSegment';

  static const String _quoteSegment = 'preventivo';
  static const String _loginSegment = 'accedi';
}

/// Router como provider: en M2 la redirección según la sesión leerá auth
/// desde acá.
final routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: AppRoutes.home,
    routes: [
      GoRoute(
        path: AppRoutes.home,
        builder: (context, state) => const HomeScreen(),
        routes: [
          GoRoute(
            path: AppRoutes._quoteSegment,
            builder: (context, state) => const QuoteCalculatorScreen(),
          ),
          GoRoute(
            path: AppRoutes._loginSegment,
            builder: (context, state) => const LoginScreen(),
          ),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
