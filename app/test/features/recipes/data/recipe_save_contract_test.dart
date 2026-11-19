// El contrato entre la app y save_recipe, leído de las migraciones (como
// quote_vectors.json une los tests de TS y de Dart). save_recipe rechaza una
// clave que no conoce, pero eso pasa en la base: sin este test, una clave
// cambiada de un solo lado (en recipeSavePayload y su test, o en la función y
// el pgTAP) dejaría todas las suites en verde y fallaría recién al guardar.
// También compara la dieta contra los alérgenos, que la app avisa antes de
// guardar y la base rechaza.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/recipe_fixtures.dart';
import '../../../support/repo_files.dart';

final RegExp _definition = RegExp(r'create (or replace )?function public\.save_recipe\(');

/// La última definición de save_recipe en las migraciones: la que queda
/// desplegada.
String _saveRecipeSource() {
  final supabase = findRepoFile('supabase/config.toml').parent;
  final migrations = Directory('${supabase.path}${Platform.pathSeparator}migrations')
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.sql'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final sources = [
    for (final file in migrations)
      if (_definition.hasMatch(file.readAsStringSync())) file.readAsStringSync(),
  ];
  if (sources.isEmpty) throw StateError('Ninguna migración define save_recipe');
  final sql = sources.last;
  final start = sql.lastIndexOf(_definition);
  return sql.substring(start, sql.indexOf(r'$$;', start));
}

/// Los textos entre comillas de [pattern] (un arreglo de SQL).
Set<String> _quoted(String source, RegExp pattern) {
  final match = pattern.firstMatch(source);
  if (match == null) throw StateError('No está ${pattern.pattern} en save_recipe');
  return {for (final m in RegExp("'([a-z_]+)'").allMatches(match.group(1)!)) m.group(1)!};
}

Set<String> _constant(String source, String name) =>
    _quoted(source, RegExp('${RegExp.escape(name)} constant text\\[\\] := array\\[([^\\]]*)\\]'));

Set<String> _excludedByDiet(String source, String diet) =>
    _quoted(source, RegExp("r\\.diet = '$diet'\\s+and v_allergens && array\\[([^\\]]*)\\]"));

void main() {
  final source = _saveRecipeSource();
  final payload = recipeSavePayload(lasagne());

  test('cada clave que manda la app la conoce save_recipe, y viceversa salvo active, catalog_visible y las descripciones', () {
    final keys = _constant(source, 'c_keys');
    expect(keys.containsAll(payload.keys), isTrue, reason: '${payload.keys.toSet().difference(keys)}');
    // La app no manda nunca active ni catalog_visible: guardar no reactiva un
    // plato ni pasa una receta de evento al catálogo. Las descripciones del
    // menú de la web (migración 20261119150000_menu_web.sql) las manda el
    // editor desde el PR de la app del menú, que las saca de esta lista.
    expect(keys.difference(payload.keys.toSet()), {
      'active',
      'catalog_visible',
      'description_it',
      'description_es',
      'description_en',
    });
  });

  test('las claves de cada ingrediente son las de save_recipe', () {
    final keys = _constant(source, 'c_ingredient_keys');
    final ingredients = payload['ingredients']! as List<Object?>;
    expect(ingredients, isNotEmpty);
    for (final ingredient in ingredients) {
      expect((ingredient! as Map<String, Object?>).keys.toSet(), keys);
    }
  });

  test('la dieta contra los alérgenos es la misma regla en la app y en save_recipe', () {
    for (final diet in Diet.values) {
      expect(
        {for (final allergen in allergensExcludedByDiet[diet]!) allergen.name},
        _excludedByDiet(source, diet.name),
        reason: diet.name,
      );
    }
  });
}
