// Monta pantallas o la app completa con tema, localizaciones y ProviderScope.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/app.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/env.dart';
import 'package:radici/core/platform.dart';
import 'package:radici/core/theme.dart';
import 'package:radici/l10n/app_localizations.dart';

import 'request_fixtures.dart';

/// Sin reintentos automáticos de Riverpod: un provider que falla en un test
/// tiene que fallar una vez, sin dejar timers pendientes.
Duration? noRetry(int retryCount, Object error) => null;

/// Cuánto esperar antes de cada reintento automático (null: no reintenta).
typedef RetryDelay = Duration? Function(int retryCount, Object error);

/// Como en producción (lib/main.dart no pasa `retry`: Riverpod reintenta
/// solo), pero con un único reintento a los [delay]: mientras tanto el
/// provider queda cargando con el error.
RetryDelay retryOnce([Duration delay = const Duration(seconds: 1)]) =>
    (retryCount, error) => retryCount == 0 ? delay : null;

Future<void> pumpLocalized(
  WidgetTester tester,
  Widget screen, {
  Locale locale = const Locale('it'),
  List<Override> overrides = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      retry: noRetry,
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: screen,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// La app completa (router, redirecciones, aviso de pedidos nuevos).
/// [isWeb] simula la versión web (/gestione/); [clock] es "ahora" (por
/// defecto, siempre [testNow]); [retry], los reintentos automáticos de
/// Riverpod (por defecto, ninguno).
Future<ProviderContainer> pumpRadiciApp(
  WidgetTester tester, {
  List<Override> overrides = const [],
  AppEnv env = const AppEnv(environment: AppEnvironment.prod),
  List<Locale> deviceLocales = const [Locale('it', 'IT')],
  bool isWeb = false,
  bool settle = true,
  DateTime Function()? clock,
  RetryDelay retry = noRetry,
}) async {
  tester.platformDispatcher.localesTestValue = deviceLocales;
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  await tester.pumpWidget(
    ProviderScope(
      retry: retry,
      overrides: [
        appEnvProvider.overrideWithValue(env),
        isWebProvider.overrideWithValue(isWeb),
        clockProvider.overrideWithValue(clock ?? () => testNow),
        ...overrides,
      ],
      child: const RadiciApp(),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(RadiciApp)));
}

/// Cambia el tamaño de la pantalla de prueba (en dp) y lo restaura al final.
void setSurfaceSize(WidgetTester tester, Size size) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}
