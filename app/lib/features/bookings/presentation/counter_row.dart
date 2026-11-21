// Una fila con un contador: la etiqueta, − valor + (botones de 48 dp). La
// usan la hoja «Conferma prenotazione» (semanas, minutos, adultos, niños y
// días) y el formulario «Nuova cliente» (adultos y niños).
import 'package:flutter/material.dart';
import 'package:radici/l10n/app_localizations.dart';

class CounterRow extends StatelessWidget {
  const CounterRow({
    super.key,
    required this.keyPrefix,
    required this.label,
    required this.value,
    required this.onDecrement,
    required this.onIncrement,
  });

  /// Las claves de los botones y del valor: `<keyPrefix>-decrement`,
  /// `<keyPrefix>-value` y `<keyPrefix>-increment`.
  final String keyPrefix;
  final String label;
  final String value;

  /// null: deshabilitado (en el límite o mientras nada se puede cambiar).
  final VoidCallback? onDecrement;
  final VoidCallback? onIncrement;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            // El lector de pantalla lee "Settimane, 4" en un solo nodo.
            child: Semantics(
              value: value,
              child: Text(label, style: textTheme.titleMedium),
            ),
          ),
          IconButton.filledTonal(
            key: ValueKey('$keyPrefix-decrement'),
            tooltip: l10n.counterDecrease(label),
            onPressed: onDecrement,
            icon: const Icon(Icons.remove),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 72),
            child: ExcludeSemantics(
              child: Text(
                value,
                key: ValueKey('$keyPrefix-value'),
                textAlign: TextAlign.center,
                style: textTheme.titleMedium,
              ),
            ),
          ),
          IconButton.filledTonal(
            key: ValueKey('$keyPrefix-increment'),
            tooltip: l10n.counterIncrease(label),
            onPressed: onIncrement,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}
