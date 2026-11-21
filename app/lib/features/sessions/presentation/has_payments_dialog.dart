// Aviso de una semana ya cobrada al cancelar (409 hasPayments): no se canceló
// nada (es todo o nada). Dice cuáles están cobradas, por fecha, y ofrece lo
// que se puede hacer (hasPaymentsPlan): pasar la semana de la ficha al final
// de la reserva (decisión 5 del plan) si solo se cancelaba esa, o cancelar
// solo las que no están cobradas si se cancelaban varias. Cancelar una
// cobrada con la devolución llega con los cobros (PR 10): la app nunca manda
// allowWithPayments.
import 'package:flutter/material.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';
import 'package:radici/features/sessions/presentation/session_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Lo que se eligió en el aviso (null: «Cerrar»).
enum HasPaymentsAction {
  /// Abrir la hoja «Mover» con [HasPaymentsPlan.moveToEnd].
  moveToEnd,

  /// Cancelar [HasPaymentsPlan.unpaid].
  cancelUnpaid,
}

Future<HasPaymentsAction?> showHasPaymentsDialog(
  BuildContext context, {
  required HasPaymentsPlan plan,
}) => showDialog<HasPaymentsAction>(
  context: context,
  builder: (_) => HasPaymentsDialog(plan: plan),
);

class HasPaymentsDialog extends StatelessWidget {
  const HasPaymentsDialog({super.key, required this.plan});

  final HasPaymentsPlan plan;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final formats = SessionFormats(context);
    final paid = plan.paid;
    final unpaid = plan.unpaid;
    final moveToEnd = plan.moveToEnd;
    final next = moveToEnd != null
        ? l10n.cancelHasPaymentsMoveToEnd(formats.inText(moveToEnd))
        : unpaid.isNotEmpty
        ? l10n.cancelHasPaymentsCancelUnpaid(unpaid.length)
        : l10n.cancelHasPaymentsNoAction;

    return AlertDialog(
      key: const ValueKey('has-payments-dialog'),
      scrollable: true,
      title: Text(l10n.cancelHasPaymentsTitle(paid.length)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.cancelHasPaymentsPaid(
              paid.length,
              formats.listInText([for (final session in paid) session.date]),
            ),
            key: const ValueKey('has-payments-paid'),
          ),
          const SizedBox(height: 12),
          Text(next, key: const ValueKey('has-payments-next')),
        ],
      ),
      actionsOverflowButtonSpacing: 8,
      actions: [
        TextButton(
          key: const ValueKey('has-payments-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionClose),
        ),
        if (moveToEnd != null)
          FilledButton(
            key: const ValueKey('has-payments-move-to-end'),
            onPressed: () =>
                Navigator.of(context).pop(HasPaymentsAction.moveToEnd),
            child: Text(l10n.moveToEnd),
          ),
        if (unpaid.isNotEmpty)
          FilledButton(
            key: const ValueKey('has-payments-cancel-unpaid'),
            style: FilledButton.styleFrom(
              backgroundColor: colors.error,
              foregroundColor: colors.onError,
            ),
            onPressed: () =>
                Navigator.of(context).pop(HasPaymentsAction.cancelUnpaid),
            child: Text(l10n.cancelHasPaymentsCancelUnpaidAction(unpaid.length)),
          ),
      ],
    );
  }
}
