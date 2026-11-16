// Catálogo de platos de la cocinera en Supabase (migración
// 20261116170000_recipe_catalog.sql). La RLS ya limita las filas a las de su
// chef_id; el filtro explícito es para el índice y para cuando haya más de una
// cocinera.
//
// Un plato se guarda entero con save_recipe (receta, alérgenos e ingredientes
// en una transacción); nunca se escriben alérgenos ni ingredientes sueltos.
// Desactivar o reactivar es un update de `active`. Nada de esto se loguea: las
// notas son de la cocinera.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/supabase_client.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract interface class RecipesRepository {
  /// Los platos del catálogo de la cocinera, activos y desactivados (no las
  /// recetas de un evento, que no son del catálogo). Lanza [RecipesFailure].
  Future<List<Recipe>> fetchCatalog({required String chefId});

  /// Guarda [recipe] entero con save_recipe: si el id no existe lo crea. Un
  /// reintento con el mismo id no duplica. No cambia si está activo. Lanza
  /// [RecipesFailure].
  Future<void> save(Recipe recipe);

  /// Activa o desactiva el plato [id]. Lanza [RecipesFailure]
  /// ([RecipesFailureKind.notFound] si ya no existe).
  Future<void> setActive({
    required String chefId,
    required String id,
    required bool active,
  });
}

final recipesRepositoryProvider = Provider<RecipesRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null
      ? const _NoBackendRecipesRepository()
      : SupabaseRecipesRepository(client);
});

enum RecipesFailureKind {
  /// Sin conexión o error del servidor.
  unavailable,

  /// La base rechazó el plato (save_recipe: invalid_payload o un check). La
  /// app valida lo mismo antes de mandar: no debería pasar.
  invalid,

  /// El plato ya no existe, o es de otra cocinera.
  notFound,
}

class RecipesFailure implements Exception {
  const RecipesFailure(this.kind);

  final RecipesFailureKind kind;

  @override
  String toString() => 'RecipesFailure(${kind.name})';
}

class SupabaseRecipesRepository implements RecipesRepository {
  SupabaseRecipesRepository(this._client);

  final SupabaseClient _client;

  static const String _recipes = 'recipes';

  @override
  Future<List<Recipe>> fetchCatalog({required String chefId}) =>
      _guard(() async {
        final rows = await _client
            .from(_recipes)
            .select(recipeColumns)
            .eq('chef_id', chefId)
            .eq('catalog_visible', true)
            .order('name_it', ascending: true);
        return rows.map(Recipe.fromJson).toList();
      });

  @override
  Future<void> save(Recipe recipe) => _guard(
    () => _client.rpc<dynamic>(
      'save_recipe',
      params: {'p': recipeSavePayload(recipe)},
    ),
  );

  @override
  Future<void> setActive({
    required String chefId,
    required String id,
    required bool active,
  }) => _guard(() async {
    final updated = await _client
        .from(_recipes)
        .update({'active': active})
        .eq('chef_id', chefId)
        .eq('id', id)
        .select('id');
    if (updated.isEmpty) {
      throw const RecipesFailure(RecipesFailureKind.notFound);
    }
  });

  /// Traduce los errores de save_recipe (22023 invalid_payload, 23514 un
  /// check, P0002 recipe_not_found) y cualquier otro error de red, de
  /// PostgREST o de una fila rota a [RecipesFailure]. No se loguea el
  /// detalle: puede traer el plato.
  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on RecipesFailure {
      rethrow;
    } on PostgrestException catch (error) {
      throw RecipesFailure(switch (error.code) {
        '22023' || '23514' => RecipesFailureKind.invalid,
        'P0002' => RecipesFailureKind.notFound,
        _ => RecipesFailureKind.unavailable,
      });
    } on Object {
      throw const RecipesFailure(RecipesFailureKind.unavailable);
    }
  }
}

class _NoBackendRecipesRepository implements RecipesRepository {
  const _NoBackendRecipesRepository();

  static const _failure = RecipesFailure(RecipesFailureKind.unavailable);

  @override
  Future<List<Recipe>> fetchCatalog({required String chefId}) =>
      Future.error(_failure);

  @override
  Future<void> save(Recipe recipe) => Future.error(_failure);

  @override
  Future<void> setActive({
    required String chefId,
    required String id,
    required bool active,
  }) => Future.error(_failure);
}
