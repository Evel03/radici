// Catálogo de platos de la cocinera: la lista, la búsqueda y los cambios.
// Guardar deja el plato en la lista con lo que se mandó (sin volver a leer);
// desactivar o reactivar se ve enseguida y vuelve atrás si el servidor falla.
// Entre dos dispositivos alcanza con deslizar para actualizar (sin Realtime).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/recipes/data/recipes_repository.dart';
import 'package:radici/features/recipes/domain/recipe.dart';

final recipeCatalogProvider =
    AsyncNotifierProvider<RecipeCatalogController, List<Recipe>>(
      RecipeCatalogController.new,
    );

/// Lo que se escribe en la búsqueda de la lista. Vuelve a vacío al salir de
/// la lista.
final recipeSearchQueryProvider =
    NotifierProvider.autoDispose<RecipeSearchQuery, String>(
      RecipeSearchQuery.new,
    );

class RecipeSearchQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String query) => state = query;
}

/// La lista ordenada y filtrada por la búsqueda.
final recipeCatalogViewProvider =
    Provider.autoDispose<AsyncValue<RecipeCatalogView>>((ref) {
      final query = ref.watch(recipeSearchQueryProvider);
      return ref
          .watch(recipeCatalogProvider)
          .whenData((recipes) => recipeCatalogView(recipes, query: query));
    });

/// Un plato recién guardado en el editor. `untranslated`: se guardó sin
/// traducir porque la traducción automática está apagada.
typedef SavedRecipeNotice = ({Recipe recipe, bool untranslated});

/// El plato recién guardado en el editor, para que la lista lo avise con su
/// botón flotante a la vista (el editor tapa la lista y se cierra al
/// guardar). La lista lo muestra y lo limpia.
final recipeSavedNoticeProvider =
    NotifierProvider<RecipeSavedNotice, SavedRecipeNotice?>(
      RecipeSavedNotice.new,
    );

class RecipeSavedNotice extends Notifier<SavedRecipeNotice?> {
  @override
  SavedRecipeNotice? build() => null;

  void post(Recipe recipe, {bool untranslated = false}) =>
      state = (recipe: recipe, untranslated: untranslated);

  void clear() => state = null;
}

class RecipeCatalogController extends AsyncNotifier<List<Recipe>> {
  RecipesRepository get _repository => ref.read(recipesRepositoryProvider);

  String? get _chefId => ref.read(currentChefProvider)?.chefId;

  /// Suma uno cuando un cambio empieza y otro cuando termina: si cambió
  /// mientras se leía, la lectura puede ser de antes del cambio.
  int _changes = 0;

  /// Cambios que todavía esperan al servidor.
  int _changesInFlight = 0;

  @override
  Future<List<Recipe>> build() async {
    final chefId = ref.watch(
      currentChefProvider.select((chef) => chef?.chefId),
    );
    if (chefId == null) return const [];
    return ref.watch(recipesRepositoryProvider).fetchCatalog(chefId: chefId);
  }

  /// Vuelve a leer todo (deslizar para actualizar). Una lectura que se cruzó
  /// con un cambio puede ser de antes de que el servidor lo guardara: se
  /// descarta y se lee una vez más; si esa también se cruza, queda lo local.
  /// Si falla, queda lo que había y se relanza [RecipesFailure].
  Future<void> refresh() async {
    final chefId = _chefId;
    if (chefId == null) return;
    for (var attempt = 0; attempt < 2; attempt++) {
      final changes = _changes;
      final fresh = await _repository.fetchCatalog(chefId: chefId);
      if (!ref.mounted) return;
      if (_changesInFlight == 0 && changes == _changes) {
        state = AsyncData(fresh);
        return;
      }
    }
  }

  /// Guarda [recipe] entero y lo deja en la lista. Guardar no cambia si está
  /// activo: el plato de la lista conserva su estado. Devuelve el plato como
  /// quedó. Si falla, la lista no cambia y se relanza [RecipesFailure].
  Future<Recipe> save(Recipe recipe) async {
    final saved = await _change(() async {
      await _repository.save(recipe);
      final current = _find(recipe.id);
      return current == null ? recipe : recipe.copyWith(active: current.active);
    });
    if (ref.mounted) _put(saved);
    return saved;
  }

  /// Activa o desactiva el plato [id]. Se ve enseguida; si falla, vuelve a
  /// como estaba y se relanza [RecipesFailure].
  Future<void> setActive(String id, {required bool active}) async {
    final chefId = _chefId;
    final current = _find(id);
    if (chefId == null || current == null || current.active == active) return;
    await _change(() async {
      _put(current.copyWith(active: active));
      try {
        await _repository.setActive(chefId: chefId, id: id, active: active);
      } on Object {
        if (ref.mounted) _put(current);
        rethrow;
      }
    });
  }

  Future<T> _change<T>(Future<T> Function() body) async {
    _changes++;
    _changesInFlight++;
    try {
      return await body();
    } finally {
      _changes++;
      _changesInFlight--;
    }
  }

  Recipe? _find(String id) {
    for (final recipe in state.value ?? const <Recipe>[]) {
      if (recipe.id == id) return recipe;
    }
    return null;
  }

  /// Pone [recipe] en la lista, en lugar del que tenga su id.
  void _put(Recipe recipe) {
    final current = state.value;
    if (current == null) return;
    final index = current.indexWhere((r) => r.id == recipe.id);
    state = AsyncData([
      if (index < 0) ...current else ...current.sublist(0, index),
      recipe,
      if (index >= 0) ...current.sublist(index + 1),
    ]);
  }
}
