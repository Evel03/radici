// Agregar o cambiar un renglón de la lista de compras de una semana: qué
// (como un ingrediente), la cantidad entera en g, ml o piezas, o «q.b.» sin
// cantidad, y la sección del súper. Valida como la base (validateShoppingItem)
// antes de cerrar. Los nombres le llegan a la clienta traducidos solos a su
// idioma (decisión del 22/11/2026): el campo pide no escribir datos
// personales. Los campos tienen letra de 16 px (con menos, iOS agranda la
// página) y autofillHints: null (sin pasarlo, en /gestione/ Safari podría
// ofrecer datos de Evelyn).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_draft.dart';
import 'package:radici/features/recipes/presentation/recipe_labels.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Cifras de la cantidad: hasta 1.000.000.
const int _quantityDigits = 7;

/// Abre el diálogo: vacío para agregar, o con [initial] para cambiarlo.
/// [clientLanguage]: el idioma de la clienta, como se muestra («Italiano»).
/// Devuelve el renglón como quedó, o null si se canceló.
Future<ShoppingItem?> showShoppingItemDialog(
  BuildContext context, {
  required String clientLanguage,
  ShoppingItem? initial,
  ShoppingSection section = ShoppingSection.other,
}) => showDialog<ShoppingItem>(
  context: context,
  builder: (_) => ShoppingItemDialog(
    clientLanguage: clientLanguage,
    initial: initial,
    section: section,
  ),
);

class ShoppingItemDialog extends StatefulWidget {
  const ShoppingItemDialog({
    super.key,
    required this.clientLanguage,
    this.initial,
    this.section = ShoppingSection.other,
  });

  /// El idioma de la clienta, como se muestra («Italiano»): el nombre le
  /// llega traducido a ese idioma.
  final String clientLanguage;

  /// El renglón que se cambia; null para agregar uno.
  final ShoppingItem? initial;

  /// La sección de un renglón nuevo.
  final ShoppingSection section;

  @override
  State<ShoppingItemDialog> createState() => _ShoppingItemDialogState();
}

class _ShoppingItemDialogState extends State<ShoppingItemDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial?.name ?? '',
  );
  late final TextEditingController _quantity = TextEditingController(
    text: widget.initial?.amount?.quantity.toString() ?? '',
  );
  late UnitChoice _unit = widget.initial == null
      ? UnitChoice.g
      : UnitChoice.of(widget.initial!.amount);
  late ShoppingSection _section = widget.initial?.section ?? widget.section;
  bool _showErrors = false;

  @override
  void dispose() {
    _name.dispose();
    _quantity.dispose();
    super.dispose();
  }

  void _submit() {
    final item = shoppingItemFrom(
      name: _name.text,
      quantity: _quantity.text,
      unit: _unit,
      section: _section,
    );
    if (item == null) {
      setState(() => _showErrors = true);
      return;
    }
    Navigator.of(context).pop(item);
  }

  void _setUnit(UnitChoice unit) {
    // «q.b.» no lleva cantidad.
    if (unit == UnitChoice.toTaste) _quantity.clear();
    setState(() => _unit = unit);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final adding = widget.initial == null;
    // 16 px o más: con menos, iOS agranda la página al enfocar el campo.
    final field = Theme.of(context).textTheme.bodyLarge;
    final toTaste = _unit == UnitChoice.toTaste;
    final errors = _showErrors
        ? validateShoppingItem(
            name: _name.text,
            quantity: _quantity.text,
            unit: _unit,
          )
        : (name: null, quantity: null);
    final nameError = switch (errors.name) {
      null => null,
      TextError.required => l10n.recipeIngredientNameRequired,
      TextError.tooLong => l10n.recipeTextTooLong(maxShoppingItemNameLength),
    };
    final quantityError = switch (errors.quantity) {
      null => null,
      QuantityError.required => l10n.recipeIngredientQuantityRequired,
      QuantityError.outOfRange => l10n.recipeIngredientQuantityRange(
        maxShoppingQuantity,
      ),
    };

    // Como en el diálogo de la dirección: el alto del teclado se descuenta
    // acá y el campo enfocado queda a la vista.
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: AlertDialog(
          key: const ValueKey('shopping-item-dialog'),
          alignment: Alignment.topCenter,
          scrollable: true,
          title: Text(
            adding ? l10n.weekMenuItemAdd : l10n.weekMenuItemEditTitle,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('shopping-item-name'),
                controller: _name,
                autofocus: adding,
                autofillHints: null,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: toTaste
                    ? TextInputAction.done
                    : TextInputAction.next,
                onChanged: (_) {
                  if (_showErrors) setState(() {});
                },
                onSubmitted: toTaste ? (_) => _submit() : null,
                style: field,
                decoration: InputDecoration(
                  labelText: l10n.recipeIngredientName,
                  helperText: l10n.shoppingItemNameHelper(
                    widget.clientLanguage,
                  ),
                  helperMaxLines: 3,
                  errorText: nameError,
                  errorMaxLines: 2,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('shopping-item-quantity'),
                      controller: _quantity,
                      enabled: !toTaste,
                      autofillHints: null,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(_quantityDigits),
                      ],
                      textInputAction: TextInputAction.done,
                      onChanged: (_) {
                        if (_showErrors) setState(() {});
                      },
                      onSubmitted: (_) => _submit(),
                      style: field,
                      decoration: InputDecoration(
                        labelText: l10n.recipeIngredientQuantity,
                        errorText: quantityError,
                        errorMaxLines: 3,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 120,
                    child: DropdownButtonFormField<UnitChoice>(
                      key: const ValueKey('shopping-item-unit'),
                      initialValue: _unit,
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
                        if (unit != null) _setUnit(unit);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ShoppingSection>(
                key: const ValueKey('shopping-item-section'),
                initialValue: _section,
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
                  if (section != null) setState(() => _section = section);
                },
              ),
            ],
          ),
          actionsOverflowButtonSpacing: 8,
          actions: [
            TextButton(
              key: const ValueKey('shopping-item-cancel'),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.actionCancel),
            ),
            FilledButton(
              key: const ValueKey('shopping-item-save'),
              onPressed: _submit,
              child: Text(adding ? l10n.weekMenuItemAdd : l10n.actionSave),
            ),
          ],
        ),
      ),
    );
  }
}
