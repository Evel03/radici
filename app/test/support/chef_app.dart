// La app con la sesión de Evelyn abierta y repositorios falsos.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/router.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/availability/data/availability_repository.dart';
import 'package:radici/features/bookings/data/bookings_repository.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';

import 'fakes.dart';
import 'pump_app.dart';
import 'request_fixtures.dart';

class ChefApp {
  ChefApp(
    this.container,
    this.auth,
    this.accounts,
    this.requests,
    this.launcher,
    this.availability,
    this.bookings,
    this.sessions,
  );

  final ProviderContainer container;
  final FakeAuthRepository auth;
  final FakeAccountRepository accounts;
  final FakeChefRequestsRepository requests;
  final FakeLinkLauncher launcher;
  final FakeAvailabilityRepository availability;
  final FakeBookingsRepository bookings;
  final FakeSessionsRepository sessions;

  /// Navega como si se abriera un enlace a [location].
  void go(String location) => container.read(routerProvider).go(location);
}

/// Monta la app con Evelyn logueada. [location] abre una ruta directa (como
/// el botón del email: `INBOX_URL#/richieste/<id>`). [accounts] es su perfil
/// (por defecto, sin idioma: manda el dispositivo). [availability] es su
/// horario y sus días bloqueados (por defecto, lunes a viernes de 9 a 15 y
/// sin bloqueos). [bookings] es la Edge Function de las reservas (por
/// defecto, todo libre y la llegada sugerida a las 10:00; al confirmar, el
/// pedido pasa a `accepted` en [requests]). [sessions] son sus sesiones y la
/// Edge Function para moverlas y cancelarlas (por defecto, ninguna).
Future<ChefApp> pumpChefApp(
  WidgetTester tester, {
  required FakeChefRequestsRepository requests,
  FakeAccountRepository? accounts,
  FakeAvailabilityRepository? availability,
  FakeBookingsRepository? bookings,
  FakeSessionsRepository? sessions,
  String? location,
  Size size = const Size(400, 900),
  List<Locale> deviceLocales = const [Locale('it', 'IT')],
  DateTime Function()? clock,
  List<Override> overrides = const [],
}) async {
  setSurfaceSize(tester, size);
  final auth = FakeAuthRepository(user: chefUser);
  final account = accounts ?? FakeAccountRepository(chefAccountData);
  final days = availability ?? FakeAvailabilityRepository();
  final booking = bookings ?? FakeBookingsRepository(requests: requests);
  final sessionsRepository = sessions ?? FakeSessionsRepository();
  final launcher = FakeLinkLauncher();
  final container = await pumpRadiciApp(
    tester,
    deviceLocales: deviceLocales,
    clock: clock,
    overrides: [
      authRepositoryProvider.overrideWithValue(auth),
      accountRepositoryProvider.overrideWithValue(account),
      chefRequestsRepositoryProvider.overrideWithValue(requests),
      availabilityRepositoryProvider.overrideWithValue(days),
      bookingsRepositoryProvider.overrideWithValue(booking),
      sessionsRepositoryProvider.overrideWithValue(sessionsRepository),
      linkLauncherProvider.overrideWithValue(launcher),
      ...overrides,
    ],
  );
  final app = ChefApp(
    container,
    auth,
    account,
    requests,
    launcher,
    days,
    booking,
    sessionsRepository,
  );
  if (location != null) {
    app.go(location);
    await tester.pumpAndSettle();
  }
  return app;
}
