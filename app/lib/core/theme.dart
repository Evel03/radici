// Tema Material 3 con semilla cálida (terracota) y tipografía del sistema.
import 'package:flutter/material.dart';
import 'package:radici/core/brand_mark_geometry.dart';

/// Terracota: color semilla del tema, el mismo de la marca y los íconos.
const Color brandSeedColor = Color(brandTerracotta);

/// Tamaño mínimo de los objetivos táctiles (pautas de Android e iOS).
const double minTapTarget = 48;

ThemeData buildLightTheme() => _buildTheme(Brightness.light);

ThemeData buildDarkTheme() => _buildTheme(Brightness.dark);

ThemeData _buildTheme(Brightness brightness) {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: brandSeedColor,
    brightness: brightness,
  );
  const buttonMinimumSize = Size(minTapTarget, minTapTarget);

  return ThemeData(
    colorScheme: colorScheme,
    // Mobile first: densidad estándar y objetivos táctiles de 48 dp también
    // en escritorio o en tests.
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: buttonMinimumSize),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: buttonMinimumSize),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: buttonMinimumSize),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
  );
}
