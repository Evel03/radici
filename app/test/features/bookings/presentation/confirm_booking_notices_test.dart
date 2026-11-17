// Hoja «Conferma prenotazione» en /gestione/ en Safari del iPhone, con una
// versión nueva publicada (arriba, el aviso de versión y la tarjeta de
// Safari) y el teclado abierto en el precio: en un iPhone SE (375×548 con las
// barras de Safari) y en uno de 390×844 (390×664), el campo que se escribe, el
// precio que se confirma y «Conferma» quedan a la vista arriba del teclado, sin
// desbordes. Con los avisos a la vista no entraban: los dos le quitan a todas
// las pantallas su alto, y la barra de la hoja (unos 128 px) más la barra de
// título no dejaban lugar; con el teclado abierto se esconden.
//
// También se esconden mientras está abierto el calendario de una semana o el
// reloj de «Altra ora», y vuelven al cerrarlo: los diálogos van en el
// Navigator, debajo de los avisos, y con los dos a la vista, a 375×548 las
// filas del calendario medían 14 px (39 sin avisos) y «OK» del reloj quedaba
// cortado, sin poder tocarse; con el reloj en modo escritura, cerrar el
// teclado daba un error de layout en el primer cuadro (a 390×664).
//
// Mide con las fuentes reales (con la letra de los tests, cada letra es un
// cuadrado y el texto mide de más). Va aparte porque las fuentes que se cargan
// valen para todo el archivo, y los demás tests de la hoja miden con la letra
// de los tests.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
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

  const platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.iOS,
  });

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

  /// La hoja de un pedido de 4 semanas desde el lunes 23/11, abierta con un
  /// enlace directo.
  Future<void> openSheet(
    WidgetTester tester, {
    required Size size,
    required Locale locale,
    List<Override> overrides = const [],
  }) async {
    await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([
        buildRequest(
          weeks: 4,
          preferredDate: CalendarDate(2026, 11, 23),
          estimate: fourWeeksEstimate,
          seenAt: testNow,
        ),
      ]),
      location: '/richieste/req-1/prenota',
      size: size,
      deviceLocales: [locale],
      overrides: overrides,
    );
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

  /// Desde la hoja ya abierta, el reloj de «Altra ora».
  Future<void> openClock(WidgetTester tester) async {
    await tester.ensureVisible(byKey('booking-start-other'));
    await tester.pumpAndSettle();
    await tester.tap(byKey('booking-start-other'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
  }

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

  for (final locale in const [Locale('it', 'IT'), Locale('es', 'ES')]) {
    testWidgets(
      'calendario de la primera semana a 375×548 con los dos avisos: se '
      'esconden mientras está abierto, las filas miden lo mismo que sin avisos '
      'y el día y «OK» se pueden tocar; al elegir vuelven '
      '(${locale.languageCode})',
      (tester) async {
        const size = Size(375, 548);
        Future<void> openCalendar() async {
          await tester.ensureVisible(byKey('booking-week-0'));
          await tester.pumpAndSettle();
          await tester.tap(byKey('booking-week-0'));
          await tester.pumpAndSettle();
          expect(find.byType(DatePickerDialog), findsOneWidget);
        }

        // Sin avisos (fuera de /gestione/), para comparar.
        await openSheet(tester, size: size, locale: locale);
        await openCalendar();
        final rowWithoutNotices = calendarRow(tester);
        await tester.pumpWidget(const SizedBox());

        await openSheet(
          tester,
          size: size,
          locale: locale,
          overrides: notices(),
        );
        expectNotices(shown: true);
        await openCalendar();
        expectNotices(shown: false);
        expect(calendarRow(tester), moreOrLessEquals(rowWithoutNotices));
        expect(calendarDay('24').hitTestable(), findsOneWidget);
        final ok = dialogButton(
          tester,
          DatePickerDialog,
          (labels) => labels.okButtonLabel,
        );
        expect(ok.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);

        // El martes 24/11 en lugar del lunes 23.
        await tester.tap(calendarDay('24'));
        await tester.pumpAndSettle();
        await tester.tap(ok);
        await tester.pumpAndSettle();
        expect(find.byType(DatePickerDialog), findsNothing);
        expect(
          find.descendant(
            of: byKey('booking-week-0'),
            matching: find.textContaining('24'),
          ),
          findsOneWidget,
        );
        expectNotices(shown: true);
        expect(tester.takeException(), isNull);
      },
      variant: platforms,
    );

    testWidgets(
      'reloj de «Altra ora» a 375×548 con los dos avisos: se esconden '
      'mientras está abierto y «OK» y «Annulla» se pueden tocar; al cerrarlo '
      'vuelven (${locale.languageCode})',
      (tester) async {
        await openSheet(
          tester,
          size: const Size(375, 548),
          locale: locale,
          overrides: notices(),
        );
        expectNotices(shown: true);
        await openClock(tester);
        expectNotices(shown: false);
        final ok = dialogButton(
          tester,
          TimePickerDialog,
          (labels) => labels.okButtonLabel,
        );
        expect(ok.hitTestable(), findsOneWidget);
        final cancel = dialogButton(
          tester,
          TimePickerDialog,
          (labels) => labels.cancelButtonLabel,
        );
        expect(cancel.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(cancel);
        await tester.pumpAndSettle();
        expect(find.byType(TimePickerDialog), findsNothing);
        expect(byKey('booking-confirm').hitTestable(), findsOneWidget);
        expectNotices(shown: true);
        expect(tester.takeException(), isNull);
      },
      variant: platforms,
    );

    testWidgets(
      'reloj en modo escritura a 390×664 con los dos avisos y el teclado '
      '(336): al cerrar el teclado los avisos siguen escondidos y no hay '
      'errores de layout; al cerrar el reloj vuelven (${locale.languageCode})',
      (tester) async {
        await openSheet(
          tester,
          size: const Size(390, 664),
          locale: locale,
          overrides: notices(),
        );
        await openClock(tester);
        final clock = find.byType(TimePickerDialog);
        final labels = MaterialLocalizations.of(tester.element(clock));
        await tester.tap(find.byTooltip(labels.inputTimeModeButtonLabel));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(of: clock, matching: find.byType(EditableText)).first,
        );
        await tester.pump();
        tester.view.viewInsets = const FakeViewPadding(bottom: 336);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        tester.view.resetViewInsets();
        await tester.pump();
        expect(tester.takeException(), isNull);
        expectNotices(shown: false);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await tester.tap(
          dialogButton(
            tester,
            TimePickerDialog,
            (labels) => labels.okButtonLabel,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(clock, findsNothing);
        expectNotices(shown: true);
      },
      variant: platforms,
    );
  }
}
