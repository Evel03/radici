// Hoja «Conferma prenotazione» en /gestione/ en Safari del iPhone, con una
// versión nueva publicada (arriba, el aviso de versión y la tarjeta de
// Safari) y el teclado abierto en el precio: en un iPhone SE (375×548 con las
// barras de Safari) y en uno de 390×844 (390×664), el campo que se escribe, el
// precio que se confirma y «Conferma» quedan a la vista arriba del teclado, sin
// desbordes. Con los avisos a la vista no entraban: los dos le quitan a todas
// las pantallas su alto, y la barra de la hoja (unos 128 px) más la barra de
// título no dejaban lugar; con el teclado abierto se esconden.
//
// Mide con las fuentes reales (con la letra de los tests, cada letra es un
// cuadrado y el texto mide de más). Va aparte porque las fuentes que se cargan
// valen para todo el archivo, y los demás tests de la hoja miden con la letra
// de los tests.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/brand.dart';
import 'package:radici/core/browser.dart';
import 'package:radici/core/build_id.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/web_app/data/published_build_repository.dart';

import '../../../support/browser_fakes.dart';
import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/request_fixtures.dart';

void main() {
  setUpAll(() async {
    Future<void> load(String family, List<String> files) {
      final loader = FontLoader(family);
      for (final file in files) {
        loader.addFont(rootBundle.load('assets/fonts/$file'));
      }
      return loader.load();
    }

    const roboto = [
      'Roboto-Regular.ttf',
      'Roboto-Medium.ttf',
      'Roboto-Bold.ttf',
    ];
    await Future.wait([
      load('Roboto', roboto),
      load(brandSerifFont, const ['CormorantGaramond-SemiBold.ttf']),
      // En iOS el tema pide la letra del sistema, que en /gestione/ (Flutter
      // web) no existe: el texto sale en la Roboto que trae la app.
      load('CupertinoSystemText', roboto),
      load('CupertinoSystemDisplay', roboto),
    ]);
  });

  Finder byKey(String key) => find.byKey(ValueKey(key));

  for (final (size, keyboard) in const [
    // Teclado decimal más la barra de Safari.
    (Size(375, 548), 260.0),
    // El teclado de letras con predicciones (el que usan los demás tests).
    (Size(375, 548), 300.0),
    (Size(390, 664), 336.0),
  ]) {
    for (final locale in const [Locale('it', 'IT'), Locale('es', 'ES')]) {
      final height = size.height;
      testWidgets(
        '${size.width.toInt()}×${height.toInt()} con los dos avisos y el teclado '
        '(${keyboard.toInt()}) en el precio: todo a la vista y sin desbordes '
        '(${locale.languageCode})',
        (tester) async {
          final requests = FakeChefRequestsRepository([
            buildRequest(
              weeks: 4,
              preferredDate: CalendarDate(2026, 11, 23),
              estimate: fourWeeksEstimate,
              seenAt: testNow,
            ),
          ]);
          await pumpChefApp(
            tester,
            requests: requests,
            location: '/richieste/req-1',
            size: size,
            deviceLocales: [locale],
            overrides: [
              browserProvider.overrideWithValue(
                FakeBrowser(info: iPhoneInSafari),
              ),
              buildIdProvider.overrideWithValue('abc1234'),
              publishedBuildRepositoryProvider.overrideWithValue(
                FakePublishedBuildRepository('def5678'),
              ),
            ],
          );
          expect(byKey('update-banner'), findsOneWidget);
          expect(byKey('install-hint'), findsOneWidget);
          await tester.tap(byKey('action-confirm-booking'));
          await tester.pumpAndSettle();
          final confirm = byKey('booking-confirm');
          expect(confirm.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);

          await tester.ensureVisible(byKey('booking-price'));
          await tester.pumpAndSettle();
          await tester.tap(byKey('booking-price'));
          await tester.pump();
          tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          expect(byKey('update-banner'), findsNothing);
          expect(byKey('install-hint'), findsNothing);
          expect(confirm.hitTestable(), findsOneWidget);
          expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(height - keyboard));
          expect(byKey('booking-summary').hitTestable(), findsOneWidget);
          final field = find.descendant(
            of: byKey('booking-price'),
            matching: find.byType(EditableText),
          );
          expect(field.hitTestable(), findsOneWidget);
          final form = tester.getRect(byKey('booking-form'));
          final input = tester.getRect(field);
          expect(input.top, greaterThanOrEqualTo(form.top));
          expect(input.bottom, lessThanOrEqualTo(form.bottom));

          // Al cerrar el teclado vuelven, sin desbordes.
          tester.view.resetViewInsets();
          await tester.pumpAndSettle();
          expect(byKey('update-banner'), findsOneWidget);
          expect(byKey('install-hint'), findsOneWidget);
          expect(confirm.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
        variant: const TargetPlatformVariant({
          TargetPlatform.android,
          TargetPlatform.iOS,
        }),
      );
    }
  }
}
