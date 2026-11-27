// La portada de la app sin sesión (iOS y Android): las secciones de la web,
// sin precios, el formulario y la privacy abiertos dentro de la app y el
// login arriba y al final.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/features/auth/presentation/login_screen.dart';
import 'package:radici/features/home/presentation/home_screen.dart';
import 'package:radici/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/pump_app.dart';

Future<FakeLinkLauncher> _pumpHome(
  WidgetTester tester, {
  Locale locale = const Locale('it', 'IT'),
}) async {
  final links = FakeLinkLauncher();
  await pumpRadiciApp(
    tester,
    deviceLocales: [locale],
    overrides: [linkLauncherProvider.overrideWithValue(links)],
  );
  expect(find.byType(HomeScreen), findsOneWidget);
  return links;
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in const [
    Locale('it', 'IT'),
    Locale('es', 'ES'),
    Locale('en', 'GB'),
  ]) {
    final code = locale.languageCode;
    final l10n = lookupAppLocalizations(Locale(code));

    testWidgets('tiene las secciones de la portada web ($code)', (
      tester,
    ) async {
      await _pumpHome(tester, locale: locale);
      for (final text in [
        l10n.landingHeroTitle,
        l10n.landingHeroLabel1Title,
        l10n.landingServicesWeekly,
        l10n.landingHowIntro,
        l10n.landingHowStep4Title,
        l10n.landingIncludedTitle,
        l10n.landingIncludedItem5Title,
        l10n.landingPricingTitle,
        l10n.landingPricingMethodsText,
        l10n.landingWhoKidsTitle,
        l10n.landingFaqTitle,
        l10n.landingFaqQ6,
        l10n.landingValuesV4,
        l10n.landingFinalTitle,
        l10n.landingFooterSlogan,
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      // Sin precios (22/11/2026).
      expect(find.textContaining('€'), findsNothing);
    });

    testWidgets(
      'los tres «pedir presupuesto» abren el formulario dentro de la app ($code)',
      (tester) async {
        final links = await _pumpHome(tester, locale: locale);
        for (final key in [
          'home-request',
          'home-request-pricing',
          'home-request-final',
        ]) {
          await _tap(tester, key);
        }
        final form = Uri.parse(
          'https://radicicucina.app/richiesta/?lang=$code',
        );
        expect(links.pages, [form, form, form]);
        expect(links.launched, isEmpty);
      },
    );
  }

  testWidgets('la privacy se abre dentro de la app, en su idioma', (
    tester,
  ) async {
    final links = await _pumpHome(tester, locale: const Locale('en', 'GB'));
    await _tap(tester, 'home-privacy');
    expect(links.pages, [
      Uri.parse('https://radicicucina.app/privacy/?lang=en'),
    ]);
  });

  testWidgets('«Come funziona» baja hasta los cuatro pasos', (tester) async {
    await _pumpHome(tester);
    final title = find.byKey(const ValueKey('home-how-title'));
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(tester.getTopLeft(title).dy, greaterThan(screen.height));

    await tester.tap(find.byKey(const ValueKey('home-how')));
    await tester.pumpAndSettle();
    final top = tester.getTopLeft(title).dy;
    expect(top, greaterThanOrEqualTo(0));
    expect(top, lessThan(screen.height / 2));
  });

  testWidgets('las preguntas se abren y los números salen de los límites', (
    tester,
  ) async {
    await _pumpHome(tester, locale: const Locale('es', 'ES'));
    final l10n = lookupAppLocalizations(const Locale('es'));
    expect(find.text(l10n.landingIncludedItem3Text(2, 6)), findsOneWidget);

    final answer = l10n.landingFaqAWeeks(8);
    // La web separa el número de «semanas» con un espacio duro.
    expect(answer, matches(RegExp(r'hasta 8\s+semanas')));
    expect(find.text(answer), findsNothing);
    await _tap(tester, 'home-faq-2');
    expect(find.text(answer), findsOneWidget);
  });

  testWidgets('las fotos tienen su descripción para el lector de pantalla', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pumpHome(tester);
    final l10n = lookupAppLocalizations(const Locale('it'));
    for (final label in [
      l10n.landingHeroPhotoAlt,
      l10n.landingHowPhotoAlt('Radici'),
      l10n.landingIncludedPhotoAlt('Radici'),
    ]) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
    }
    handle.dispose();
  });

  testWidgets('«Accedi» de arriba lleva al login', (tester) async {
    await _pumpHome(tester);
    await _tap(tester, 'home-login');
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('«Accedi» del final también lleva al login', (tester) async {
    await _pumpHome(tester);
    await _tap(tester, 'home-login-footer');
    expect(find.byType(LoginScreen), findsOneWidget);
  });
}
