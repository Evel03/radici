// La hoja «Sposta» y el diálogo «Aggiungi indirizzo» en /gestione/ en Safari
// del iPhone, con una versión nueva publicada (arriba, el aviso de versión y
// la tarjeta de Safari), en un iPhone SE (375×548 con las barras de Safari) y
// en uno de 390×844 (390×664):
// - La hoja no tiene campos propios: con los dos avisos a la vista, «Sposta
//   a …» queda abajo, en el tercio inferior, y lo que dice la barra, a la
//   vista, sin desbordes (también con la semana ocupada, cuando la barra
//   dice por qué no se puede).
// - En el diálogo, con el teclado abierto los avisos se esconden y el campo y
//   «Salva» quedan arriba del teclado, sin desbordes; al cerrarlo vuelven.
//
// Mide con las fuentes reales (con la letra de los tests, cada letra es un
// cuadrado y el texto mide de más). Va aparte, como
// confirm_booking_notices_test, porque las fuentes que se cargan valen para
// todo el archivo.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/brand.dart';
import 'package:radici/core/browser.dart';
import 'package:radici/core/build_id.dart';
import 'package:radici/features/sessions/presentation/move_session_screen.dart';
import 'package:radici/features/web_app/data/published_build_repository.dart';

import '../../../support/browser_fakes.dart';
import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

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

  // Safari fuera de la app instalada y otra versión publicada: los dos avisos.
  List<Override> notices() => [
    browserProvider.overrideWithValue(FakeBrowser(info: iPhoneInSafari)),
    buildIdProvider.overrideWithValue('abc1234'),
    publishedBuildRepositoryProvider.overrideWithValue(
      FakePublishedBuildRepository('def5678'),
    ),
  ];

  const platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.iOS,
  });

  for (final size in const [Size(375, 548), Size(390, 664)]) {
    for (final locale in const [Locale('it', 'IT'), Locale('es', 'ES')]) {
      // 3/12: libre (la barra dice cómo queda). 10/12: la semana del 9/12, que
      // ya tiene otra sesión de la reserva (la barra dice por qué no).
      for (final (date, weekTaken) in const [
        ('2026-12-03', false),
        ('2026-12-10', true),
      ]) {
        final height = size.height;
        testWidgets(
          'hoja «Sposta» a ${size.width.toInt()}×${height.toInt()} con los dos '
          'avisos${weekTaken ? ', con la semana ocupada' : ''}: la barra a la '
          'vista, abajo, y sin desbordes (${locale.languageCode})',
          (tester) async {
            await pumpChefApp(
              tester,
              requests: FakeChefRequestsRepository(const []),
              sessions: FakeSessionsRepository(buildBooking()),
              location: '/sessioni/${sessionId(2)}/sposta?data=$date',
              size: size,
              deviceLocales: [locale],
              overrides: notices(),
            );
            expect(find.byType(MoveSessionScreen), findsOneWidget);
            expect(byKey('update-banner'), findsOneWidget);
            expect(byKey('install-hint'), findsOneWidget);
            expect(tester.takeException(), isNull);

            final confirm = byKey('move-confirm');
            expect(confirm.hitTestable(), findsOneWidget);
            final rect = tester.getRect(confirm);
            expect(rect.bottom, lessThanOrEqualTo(height));
            expect(rect.center.dy, greaterThan(height * 2 / 3));
            expect(rect.height, greaterThanOrEqualTo(48));
            expect(
              byKey(weekTaken ? 'move-blocker' : 'move-summary').hitTestable(),
              findsOneWidget,
            );
            if (weekTaken) {
              // La salida, en el formulario: se llega desplazando.
              await tester.ensureVisible(byKey('move-to-end'));
              await tester.pumpAndSettle();
              expect(byKey('move-to-end').hitTestable(), findsOneWidget);
            }
            await tester.drag(byKey('move-form'), const Offset(0, -1000));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(confirm.hitTestable(), findsOneWidget);
          },
          variant: platforms,
        );
      }
    }
  }

  for (final (size, keyboard) in const [
    // Teclado de letras sin predicciones y con predicciones (el que usan los
    // demás tests).
    (Size(375, 548), 260.0),
    (Size(375, 548), 300.0),
    (Size(390, 664), 336.0),
  ]) {
    for (final locale in const [Locale('it', 'IT'), Locale('es', 'ES')]) {
      final height = size.height;
      testWidgets(
        '«Aggiungi indirizzo» a ${size.width.toInt()}×${height.toInt()} con los '
        'dos avisos y el teclado (${keyboard.toInt()}): el campo y «Salva» '
        'arriba del teclado, sin desbordes (${locale.languageCode})',
        (tester) async {
          final app = await pumpChefApp(
            tester,
            requests: FakeChefRequestsRepository(const []),
            // Como llegan de la web: sin dirección.
            sessions: FakeSessionsRepository(
              buildBooking(address: null, restrictions: webRestrictions),
            ),
            location: '/sessioni/${sessionId(2)}',
            size: size,
            deviceLocales: [locale],
            overrides: notices(),
          );
          expect(byKey('update-banner'), findsOneWidget);
          expect(byKey('install-hint'), findsOneWidget);
          await tester.tap(byKey('session-add-address'));
          await tester.pumpAndSettle();
          expect(byKey('client-address-dialog'), findsOneWidget);
          expect(tester.takeException(), isNull);

          // El campo tiene el foco al abrir: llega el teclado.
          tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
          await tester.pumpAndSettle();
          await tester.enterText(
            byKey('client-address-field'),
            'Via Pignolo 5, 24121 Bergamo',
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          expect(byKey('update-banner'), findsNothing);
          expect(byKey('install-hint'), findsNothing);
          final field = find.descendant(
            of: byKey('client-address-field'),
            matching: find.byType(EditableText),
          );
          expect(field.hitTestable(), findsOneWidget);
          expect(
            tester.getRect(field).bottom,
            lessThanOrEqualTo(height - keyboard),
          );
          final save = byKey('client-address-save');
          expect(save.hitTestable(), findsOneWidget);
          expect(
            tester.getRect(save).bottom,
            lessThanOrEqualTo(height - keyboard),
          );
          expect(byKey('client-address-cancel').hitTestable(), findsOneWidget);

          // Al cerrar el teclado vuelven, sin desbordes, y se guarda.
          tester.view.resetViewInsets();
          await tester.pumpAndSettle();
          expect(byKey('update-banner'), findsOneWidget);
          expect(byKey('install-hint'), findsOneWidget);
          expect(save.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(app.sessions.addressUpdates, [
            (testClientId, 'Via Pignolo 5, 24121 Bergamo'),
          ]);
          expect(byKey('client-address-dialog'), findsNothing);
        },
        variant: platforms,
      );
    }
  }
}
