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
import 'package:radici/features/recipes/data/recipes_repository.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';

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
    this.recipes,
  );

  final ProviderContainer container;
  final FakeAuthRepository auth;
  final FakeAccountRepository accounts;
  final FakeChefRequestsRepository requests;
  final FakeLinkLauncher launcher;
  final FakeAvailabilityRepository availability;
  final FakeBookingsRepository bookings;
  final FakeRecipesRepository recipes;

  /// Navega como si se abriera un enlace a [location].
  void go(String location) => container.read(routerProvider).go(location);
}

/// Monta la app con Evelyn logueada. [location] abre una ruta directa (como
/// el botón del email: `INBOX_URL#/richieste/<id>`). [accounts] es su perfil
/// (por defecto, sin idioma: manda el dispositivo). [availability] es su
/// horario y sus días bloqueados (por defecto, lunes a viernes de 9 a 15 y
/// sin bloqueos). [bookings] es la Edge Function de las reservas (por
/// defecto, todo libre y la llegada sugerida a las 10:00; al confirmar, el
/// pedido pasa a `accepted` en [requests]). [recipes] es su catálogo de
/// platos (por defecto, vacío).
Future<ChefApp> pumpChefApp(
  WidgetTester tester, {
  required FakeChefRequestsRepository requests,
  FakeAccountRepository? accounts,
  FakeAvailabilityRepository? availability,
  FakeBookingsRepository? bookings,
  FakeRecipesRepository? recipes,
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
  final catalog = recipes ?? FakeRecipesRepository();
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
      recipesRepositoryProvider.overrideWithValue(catalog),
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
    catalog,
  );
  if (location != null) {
    app.go(location);
    await tester.pumpAndSettle();
  }
  return app;
}
