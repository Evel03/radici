// Una fila de ingrediente del editor de platos: nombre, cantidad para 4
// porciones (teclado numérico, solo cifras), unidad (g, ml, piezas o «q.b.»,
// que no lleva cantidad) y sección del súper. Se reordena y se quita con
// botones a la vista: nada escondido en gestos.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_draft.dart';
import 'package:radici/features/recipes/presentation/recipe_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Cifras de la cantidad: hasta 100000.
const int _quantityDigits = 6;

/// Los campos de una fila. Viven mientras la fila está en el formulario y la
/// siguen al reordenar.
class IngredientRowControllers {
  IngredientRowControllers(IngredientDraft row)
    : name = TextEditingController(text: row.name),
      quantity = TextEditingController(text: row.quantity);

  final TextEditingController name;
  final TextEditingController quantity;
  final FocusNode nameFocus = FocusNode();

  /// «Siguiente» en el nombre lleva acá (si no, iría al botón de quitar, que
  /// es lo próximo en el orden de lectura, y el teclado se cerraría).
  final FocusNode quantityFocus = FocusNode();

  /// Para llevar la fila a la vista (al agregarla o si tiene un error).
  final GlobalKey anchor = GlobalKey();

  void dispose() {
    name.dispose();
    quantity.dispose();
    nameFocus.dispose();
    quantityFocus.dispose();
  }
}

class IngredientRow extends StatelessWidget {
  const IngredientRow({
    super.key,
    required this.row,
    required this.position,
    required this.count,
    required this.controllers,
    required this.errors,
    required this.onNameChanged,
    required this.onQuantityChanged,
    required this.onUnitChanged,
    required this.onSectionChanged,
    required this.onMove,
    required this.onRemove,
  });

  final IngredientDraft row;

  /// Lugar de la fila (desde 0) y cuántas hay: el primero no sube y el último
  /// no baja.
  final int position;
  final int count;
  final IngredientRowControllers controllers;

  /// Los errores de la fila, o null si no hay que mostrarlos.
  final IngredientDraftErrors? errors;
  final ValueChanged<String> onNameChanged;
  final ValueChanged<String> onQuantityChanged;
  final ValueChanged<UnitChoice> onUnitChanged;
  final ValueChanged<ShoppingSection> onSectionChanged;

  /// -1 sube la fila y 1 la baja.
  final ValueChanged<int> onMove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final key = row.key;
    final toTaste = row.unit == UnitChoice.toTaste;

    final nameError = switch (errors?.name) {
      null => null,
      TextError.required => l10n.recipeIngredientNameRequired,
      TextError.tooLong => l10n.recipeTextTooLong(maxIngredientNameLength),
    };
    final quantityError = switch (errors?.quantity) {
      null => null,
      QuantityError.required => l10n.recipeIngredientQuantityRequired,
      QuantityError.outOfRange => l10n.recipeIngredientQuantityRange(
        maxIngredientQuantity,
      ),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: KeyedSubtree(
        key: controllers.anchor,
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    key: ValueKey('recipe-ingredient-name-$key'),
                    controller: controllers.name,
                    focusNode: controllers.nameFocus,
                    textCapitalization: TextCapitalization.sentences,
                    // Con «q.b.» no hay cantidad que escribir: «Fine» cierra
                    // el teclado.
                    textInputAction: toTaste ? TextInputAction.done : TextInputAction.next,
                    onEditingComplete: toTaste ? null : controllers.quantityFocus.requestFocus,
                    onChanged: onNameChanged,
                    decoration: InputDecoration(
                      labelText: '${position + 1}. ${l10n.recipeIngredientName}',
                      errorText: nameError,
                      errorMaxLines: 2,
                    ),
                  ),
                ),
                IconButton(
                  key: ValueKey('recipe-ingredient-remove-$key'),
                  tooltip: l10n.recipeIngredientRemove,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: onRemove,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    key: ValueKey('recipe-ingredient-quantity-$key'),
                    controller: controllers.quantity,
                    focusNode: controllers.quantityFocus,
                    enabled: !toTaste,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(_quantityDigits),
                    ],
                    textInputAction: TextInputAction.done,
                    onChanged: onQuantityChanged,
                    decoration: InputDecoration(
                      labelText: l10n.recipeIngredientQuantity,
                      errorText: quantityError,
                      errorMaxLines: 3,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 128,
                  child: DropdownButtonFormField<UnitChoice>(
                    key: ValueKey('recipe-ingredient-unit-$key'),
                    initialValue: row.unit,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.recipeIngredientUnit,
                    ),
                    items: [
                      for (final unit in UnitChoice.values)
                        DropdownMenuItem(
                          value: unit,
                          child: Text(l10n.unitChoice(unit)),
                        ),
                    ],
                    onChanged: (unit) {
                      if (unit != null) onUnitChanged(unit);
                    },
                  ),
                ),
                // A la altura del botón de quitar de arriba.
                const SizedBox(width: 48),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<ShoppingSection>(
                    key: ValueKey('recipe-ingredient-section-$key'),
                    initialValue: row.section,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.recipeIngredientSection,
                    ),
                    items: [
                      for (final section in ShoppingSection.values)
                        DropdownMenuItem(
                          value: section,
                          child: Text(
                            l10n.shoppingSection(section),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (section) {
                      if (section != null) onSectionChanged(section);
                    },
                  ),
                ),
                IconButton(
                  key: ValueKey('recipe-ingredient-up-$key'),
                  tooltip: l10n.recipeIngredientMoveUp,
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: position > 0 ? () => onMove(-1) : null,
                ),
                IconButton(
                  key: ValueKey('recipe-ingredient-down-$key'),
                  tooltip: l10n.recipeIngredientMoveDown,
                  icon: const Icon(Icons.arrow_downward),
                  onPressed: position < count - 1 ? () => onMove(1) : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
