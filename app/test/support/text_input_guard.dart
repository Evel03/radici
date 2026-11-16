// Guardián de los campos de texto: en el iPhone (Safari y la app agregada a
// la pantalla de inicio), un campo con letra de menos de 16 px hace que iOS
// agrande la página al enfocarlo, y Evelyn queda con la pantalla corrida.
// Flutter web le pasa al campo nativo el tamaño de su EditableText.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tamaño mínimo de la letra de un campo de texto para que iOS no haga zoom.
const double minReadableInputFontSize = 16;

/// Exige que haya al menos un campo en pantalla y que todos tengan letra de
/// 16 px o más.
void expectReadableInputs(WidgetTester tester) {
  final fields = tester.widgetList<EditableText>(find.byType(EditableText));
  expect(fields, isNotEmpty, reason: 'no hay ningún campo de texto en pantalla');
  for (final field in fields) {
    expect(
      field.style.fontSize,
      greaterThanOrEqualTo(minReadableInputFontSize),
      reason: 'un campo con letra de menos de 16 px hace zoom en iOS',
    );
  }
}
