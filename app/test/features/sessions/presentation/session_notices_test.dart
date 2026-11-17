// La hoja «Sposta», su calendario y su reloj, y el diálogo «Aggiungi
// indirizzo» en /gestione/ en Safari del iPhone, con una versión nueva
// publicada (arriba, el aviso de versión y la tarjeta de Safari), en un iPhone
// SE (375×548 con las barras de Safari) y en uno de 390×844 (390×664):
// - La hoja no tiene campos propios: con los dos avisos a la vista, «Sposta
//   a …» queda abajo, en el tercio inferior, y lo que dice la barra, a la
//   vista, sin desbordes (también con la semana ocupada, cuando la barra
//   dice por qué no se puede).
// - Mientras está abierto un diálogo (la dirección, el calendario de «Sposta»
//   o el reloj de «Altro orario») los avisos se esconden, y vuelven al
//   cerrarlo. Los diálogos van en el Navigator, debajo de los avisos: con los
//   dos a la vista, a 375×548 las filas del calendario medían 14 px (39 sin
//   avisos) y «OK» del reloj quedaba cortado, sin poder tocarse; con el reloj
//   en modo escritura, cerrar el teclado daba un error de layout en el primer
//   cuadro (a 390×664).
// - En el diálogo de la dirección, con el teclado abierto, el campo y «Salva»
//   quedan arriba del teclado, sin desbordes.
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

  void expectNotices({required bool shown}) {
    final matcher = shown ? findsOneWidget : findsNothing;
    expect(byKey('update-banner'), matcher);
    expect(byKey('install-hint'), matcher);
  }

  /// El día [n] del calendario abierto.
  Finder calendarDay(String n) => find
      .descendant(of: find.byType(DatePickerDialog), matching: find.text(n))
      .first;

  /// Alto de una fila del calendario abierto: del 3 al 10 del mes.
  double calendarRow(WidgetTester tester) =>
      tester.getCenter(calendarDay('10')).dy -
      tester.getCenter(calendarDay('3')).dy;

  /// El botón [label] del diálogo [dialog] abierto.
  Finder dialogButton(
    WidgetTester tester,
    Type dialog,
    String Function(MaterialLocalizations labels) label,
  ) {
    final finder = find.byType(dialog);
    final labels = MaterialLocalizations.of(tester.element(finder));
    return find.descendant(of: finder, matching: find.text(label(labels)));
  }

  /// La hoja «Sposta» con el 3/12 y, desde «Altro orario», el reloj.
  Future<void> openClock(
    WidgetTester tester, {
    required Size size,
    required Locale locale,
  }) async {
    await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      sessions: FakeSessionsRepository(buildBooking()),
      location: '/sessioni/${sessionId(2)}/sposta?data=2026-12-03',
      size: size,
      deviceLocales: [locale],
      overrides: notices(),
    );
    expectNotices(shown: true);
    await tester.ensureVisible(byKey('move-start-other'));
    await tester.pumpAndSettle();
    await tester.tap(byKey('move-start-other'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
  }

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
          expectNotices(shown: true);
          await tester.tap(byKey('session-add-address'));
          await tester.pumpAndSettle();
          expect(byKey('client-address-dialog'), findsOneWidget);
          expectNotices(shown: false);
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
          expectNotices(shown: false);
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

          // Al cerrar el teclado siguen escondidos (el diálogo sigue abierto),
          // sin desbordes; al guardar, el diálogo se cierra y vuelven.
          tester.view.resetViewInsets();
          await tester.pumpAndSettle();
          expectNotices(shown: false);
          expect(save.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(app.sessions.addressUpdates, [
            (testClientId, 'Via Pignolo 5, 24121 Bergamo'),
          ]);
          expect(byKey('client-address-dialog'), findsNothing);
          expectNotices(shown: true);
          expect(tester.takeException(), isNull);
        },
        variant: platforms,
      );
    }
  }

  for (final locale in const [Locale('it', 'IT'), Locale('es', 'ES')]) {
    testWidgets(
      'calendario de «Sposta» a 375×548 con los dos avisos: se esconden '
      'mientras está abierto, las filas miden lo mismo que sin avisos y el día '
      'y «OK» se pueden tocar; al elegir, la hoja con los avisos '
      '(${locale.languageCode})',
      (tester) async {
        Future<void> openCalendar(List<Override> overrides) async {
          await pumpChefApp(
            tester,
            requests: FakeChefRequestsRepository(const []),
            sessions: FakeSessionsRepository(buildBooking()),
            location: '/sessioni/${sessionId(2)}',
            size: const Size(375, 548),
            deviceLocales: [locale],
            overrides: overrides,
          );
          await tester.tap(byKey('session-move'));
          await tester.pumpAndSettle();
          expect(find.byType(DatePickerDialog), findsOneWidget);
        }

        // Sin avisos (fuera de /gestione/), para comparar.
        await openCalendar(const []);
        final rowWithoutNotices = calendarRow(tester);
        await tester.pumpWidget(const SizedBox());

        await openCalendar(notices());
        expectNotices(shown: false);
        expect(calendarRow(tester), moreOrLessEquals(rowWithoutNotices));
        expect(calendarDay('3').hitTestable(), findsOneWidget);
        final ok = dialogButton(
          tester,
          DatePickerDialog,
          (labels) => labels.okButtonLabel,
        );
        expect(ok.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(calendarDay('3'));
        await tester.pumpAndSettle();
        await tester.tap(ok);
        await tester.pumpAndSettle();
        expect(find.byType(MoveSessionScreen), findsOneWidget);
        expect(byKey('move-summary'), findsOneWidget);
        expectNotices(shown: true);
        expect(tester.takeException(), isNull);
      },
      variant: platforms,
    );

    testWidgets(
      'reloj de «Altro orario» a 375×548 con los dos avisos: se esconden '
      'mientras está abierto y «OK», «Annulla» y el botón para escribir la '
      'hora se pueden tocar; al cerrarlo vuelven (${locale.languageCode})',
      (tester) async {
        await openClock(tester, size: const Size(375, 548), locale: locale);
        expectNotices(shown: false);
        final ok = dialogButton(
          tester,
          TimePickerDialog,
          (labels) => labels.okButtonLabel,
        );
        expect(ok.hitTestable(), findsOneWidget);
        expect(
          dialogButton(
            tester,
            TimePickerDialog,
            (labels) => labels.cancelButtonLabel,
          ).hitTestable(),
          findsOneWidget,
        );
        final labels = MaterialLocalizations.of(
          tester.element(find.byType(TimePickerDialog)),
        );
        expect(
          find.byTooltip(labels.inputTimeModeButtonLabel).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        await tester.tap(ok);
        await tester.pumpAndSettle();
        expect(find.byType(TimePickerDialog), findsNothing);
        expect(find.byType(MoveSessionScreen), findsOneWidget);
        expectNotices(shown: true);
        expect(tester.takeException(), isNull);
      },
      variant: platforms,
    );

    for (final keyboard in const [260.0, 336.0]) {
      testWidgets(
        'reloj en modo escritura a 390×664 con los dos avisos y el teclado '
        '(${keyboard.toInt()}): al cerrar el teclado los avisos siguen '
        'escondidos, sin errores de layout, también si «OK» se toca con el '
        'teclado abierto; al cerrarse el reloj vuelven '
        '(${locale.languageCode})',
        (tester) async {
          await openClock(tester, size: const Size(390, 664), locale: locale);
          final clock = find.byType(TimePickerDialog);
          final labels = MaterialLocalizations.of(tester.element(clock));
          await tester.tap(find.byTooltip(labels.inputTimeModeButtonLabel));
          await tester.pumpAndSettle();
          final hour = find
              .descendant(of: clock, matching: find.byType(EditableText))
              .first;

          Future<void> openKeyboard() async {
            await tester.tap(hour);
            await tester.pump();
            tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expectNotices(shown: false);
          }

          await openKeyboard();
          // El primer cuadro con el teclado cerrado: ahí volvían los avisos y
          // al reloj le faltaba alto.
          tester.view.resetViewInsets();
          await tester.pump();
          expect(tester.takeException(), isNull);
          expectNotices(shown: false);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expectNotices(shown: false);

          // «OK» con el teclado abierto; el teclado se cierra mientras el
          // reloj se va.
          await openKeyboard();
          final ok = dialogButton(
            tester,
            TimePickerDialog,
            (labels) => labels.okButtonLabel,
          );
          expect(ok.hitTestable(), findsOneWidget);
          await tester.tap(ok);
          await tester.pump();
          tester.view.resetViewInsets();
          for (var frame = 0; frame < 20; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(tester.takeException(), isNull);
          }
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(clock, findsNothing);
          expect(find.byType(MoveSessionScreen), findsOneWidget);
          expectNotices(shown: true);
        },
        variant: platforms,
      );
    }
  }
}
