// El tema lleva la identidad de la marca (la de la web) y todos los pares de
// colores que usa la app tienen contraste suficiente (WCAG AA), en claro y en
// oscuro.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/brand.dart';
import 'package:radici/core/theme.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  test('modo claro: los colores de la web', () {
    final scheme = buildLightTheme().colorScheme;
    expect(scheme.primary, const Color(brandOlive));
    expect(scheme.onPrimary, const Color(brandCream));
    expect(scheme.surface, const Color(brandCream));
    expect(scheme.surfaceContainerLowest, const Color(brandCreamLight));
    expect(scheme.onSurface, const Color(brandInk));
    expect(scheme.outline, const Color(brandTerra));
    expect(scheme.outlineVariant, const Color(brandLinen));
    // Las tarjetas, como los paneles de la web: crema clara con borde lino.
    final card = buildLightTheme().cardTheme;
    expect(card.color, const Color(brandCreamLight));
    expect(card.elevation, 0);
  });

  test('títulos en Cormorant Garamond con números de caja alta; el resto, del sistema', () {
    final text = buildLightTheme().textTheme;
    for (final style in [
      text.displayLarge,
      text.headlineLarge,
      text.headlineMedium,
      text.headlineSmall,
      text.titleLarge,
    ]) {
      expect(style?.fontFamily, brandSerifFont);
      expect(style?.fontWeight, FontWeight.w600);
      expect(style?.fontFeatures, contains(const FontFeature.liningFigures()));
      expect(style?.fontFamilyFallback, ['Roboto']);
    }
    for (final style in [text.titleMedium, text.bodyLarge, text.labelLarge]) {
      expect(style?.fontFamily, isNot(brandSerifFont));
    }
  });

  for (final (name, build) in [
    ('claro', buildLightTheme),
    ('oscuro', buildDarkTheme),
  ]) {
    test('modo $name: contraste de los pares de colores que usa la app', () {
      final s = build().colorScheme;
      // Texto: 4,5:1 (AA).
      for (final (label, fg, bg) in [
        ('texto', s.onSurface, s.surface),
        ('texto secundario', s.onSurfaceVariant, s.surface),
        ('texto secundario en barras', s.onSurfaceVariant, s.surfaceContainer),
        ('iniciales y aviso', s.onSurfaceVariant, s.surfaceContainerHighest),
        ('links y botones de texto', s.primary, s.surface),
        ('botón principal', s.onPrimary, s.primary),
        ('pedido nuevo', s.onPrimaryContainer, s.primaryContainer),
        // La tarjeta del día de hoy (agenda) pinta texto, secundario y el
        // ícono de restricciones sobre secondaryContainer.
        ('día de hoy: texto', s.onSurface, s.secondaryContainer),
        ('día de hoy: secundario', s.onSurfaceVariant, s.secondaryContainer),
        ('día de hoy: restricciones', s.tertiary, s.secondaryContainer),
        ('restricciones', s.tertiary, s.surface),
        // Agenda: número de un día bloqueado (tachado) sobre su círculo, y el
        // botón tonal «Blocca questo giorno».
        ('día bloqueado', s.onSurface, s.surfaceContainerHighest),
        ('botón tonal', s.onSecondaryContainer, s.secondaryContainer),
        // En la semana, «Blocca»/«Sblocca» van con borde (texto primary)
        // también sobre la tarjeta de hoy.
        ('botón con borde en la tarjeta de hoy', s.primary, s.secondaryContainer),
        (
          'etiquetas de restricciones',
          s.onTertiaryContainer,
          s.tertiaryContainer,
        ),
        ('error', s.error, s.surface),
        ('sobre error', s.onError, s.error),
        ('aviso de error', s.onErrorContainer, s.errorContainer),
        ('snackbar', s.onInverseSurface, s.inverseSurface),
        // «Annulla» y «Riprova» del aviso (M3: inversePrimary).
        ('acción del aviso', s.inversePrimary, s.inverseSurface),
        ('texto en tarjetas', s.onSurface, build().cardTheme.color!),
        (
          'secundario en tarjetas',
          s.onSurfaceVariant,
          build().cardTheme.color!,
        ),
        // «Chiudi» del aviso de Safari (/gestione/), en su tarjeta.
        (
          'botones de texto en tarjetas',
          s.primary,
          build().cardTheme.color!,
        ),
        // El cartel de un día de la agenda es una tarjeta: nombre, renglón y
        // el punto de una sesión van en los pares de arriba; el de un pedido,
        // en terciario.
        (
          'punto de un pedido en el cartel del día',
          s.tertiary,
          build().cardTheme.color!,
        ),
      ]) {
        expect(
          _contrast(fg, bg),
          greaterThanOrEqualTo(4.5),
          reason: '$label: ${_contrast(fg, bg).toStringAsFixed(2)}:1',
        );
      }
      // Bordes de campos y botones: 3:1 (componentes de interfaz).
      expect(_contrast(s.outline, s.surface), greaterThanOrEqualTo(3));
    });
  }
}
