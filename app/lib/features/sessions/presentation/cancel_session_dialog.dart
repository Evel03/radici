// Confirmación de cancelar una sesión: qué pasa (la web vuelve a ofrecer el
// día y no se puede reactivar), el motivo (una lista cerrada, nunca texto
// libre: la clienta con cuenta puede leerlo) y, si la reserva tiene semanas
// después, «también las siguientes». Cancelar es lo único de la ficha que se
// confirma: mover tiene «Deshacer».
import 'package:flutter/material.dart';
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_api.dart';
import 'package:radici/features/sessions/presentation/session_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Lo que se eligió en la confirmación.
typedef CancelChoice = ({CancelReason reason, bool withFollowing});

/// Muestra la confirmación para [session] y sus [following] (las semanas
/// siguientes que se pueden cancelar). Devuelve lo elegido, o null si se
/// volvió atrás.
Future<CancelChoice?> showCancelSessionDialog(
  BuildContext context, {
  required CookingSession session,
  required List<CookingSession> following,
}) => showDialog<CancelChoice>(
  context: context,
  builder: (_) => CancelSessionDialog(session: session, following: following),
);

class CancelSessionDialog extends StatefulWidget {
  const CancelSessionDialog({
    super.key,
    required this.session,
    required this.following,
  });

  final CookingSession session;
  final List<CookingSession> following;

  @override
  State<CancelSessionDialog> createState() => _CancelSessionDialogState();
}

class _CancelSessionDialogState extends State<CancelSessionDialog> {
  /// El de por defecto del contrato: neutro, para no decir que la pidió la
  /// clienta (que puede leerlo) si no fue así.
  CancelReason _reason = CancelReason.chefCancelled;
  bool _withFollowing = false;

  /// En el orden en que se muestran.
  static const List<CancelReason> _reasons = [
    CancelReason.clientCancelled,
    CancelReason.chefUnavailable,
    CancelReason.chefCancelled,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final formats = RequestFormats(context);
    final following = widget.following;
    final count = 1 + (_withFollowing ? following.length : 0);

    return AlertDialog(
      key: const ValueKey('cancel-session-dialog'),
      scrollable: true,
      title: Text(
        l10n.cancelSessionTitle(formats.shortDate(widget.session.date)),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.cancelSessionBody),
          const SizedBox(height: 16),
          Semantics(
            header: true,
            child: Text(
              l10n.cancelSessionReason,
              style: theme.textTheme.titleSmall,
            ),
          ),
          RadioGroup<CancelReason>(
            groupValue: _reason,
            onChanged: (reason) {
              if (reason != null) setState(() => _reason = reason);
            },
            child: Column(
              children: [
                for (final reason in _reasons)
                  RadioListTile<CancelReason>(
                    key: ValueKey('cancel-reason-${reason.code}'),
                    contentPadding: EdgeInsets.zero,
                    value: reason,
                    title: Text(l10n.cancelReason(reason)),
                  ),
              ],
            ),
          ),
          if (following.isNotEmpty) ...[
            const Divider(),
            CheckboxListTile(
              key: const ValueKey('cancel-session-following'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _withFollowing,
              onChanged: (value) =>
                  setState(() => _withFollowing = value ?? false),
              title: Text(l10n.cancelSessionFollowing(following.length)),
              // Las fechas, con espacios que no cortan: el renglón se parte
              // entre dos fechas, nunca en medio de una.
              subtitle: Text(
                [
                  for (final session in following)
                    formats.shortDate(session.date).replaceAll(' ', ' '),
                ].join(' · '),
              ),
            ),
          ],
        ],
      ),
      actionsOverflowButtonSpacing: 8,
      actions: [
        TextButton(
          key: const ValueKey('cancel-session-keep'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelSessionKeep),
        ),
        FilledButton(
          key: const ValueKey('cancel-session-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: colors.error,
            foregroundColor: colors.onError,
          ),
          onPressed: () => Navigator.of(
            context,
          ).pop<CancelChoice>((reason: _reason, withFollowing: _withFollowing)),
          child: Text(l10n.cancelSessionConfirm(count)),
        ),
      ],
    );
  }
}
