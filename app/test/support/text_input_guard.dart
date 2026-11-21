// Guardián de los campos de texto: en el iPhone (Safari y la app agregada a
// la pantalla de inicio), un campo con letra de menos de 16 px hace que iOS
// agrande la página al enfocarlo, y Evelyn queda con la pantalla corrida.
// Flutter web le pasa al campo nativo el tamaño de su EditableText.
//
// También el autocompletar del navegador en los campos de una clienta: si el
// mensaje TextInput.setClient trae la clave `autofill`, Flutter web arma un
// `<input autocomplete="on">` dentro de un `<form>`, y Safari puede ofrecer
// el teléfono o la dirección de Evelyn. Esa clave viene siempre que
// `autofillHints` no sea null, también con el valor por defecto de TextField
// (una lista vacía): para apagarlo hay que pasar `autofillHints: null`.
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

/// Enfoca [field] tocándolo y exige que al motor no le pida autocompletar
/// (sin la clave `autofill` en TextInput.setClient). Con [tap] en false, lo
/// toma del campo que ya tiene el foco (un diálogo con autofocus).
Future<void> expectNoBrowserAutofill(
  WidgetTester tester,
  Finder field, {
  bool tap = true,
}) async {
  if (tap) {
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    tester.testTextInput.log.clear();
    await tester.tap(field);
    await tester.pumpAndSettle();
  }
  final setClient = tester.testTextInput.log.lastWhere(
    (call) => call.method == 'TextInput.setClient',
    orElse: () => fail('el campo $field no se enfocó'),
  );
  final config = (setClient.arguments as List<Object?>)[1]! as Map;
  expect(
    config.containsKey('autofill'),
    isFalse,
    reason:
        '$field pide autocompletar: en /gestione/ sale con '
        'autocomplete="on" (falta autofillHints: null)',
  );
}
