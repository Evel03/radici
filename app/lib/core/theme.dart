// Tema con la identidad de Radici (la misma de la web): paleta del manual de
// marca, títulos en Cormorant Garamond y esquinas casi rectas. El texto chico
// (listas, formularios, botones) sigue en la letra del sistema (Roboto en
// Android y en la web, San Francisco en iOS): la app es una herramienta de
// trabajo y así se lee mejor en el teléfono. El logotipo (Cinzel) está en
// core/radici_logo.dart.
import 'package:flutter/material.dart';
import 'package:radici/core/brand.dart';

/// Oliva: color semilla del tema, el mismo de la marca y de los íconos.
const Color brandSeedColor = Color(brandOlive);

/// Tamaño mínimo de los objetivos táctiles (pautas de Android e iOS).
const double minTapTarget = 48;

ThemeData buildLightTheme() => _buildTheme(_lightScheme());

ThemeData buildDarkTheme() => _buildTheme(_darkScheme());

/// Modo claro con los colores de la web: fondo crema, tarjetas crema clara,
/// bordes lino, texto tinta; oliva para lo principal y terra para lo que
/// tiene que ver con restricciones (íconos y etiquetas). El resto de los roles
/// sale de la semilla oliva.
ColorScheme _lightScheme() =>
    ColorScheme.fromSeed(
      seedColor: brandSeedColor,
      brightness: Brightness.light,
    ).copyWith(
      primary: const Color(brandOlive),
      onPrimary: const Color(brandCream),
      primaryContainer: const Color(brandOliveTint),
      onPrimaryContainer: const Color(brandOliveDark),
      tertiary: const Color(brandTerraInk),
      onTertiary: const Color(brandCream),
      tertiaryContainer: const Color(brandTerraTint),
      onTertiaryContainer: const Color(brandTerraDeep),
      error: const Color(brandError),
      onError: const Color(brandCream),
      errorContainer: const Color(brandErrorTint),
      onErrorContainer: const Color(brandErrorDeep),
      surface: const Color(brandCream),
      onSurface: const Color(brandInk),
      onSurfaceVariant: const Color(brandMuted),
      surfaceTint: const Color(brandOlive),
      surfaceBright: const Color(brandCreamLight),
      surfaceDim: const Color(0xFFE3D6C3),
      surfaceContainerLowest: const Color(brandCreamLight),
      surfaceContainerLow: const Color(0xFFF8F2E9),
      surfaceContainer: const Color(0xFFF2E9DC),
      surfaceContainerHigh: const Color(brandCreamDark),
      surfaceContainerHighest: const Color(0xFFE7DAC8),
      outline: const Color(brandTerra),
      outlineVariant: const Color(brandLinen),
      inverseSurface: const Color(brandInk),
      onInverseSurface: const Color(brandCream),
    );

/// Modo oscuro (la web no tiene): los tonos que Material deriva de la semilla
/// oliva, y la familia terra para el terciario, como en el claro.
ColorScheme _darkScheme() {
  final terra = ColorScheme.fromSeed(
    seedColor: const Color(brandTerra),
    brightness: Brightness.dark,
  );
  return ColorScheme.fromSeed(
    seedColor: brandSeedColor,
    brightness: Brightness.dark,
  ).copyWith(
    tertiary: terra.primary,
    onTertiary: terra.onPrimary,
    tertiaryContainer: terra.primaryContainer,
    onTertiaryContainer: terra.onPrimaryContainer,
  );
}

/// Títulos en Cormorant Garamond, como los de la web. Tiene menos altura de x
/// que Roboto: va un poco más grande para leerse igual. Números de caja alta
/// (los de estilo antiguo confunden el 1 con una i en fechas) y Roboto para
/// cualquier letra que la fuente no tenga (en la web no hay otra de respaldo).
TextTheme _serifTitles() {
  TextStyle serif(double size, {double height = 1.2}) => TextStyle(
    fontFamily: brandSerifFont,
    fontFamilyFallback: const ['Roboto'],
    fontSize: size,
    height: height,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    fontFeatures: const [FontFeature.liningFigures()],
  );
  return TextTheme(
    displayLarge: serif(62, height: 1.1),
    displayMedium: serif(50, height: 1.1),
    displaySmall: serif(40, height: 1.15),
    headlineLarge: serif(36),
    headlineMedium: serif(31),
    headlineSmall: serif(27),
    titleLarge: serif(24),
  );
}

ThemeData _buildTheme(ColorScheme colorScheme) {
  const buttonMinimumSize = Size(minTapTarget, minTapTarget);
  // Esquinas casi rectas, como en la web.
  final corners = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(4),
  );
  final light = colorScheme.brightness == Brightness.light;

  return ThemeData(
    colorScheme: colorScheme,
    textTheme: _serifTitles(),
    // Mobile first: densidad estándar y objetivos táctiles de 48 dp también
    // en escritorio o en tests.
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: buttonMinimumSize,
        shape: corners,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: buttonMinimumSize,
        shape: corners,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: buttonMinimumSize,
        shape: corners,
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
    // Tarjetas como los paneles de la web: planas, con borde lino; en claro,
    // crema clara sobre el fondo crema.
    cardTheme: CardThemeData(
      elevation: 0,
      color: light
          ? colorScheme.surfaceContainerLowest
          : colorScheme.surfaceContainerLow,
      shape: corners.copyWith(
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
    ),
    chipTheme: ChipThemeData(shape: corners),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  );
}
