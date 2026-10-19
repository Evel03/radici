// La app con la sesión de Evelyn abierta y repositorios falsos.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mestolo/core/link_launcher.dart';
import 'package:mestolo/core/router.dart';
import 'package:mestolo/features/auth/data/account_repository.dart';
import 'package:mestolo/features/auth/data/auth_repository.dart';
import 'package:mestolo/features/requests/data/chef_requests_repository.dart';

import 'fakes.dart';
import 'pump_app.dart';
import 'request_fixtures.dart';

class ChefApp {
  ChefApp(this.container, this.auth, this.requests, this.launcher);

  final ProviderContainer container;
  final FakeAuthRepository auth;
  final FakeChefRequestsRepository requests;
  final FakeLinkLauncher launcher;

  /// Navega como si se abriera un enlace a [location].
  void go(String location) => container.read(routerProvider).go(location);
}

/// Monta la app con Evelyn logueada. [location] abre una ruta directa (como
/// el botón del email: `INBOX_URL#/richieste/<id>`).
Future<ChefApp> pumpChefApp(
  WidgetTester tester, {
  required FakeChefRequestsRepository requests,
  String? location,
  Size size = const Size(400, 900),
  List<Locale> deviceLocales = const [Locale('it', 'IT')],
  List<Override> overrides = const [],
}) async {
  setSurfaceSize(tester, size);
  final auth = FakeAuthRepository(user: chefUser);
  final launcher = FakeLinkLauncher();
  final container = await pumpMestoloApp(
    tester,
    deviceLocales: deviceLocales,
    overrides: [
      authRepositoryProvider.overrideWithValue(auth),
      accountRepositoryProvider.overrideWithValue(
        FakeAccountRepository(chefAccountData),
      ),
      chefRequestsRepositoryProvider.overrideWithValue(requests),
      linkLauncherProvider.overrideWithValue(launcher),
      ...overrides,
    ],
  );
  final app = ChefApp(container, auth, requests, launcher);
  if (location != null) {
    app.go(location);
    await tester.pumpAndSettle();
  }
  return app;
}
