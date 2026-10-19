// Humo de la app completa: arranque, idioma por defecto, navegación y aviso
// de backend.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mestolo/app.dart';
import 'package:mestolo/core/env.dart';
import 'package:mestolo/features/auth/presentation/login_screen.dart';
import 'package:mestolo/features/quote/presentation/quote_calculator_screen.dart';

const _devWithoutBackend = AppEnv(environment: AppEnvironment.dev);
const _prodWithoutBackend = AppEnv(environment: AppEnvironment.prod);

Future<void> _pumpApp(
  WidgetTester tester, {
  AppEnv env = _devWithoutBackend,
  List<Locale> deviceLocales = const [Locale('it', 'IT')],
}) async {
  tester.platformDispatcher.localesTestValue = deviceLocales;
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appEnvProvider.overrideWithValue(env)],
      child: const MestoloApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('arranca en el inicio, en italiano', (tester) async {
    await _pumpApp(tester);
    expect(find.text('Cucina di casa, a casa tua'), findsOneWidget);
    expect(find.text('Calcola preventivo'), findsOneWidget);
    expect(find.text('Accedi'), findsOneWidget);
  });

  testWidgets('con un idioma no soportado usa el italiano', (tester) async {
    await _pumpApp(tester, deviceLocales: const [Locale('de', 'DE')]);
    expect(find.text('Calcola preventivo'), findsOneWidget);
  });

  testWidgets('con el dispositivo en español usa el español', (tester) async {
    await _pumpApp(tester, deviceLocales: const [Locale('es', 'AR')]);
    expect(find.text('Calcular presupuesto'), findsOneWidget);
  });

  testWidgets('navega a la calculadora y vuelve', (tester) async {
    await _pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('home-quote')));
    await tester.pumpAndSettle();
    expect(find.byType(QuoteCalculatorScreen), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(QuoteCalculatorScreen), findsNothing);
  });

  testWidgets('navega al login (placeholder)', (tester) async {
    await _pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('home-login')));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('login-send-code')));
    await tester.pump();
    expect(find.text("L'accesso sarà disponibile a breve."), findsOneWidget);
  });

  testWidgets('en dev sin backend muestra el aviso', (tester) async {
    await _pumpApp(tester);
    expect(find.text('Backend non configurato'), findsOneWidget);
  });

  testWidgets('en prod no muestra el aviso', (tester) async {
    await _pumpApp(tester, env: _prodWithoutBackend);
    expect(find.text('Backend non configurato'), findsNothing);
  });
}
