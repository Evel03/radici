// Textos con espacios que no cortan (U+00A0): la app los usa para que un
// renglón no se parta en medio de una hora o de una fecha («fino alle» /
// «13:00»). Los tests comparan con espacios comunes, que se leen mejor; las
// reglas de dónde se parte tienen sus propios tests.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// El espacio que no corta.
final String nbsp = String.fromCharCode(0xA0);

/// [text] con los espacios que no cortan como espacios comunes.
String plainSpaces(String text) => text.replaceAll(nbsp, ' ');

/// Los Text cuyo texto, con espacios comunes, es [text].
Finder findPlainText(String text) => find.byWidgetPredicate(
  (widget) => widget is Text && plainSpaces(widget.data ?? '') == text,
  description: 'texto «$text» (con espacios comunes)',
);
