// El contrato entre la app y save_session_menu, leído de las migraciones (como
// recipe_save_contract_test.dart con save_recipe). La función rechaza una
// clave que no conoce, también dentro de un plato o un renglón, pero eso pasa
// en la base: sin este test, una clave cambiada de un solo lado dejaría todas
// las suites en verde y fallaría recién al guardar. También compara los topes
// de la app con los checks de las tablas y las secciones y unidades con los
// enums.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

import '../../../support/menu_fixtures.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/repo_files.dart';
import '../../../support/session_fixtures.dart';

final RegExp _definition = RegExp(
  r'create (or replace )?function public\.save_session_menu\(',
);

List<File> _migrations() {
  final supabase = findRepoFile('supabase/config.toml').parent;
  return Directory('${supabase.path}${Platform.pathSeparator}migrations')
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.sql'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// Todas las migraciones juntas, en orden.
String _allSql() =>
    [for (final file in _migrations()) file.readAsStringSync()].join('\n');

/// La última definición de save_session_menu en las migraciones: la que queda
/// desplegada.
String _saveSessionMenuSource() {
  final sources = [
    for (final file in _migrations())
      if (_definition.hasMatch(file.readAsStringSync()))
        file.readAsStringSync(),
  ];
  if (sources.isEmpty) {
    throw StateError('Ninguna migración define save_session_menu');
  }
  final sql = sources.last;
  final start = sql.lastIndexOf(_definition);
  return sql.substring(start, sql.indexOf(r'$$;', start));
}

/// Los textos entre comillas de la constante [name] (un arreglo de SQL).
Set<String> _constant(String source, String name) {
  // Los nombres van alineados con espacios: «c_keys      constant text[] :=».
  final match = RegExp(
    '\\b${RegExp.escape(name)}\\s+constant\\s+text\\[\\]\\s*:=\\s*array\\[([^\\]]*)\\]',
  ).firstMatch(source);
  if (match == null) throw StateError('No está $name en save_session_menu');
  return {
    for (final m in RegExp("'([a-z_]+)'").allMatches(match.group(1)!))
      m.group(1)!,
  };
}

/// Los valores de un enum de la base, en orden.
List<String> _enum(String sql, String name) {
  final match = RegExp('create type public\\.$name as enum \\(([^)]*)\\)')
      .firstMatch(sql);
  if (match == null) throw StateError('No está el enum $name');
  return [
    for (final m in RegExp("'([a-z_]+)'").allMatches(match.group(1)!))
      m.group(1)!,
  ];
}

void main() {
  final source = _saveSessionMenuSource();
  final payload = weekMenuSavePayload(
    WeekMenuSave(
      sessionId: sessionId(1),
      version: 1,
      note: 'Nota',
      allergensConfirmed: true,
      dishes: [WeekMenuDish(recipe: lasagne(), portions: 4)],
      items: lasagneList(4),
    ),
  );

  test(
    'las claves que manda la app son exactamente las de save_session_menu',
    () {
      expect(payload.keys.toSet(), _constant(source, 'c_keys'));
    },
  );

  test('las claves de cada plato son las de save_session_menu', () {
    final keys = _constant(source, 'c_dish_keys');
    final dishes = payload['dishes']! as List<Object?>;
    expect(dishes, isNotEmpty);
    for (final dish in dishes) {
      expect((dish! as Map<String, Object?>).keys.toSet(), keys);
    }
  });

  test('las claves de cada renglón son las de save_session_menu (también en un q.b.)', () {
    final keys = _constant(source, 'c_item_keys');
    final items = payload['items']! as List<Object?>;
    expect(
      items.any((i) => (i! as Map<String, Object?>)['quantity'] == null),
      isTrue,
    );
    for (final item in items) {
      expect((item! as Map<String, Object?>).keys.toSet(), keys);
    }
  });

  test('las secciones y las unidades son las de los enums de la base, en el mismo orden', () {
    final sql = _allSql();
    expect([
      for (final s in ShoppingSection.values) s.dbValue,
    ], _enum(sql, 'shopping_section'));
    expect([
      for (final u in IngredientUnit.values) u.name,
    ], _enum(sql, 'ingredient_unit'));
  });

  test('los topes de la app son los checks de las tablas', () {
    final sql = _allSql();
    bool has(String pattern) => RegExp(pattern).hasMatch(sql);
    expect(
      has('check \\(position between 1 and $maxMenuDishes\\)'),
      isTrue,
      reason: 'platos',
    );
    expect(
      has('check \\(portions between 1 and $maxDishPortions\\)'),
      isTrue,
      reason: 'porciones',
    );
    expect(
      has('check \\(position between 1 and $maxShoppingItems\\)'),
      isTrue,
      reason: 'renglones',
    );
    expect(
      has('check \\(quantity between 1 and $maxShoppingQuantity\\)'),
      isTrue,
      reason: 'cantidad',
    );
    expect(
      has('char_length\\(name\\) between 1 and $maxShoppingItemNameLength'),
      isTrue,
      reason: 'nombre',
    );
    expect(
      has('char_length\\(note\\) between 1 and $maxMenuNoteLength'),
      isTrue,
      reason: 'nota',
    );
  });
}
