// Con las fuentes reales (Roboto y Cormorant Garamond, las de /gestione/ en el
// iPhone): «Aggiorna» del aviso de versión no queda pegado a lo que hay abajo.
// El caso más justo es «Salva» del calendario de «Blocca giorni» (pantalla
// completa), que arranca en el borde de arriba del diálogo: un toque un poco
// alto recargaría la página y se perdería el rango elegido.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/brand.dart';
import 'package:radici/core/browser.dart';
import 'package:radici/core/build_id.dart';
import 'package:radici/features/web_app/data/published_build_repository.dart';

import '../../../support/browser_fakes.dart';
import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';

void main() {
  setUpAll(() async {
    // En los tests las fuentes del pubspec no se cargan solas, y la letra de
    // los tests (cada letra es un cuadrado) no mide como la real.
    final roboto = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Roboto-Medium.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
    final serif = FontLoader(brandSerifFont)
      ..addFont(rootBundle.load('assets/fonts/CormorantGaramond-SemiBold.ttf'));
    await Future.wait([roboto.load(), serif.load()]);
  });

  for (final size in const [Size(375, 667), Size(390, 844)]) {
    testWidgets(
      '${size.width.toInt()}×${size.height.toInt()}: «Aggiorna» queda '
      'a 8 px o más de «Salva» del calendario de «Blocca giorni»',
      (tester) async {
        await pumpChefApp(
          tester,
          requests: FakeChefRequestsRepository(const []),
          location: '/agenda',
          size: size,
          overrides: [
            buildIdProvider.overrideWithValue('abc1234'),
            publishedBuildRepositoryProvider.overrideWithValue(
              FakePublishedBuildRepository('def5678'),
            ),
            browserProvider.overrideWithValue(FakeBrowser()),
          ],
        );
        final reload = find.byKey(const ValueKey('update-banner-reload'));
        expect(reload, findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('agenda-block-range')));
        await tester.pumpAndSettle();
        final picker = find.byType(DateRangePickerDialog);
        final saveLabel = MaterialLocalizations.of(tester.element(picker))
            .saveButtonLabel;
        final save = find.ancestor(
          of: find.descendant(of: picker, matching: find.text(saveLabel)),
          matching: find.byType(TextButton),
        );
        expect(save, findsOneWidget);

        expect(
          tester.getRect(save).top - tester.getRect(reload).bottom,
          greaterThanOrEqualTo(8),
        );
      },
    );
  }
}
