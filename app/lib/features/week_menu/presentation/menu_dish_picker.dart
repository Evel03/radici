// Elegir platos del catálogo para el menú de una semana, a pantalla completa:
// los activos que todavía no están en el menú, con búsqueda por nombre (en
// italiano, español o inglés), cada uno con su foto, sus alérgenos y, si choca
// con las alergias o la dieta de la reserva, la marca en rojo con el porqué.
// Se marcan varios y «Agregar N platos» los agrega juntos; «Nuevo plato» abre
// el editor de platos (el plato que se guarde ahí entra al menú) y los
// marcados entran igual. Solo muestra providers: la lógica está en
// menuPickerCandidates y dishConflict.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/recipes/application/recipe_catalog_controller.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/presentation/recipe_labels.dart';
import 'package:radici/features/recipes/presentation/recipe_photo_thumbnail.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart'
    show LoadErrorView;
import 'package:radici/features/week_menu/domain/week_menu.dart';
import 'package:radici/features/week_menu/presentation/week_menu_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Lo que se eligió en el selector.
sealed class MenuPickerResult {
  const MenuPickerResult();
}

/// Agregar estos platos, en el orden en que se marcaron.
final class AddPickedDishes extends MenuPickerResult {
  const AddPickedDishes(this.recipes);

  final List<Recipe> recipes;
}

/// Crear un plato nuevo (y agregarlo al menú cuando se guarde). [picked]:
/// los que ya estaban marcados, que se agregan igual.
final class CreateNewDish extends MenuPickerResult {
  const CreateNewDish([this.picked = const []]);

  final List<Recipe> picked;
}

/// Abre el selector. [chosen]: los platos que ya están en el menú;
/// [restrictions]: las de la reserva (null: sin marcar choques); [room]:
/// cuántos platos se pueden agregar todavía.
Future<MenuPickerResult?> showMenuDishPicker(
  BuildContext context, {
  required Set<String> chosen,
  required MenuRestrictions? restrictions,
  required int room,
}) => showDialog<MenuPickerResult>(
  context: context,
  builder: (_) => Dialog.fullscreen(
    child: MenuDishPicker(
      chosen: chosen,
      restrictions: restrictions,
      room: room,
    ),
  ),
);

class MenuDishPicker extends ConsumerStatefulWidget {
  const MenuDishPicker({
    super.key,
    required this.chosen,
    required this.restrictions,
    required this.room,
  });

  final Set<String> chosen;
  final MenuRestrictions? restrictions;
  final int room;

  @override
  ConsumerState<MenuDishPicker> createState() => _MenuDishPickerState();
}

class _MenuDishPickerState extends ConsumerState<MenuDishPicker> {
  final TextEditingController _search = TextEditingController();

  /// Los marcados, en el orden en que se marcaron.
  final List<Recipe> _picked = [];

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _isPicked(Recipe recipe) => _picked.any((r) => r.id == recipe.id);

  void _toggle(Recipe recipe) {
    setState(() {
      if (_isPicked(recipe)) {
        _picked.removeWhere((r) => r.id == recipe.id);
      } else if (_picked.length < widget.room) {
        _picked.add(recipe);
      }
    });
  }

  void _clearSearch() => setState(_search.clear);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final catalog = ref.watch(recipeCatalogProvider);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('menu-picker-close'),
          icon: const Icon(Icons.close),
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(l10n.weekMenuPickerTitle),
      ),
      body: catalog.when(
        data: _list,
        error: (_, _) => LoadErrorView(
          message: l10n.recipesLoadFailed,
          onRetry: () => ref.invalidate(recipeCatalogProvider),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
      bottomNavigationBar: _Bar(
        picked: _picked.length,
        // Con el menú lleno con lo marcado, el plato nuevo no entraría.
        onNewDish: _picked.length >= widget.room
            ? null
            : () => Navigator.of(context).pop(CreateNewDish(List.of(_picked))),
        onAdd: _picked.isEmpty
            ? null
            : () =>
                  Navigator.of(context).pop(AddPickedDishes(List.of(_picked))),
      ),
    );
  }

  Widget _list(List<Recipe> recipes) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final language = Localizations.localeOf(context).languageCode;
    final query = _search.text;
    final candidates = menuPickerCandidates(
      recipes,
      chosen: widget.chosen,
      languageCode: language,
      query: query,
    );
    final restrictions = widget.restrictions;
    DishConflict conflictOf(Recipe recipe) => restrictions == null
        ? const DishConflict()
        : dishConflict(recipe, restrictions);
    final anyConflict = candidates.any((r) => conflictOf(r).isNotEmpty);
    final full = _picked.length >= widget.room;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                key: const ValueKey('menu-picker-search'),
                controller: _search,
                autofillHints: null,
                onChanged: (_) => setState(() {}),
                textInputAction: TextInputAction.search,
                style: theme.textTheme.bodyLarge,
                decoration: InputDecoration(
                  hintText: l10n.recipesSearchHint,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          key: const ValueKey('menu-picker-search-clear'),
                          tooltip: l10n.recipesSearchClear,
                          icon: const Icon(Icons.close),
                          onPressed: _clearSearch,
                        ),
                ),
              ),
            ),
            if (anyConflict)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(
                  l10n.weekMenuPickerConflicts,
                  key: const ValueKey('menu-picker-conflicts'),
                  style: muted,
                ),
              ),
            if (full)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    l10n.weekMenuMaxDishes(maxMenuDishes),
                    key: const ValueKey('menu-picker-full'),
                    style: muted,
                  ),
                ),
              ),
            Expanded(
              child: candidates.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        query.trim().isEmpty
                            ? l10n.weekMenuPickerEmpty
                            : l10n.recipesNoMatches(query.trim()),
                        key: const ValueKey('menu-picker-empty'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge,
                      ),
                    )
                  : ListView(
                      key: const ValueKey('menu-picker-list'),
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        for (final recipe in candidates)
                          _Candidate(
                            recipe: recipe,
                            name: recipeNameIn(recipe, language),
                            conflict: conflictOf(recipe),
                            picked: _isPicked(recipe),
                            enabled: _isPicked(recipe) || !full,
                            onTap: () => _toggle(recipe),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Un plato que se puede agregar: la foto, el nombre, lo que choca (en rojo)
/// o sus alérgenos, y la casilla.
class _Candidate extends StatelessWidget {
  const _Candidate({
    required this.recipe,
    required this.name,
    required this.conflict,
    required this.picked,
    required this.enabled,
    required this.onTap,
  });

  final Recipe recipe;
  final String name;
  final DishConflict conflict;
  final bool picked;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final photoId = recipe.photoId;
    final clashes = conflict.isNotEmpty;
    final detail = clashes
        ? l10n.dishConflictText(conflict)
        : recipe.allergens.isEmpty
        ? l10n.recipeNoAllergens
        : l10n.allergenList(recipe.allergens, separator: ' · ');
    return CheckboxListTile(
      key: ValueKey('menu-picker-${recipe.id}'),
      value: picked,
      onChanged: enabled ? (_) => onTap() : null,
      controlAffinity: ListTileControlAffinity.trailing,
      secondary: photoId == null
          ? null
          : RecipePhotoThumbnail(
              recipeId: recipe.id,
              photoId: photoId,
              size: 48,
            ),
      title: Text(name),
      subtitle: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (clashes) ...[
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: colors.error,
              ),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              detail,
              key: clashes
                  ? ValueKey('menu-picker-conflict-${recipe.id}')
                  : null,
              style: clashes
                  ? TextStyle(color: colors.error, fontWeight: FontWeight.w600)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// «Nuevo plato» y «Agregar N platos», abajo.
class _Bar extends StatelessWidget {
  const _Bar({
    required this.picked,
    required this.onNewDish,
    required this.onAdd,
  });

  final int picked;
  final VoidCallback? onNewDish;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.outlineVariant)),
        ),
        child: SafeArea(
          top: false,
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('menu-picker-new'),
                      onPressed: onNewDish,
                      icon: const Icon(Icons.add),
                      label: Text(l10n.recipeNew),
                    ),
                    FilledButton(
                      key: const ValueKey('menu-picker-add'),
                      onPressed: onAdd,
                      child: Text(l10n.weekMenuPickerAdd(picked)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
