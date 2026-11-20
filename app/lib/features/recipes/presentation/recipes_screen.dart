// Catálogo de platos de la cocinera: la lista con búsqueda (en los nombres en
// italiano, español e inglés), los activos primero y por nombre, cada uno con
// sus alérgenos, su dieta, su temporada y si sale en la web a la vista, y los
// desactivados al final. «Nuovo piatto» abre el editor. Solo muestra
// providers: la lógica está en RecipeCatalogController y en recipe.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/availability/presentation/availability_actions.dart';
import 'package:radici/features/recipes/application/recipe_catalog_controller.dart';
import 'package:radici/features/recipes/data/recipes_repository.dart';
import 'package:radici/features/recipes/data/translation_repository.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/presentation/recipe_labels.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart';
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

class RecipesScreen extends ConsumerStatefulWidget {
  const RecipesScreen({super.key});

  @override
  ConsumerState<RecipesScreen> createState() => _RecipesScreenState();
}

class _RecipesScreenState extends ConsumerState<RecipesScreen> {
  /// Avisos propios: así empujan hacia arriba el botón flotante en lugar de
  /// taparlo (con el de la app saldrían en el Scaffold de la barra).
  final GlobalKey<ScaffoldMessengerState> _messenger =
      GlobalKey<ScaffoldMessengerState>();

  late final TextEditingController _search;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(text: ref.read(recipeSearchQueryProvider));
    // Vuelta a la lista con el catálogo ya cargado: se actualiza sin mostrar
    // la carga (puede haber cambiado en otro dispositivo).
    if (ref.read(recipeCatalogProvider).hasValue) unawaited(_refreshQuietly());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _refreshQuietly() async {
    try {
      await ref.read(recipeCatalogProvider.notifier).refresh();
    } on RecipesFailure {
      // Queda lo que había; deslizar para actualizar lo vuelve a intentar.
    }
  }

  /// Deslizar para actualizar. Si falla, queda lo que había y se avisa.
  Future<void> _refresh() async {
    final message = AppLocalizations.of(context).inboxRefreshError;
    try {
      await ref.read(recipeCatalogProvider.notifier).refresh();
    } on RecipesFailure {
      _show(SnackBar(content: Text(message)));
    }
  }

  void _setQuery(String query) =>
      ref.read(recipeSearchQueryProvider.notifier).set(query);

  void _clearQuery() {
    _search.clear();
    _setQuery('');
  }

  void _show(SnackBar snackBar) {
    final messenger = _messenger.currentState;
    if (messenger == null) return;
    messenger
      ..removeCurrentSnackBar()
      ..showSnackBar(snackBar);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final view = ref.watch(recipeCatalogViewProvider);
    // El plato que se acaba de guardar en el editor (que ya se cerró).
    ref.listen<SavedRecipeNotice?>(recipeSavedNoticeProvider, (_, notice) {
      if (notice == null) return;
      final name = notice.recipe.nameIt;
      final because = notice.untranslatedBecause;
      // Guardado sin traducir: hay algo que hacer después (escribirlo o
      // volver a guardar), así que dura como los avisos de error del editor
      // y, con VoiceOver o TalkBack, se cierra con la X.
      final persist = because != null && MediaQuery.accessibleNavigationOf(context);
      _show(
        SnackBar(
          content: Text(switch (because) {
            null => l10n.recipeSavedDone(name),
            TranslationFailureKind.notConfigured => l10n.recipeSavedUntranslated(name),
            _ => l10n.recipeSavedUntranslatable(name),
          }),
          duration: because == null ? const Duration(seconds: 4) : errorSnackBarDuration,
          persist: persist,
          showCloseIcon: persist,
        ),
      );
      ref.read(recipeSavedNoticeProvider.notifier).clear();
    });
    final ready = view.hasValue && !view.hasError;

    return ScaffoldMessenger(
      key: _messenger,
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.recipesTitle)),
        body: view.when(
          data: _catalog,
          error: (_, _) => LoadErrorView(
            message: l10n.recipesLoadFailed,
            onRetry: () => ref.invalidate(recipeCatalogProvider),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
        ),
        floatingActionButton: ready
            ? FloatingActionButton.extended(
                key: const ValueKey('recipes-new'),
                onPressed: () => context.go(AppRoutes.recipeNew),
                icon: const Icon(Icons.add),
                label: Text(l10n.recipeNew),
              )
            : null,
      ),
    );
  }

  Widget _catalog(RecipeCatalogView view) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (view.total == 0) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          key: const ValueKey('recipes-empty'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(32, 48, 32, 96),
          children: [
            Icon(Icons.restaurant_menu, size: 48, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              l10n.recipesEmpty,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
          ],
        ),
      );
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                key: const ValueKey('recipes-search'),
                controller: _search,
                onChanged: _setQuery,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: l10n.recipesSearchHint,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          key: const ValueKey('recipes-search-clear'),
                          tooltip: l10n.recipesSearchClear,
                          icon: const Icon(Icons.close),
                          onPressed: _clearQuery,
                        ),
                ),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  key: const ValueKey('recipes-list'),
                  // Deslizar para actualizar aunque todo entre en la pantalla.
                  physics: const AlwaysScrollableScrollPhysics(),
                  // Abajo, lugar para el botón flotante: no tapa nada.
                  padding: const EdgeInsets.only(top: 4, bottom: 96),
                  children: [
                    if (view.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          children: [
                            Text(
                              l10n.recipesNoMatches(_search.text.trim()),
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyLarge,
                            ),
                            const SizedBox(height: 8),
                            TextButton(
                              key: const ValueKey('recipes-no-matches-clear'),
                              onPressed: _clearQuery,
                              child: Text(l10n.recipesSearchClear),
                            ),
                          ],
                        ),
                      ),
                    for (final recipe in view.active) ...[
                      _RecipeTile(recipe: recipe),
                      const Divider(height: 1, indent: 16),
                    ],
                    if (view.inactive.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                        child: Semantics(
                          header: true,
                          child: Text(
                            l10n.recipesInactiveSection(view.inactive.length),
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                      for (final recipe in view.inactive) ...[
                        _RecipeTile(recipe: recipe),
                        const Divider(height: 1, indent: 16),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Un plato de la lista: el nombre en italiano (el principal), el del idioma
/// de la interfaz si es otro, los alérgenos, la dieta, la temporada y, si
/// está activo, si sale en la web o le falta la descripción para salir.
class _RecipeTile extends StatelessWidget {
  const _RecipeTile({required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = RecipeFormats(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    final translation = switch (Localizations.localeOf(context).languageCode) {
      'es' => recipe.nameEs,
      'en' => recipe.nameEn,
      _ => null,
    };
    final allergens = recipe.allergens;
    final months = recipe.seasonMonths;
    final diet = recipe.diet;
    final season = months == null ? l10n.recipeAllYear : formats.season(months);
    final seasonLong = months == null
        ? l10n.recipeAllYear
        : formats.season(months, long: true);
    final web = switch (recipe.webStatus) {
      RecipeWebStatus.published => (
        icon: Icons.public,
        text: l10n.recipeOnWebsite,
      ),
      RecipeWebStatus.missingDescription => (
        icon: Icons.public_off,
        text: l10n.recipeNotOnWebsite,
      ),
      // Desactivado: ya lo dice la etiqueta de la derecha.
      RecipeWebStatus.inactive => null,
    };

    return ListTile(
      key: ValueKey('recipe-${recipe.id}'),
      onTap: () => context.go(AppRoutes.recipeEdit(recipe.id)),
      title: Text(
        recipe.nameIt,
        style: recipe.active ? null : TextStyle(color: muted),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (translation != null && translation != recipe.nameIt)
            Text(translation, style: const TextStyle(fontStyle: FontStyle.italic)),
          const SizedBox(height: 4),
          _DetailLine(
            icon: Icons.health_and_safety_outlined,
            iconColor: allergens.isEmpty ? muted : theme.colorScheme.tertiary,
            text: allergens.isEmpty
                ? l10n.recipeNoAllergens
                : l10n.allergenList(allergens, separator: ' · '),
            semanticsLabel: allergens.isEmpty
                ? l10n.recipeNoAllergens
                : l10n.recipeAllergensA11y(l10n.allergenList(allergens)),
          ),
          _DetailLine(
            icon: Icons.event_outlined,
            iconColor: muted,
            text: [if (diet != null) l10n.diet(diet), season].join(' · '),
            semanticsLabel: [
              if (diet != null) l10n.diet(diet),
              l10n.recipeSeasonA11y(seasonLong),
            ].join(', '),
          ),
          if (web != null)
            KeyedSubtree(
              key: ValueKey('recipe-web-${recipe.id}'),
              child: _DetailLine(
                icon: web.icon,
                iconColor: muted,
                text: web.text,
                semanticsLabel: web.text,
              ),
            ),
        ],
      ),
      trailing: recipe.active
          ? const Icon(Icons.chevron_right)
          : DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text(
                  l10n.recipeInactive,
                  style: theme.textTheme.labelSmall?.copyWith(color: muted),
                ),
              ),
            ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({
    required this.icon,
    required this.iconColor,
    required this.text,
    required this.semanticsLabel,
  });

  final IconData icon;
  final Color iconColor;
  final String text;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 16, color: iconColor),
          ),
          const SizedBox(width: 6),
          Expanded(child: Text(text, semanticsLabel: semanticsLabel)),
        ],
      ),
    );
  }
}
