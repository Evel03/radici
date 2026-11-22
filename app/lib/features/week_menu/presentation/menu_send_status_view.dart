// El estado del envío del menú de una semana a la clienta (SPEC 5.8), donde
// se muestra un menú: el editor, el bloque «Menú de la semana» de la ficha y
// las semanas de la reserva en el detalle del pedido. Dice si todavía no se
// mandó; cuándo y por dónde salió el último envío (hora de Roma); si la
// clienta lo confirmó o pidió cambios, con su mensaje entero (en varios
// renglones y seleccionable: solo se ve en la app, nunca va por email ni por
// push, SPEC §6), si el menú cambió después de mandarlo (hay que mandarlo de
// nuevo) y, en una semana confirmada, si salió con una versión anterior del
// presupuesto que nadie confirmó (también hay que mandarlo de nuevo, como
// dicen los avisos). Solo muestra providers (week_menu_summaries.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/features/week_menu/application/week_menu_summaries.dart';
import 'package:radici/features/week_menu/domain/menu_send.dart';
import 'package:radici/features/week_menu/presentation/week_menu_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

/// El último envío del menú de la sesión [sessionId], como lo muestran la
/// ficha y el editor: el estado ([savedVersion] es la versión del menú
/// guardado, para saber si cambió después de mandarlo), una barra mientras
/// carga y, si no se puede leer, el aviso con «Reintentar». Nada mientras no
/// hay menú guardado ni envío. [confirmedWeek]: la semana está confirmada,
/// así que también mira si el envío salió con una versión anterior del
/// presupuesto (earlierQuoteSendProvider).
class SessionMenuSendStatus extends ConsumerWidget {
  const SessionMenuSendStatus({
    super.key,
    required this.sessionId,
    required this.savedVersion,
    required this.keyPrefix,
    this.confirmedWeek = false,
  });

  final String sessionId;
  final int? savedVersion;

  /// El comienzo de las claves de sus textos ([MenuSendStatusView.keyPrefix]).
  final String keyPrefix;
  final bool confirmedWeek;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final latest = ref.watch(latestMenuSendProvider(sessionId));
    final earlierQuote =
        confirmedWeek &&
        (ref.watch(earlierQuoteSendProvider(sessionId)).value ?? false);
    return latest.when(
      data: (send) => send == null && savedVersion == null
          ? const SizedBox.shrink()
          : MenuSendStatusView(
              status: WeekMenuSendStatus(
                send: send,
                savedVersion: savedVersion,
                sentWithEarlierQuote: earlierQuote,
              ),
              keyPrefix: keyPrefix,
            ),
      loading: () => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(
          key: ValueKey('$keyPrefix-loading'),
          semanticsLabel: l10n.menuSendSection,
        ),
      ),
      error: (_, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MergeSemantics(
            child: Text(
              l10n.menuSendStatusFailed,
              key: ValueKey('$keyPrefix-error'),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: ValueKey('$keyPrefix-retry'),
              onPressed: () =>
                  ref.invalidate(latestMenuSendProvider(sessionId)),
              child: Text(l10n.actionRetry),
            ),
          ),
        ],
      ),
    );
  }
}

/// El estado del envío de una semana: [status], ya leído.
class MenuSendStatusView extends StatelessWidget {
  const MenuSendStatusView({
    super.key,
    required this.status,
    required this.keyPrefix,
  });

  final WeekMenuSendStatus status;

  /// El comienzo de las claves de sus textos, único en la pantalla (los
  /// tests los leen por ahí): «week-menu-status», «session-menu-status»…
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final formats = RequestFormats(context);
    final send = status.send;

    String sentLine(MenuSendRecord send) => l10n.menuSendSentOn(
      formats.instantDayMonth(send.sentAt),
      formats.instantTime(send.sentAt),
      l10n.menuSendViaText(send.via),
    );

    final children = <Widget>[
      switch ((status.phase, send)) {
        (MenuSendPhase.confirmed, final send?) => _StatusLine(
          icon: Icons.check_circle_outline,
          color: colors.primary,
          text: l10n.menuSendConfirmedOn(
            formats.instantDayMonth(send.confirmedAt!),
            formats.instantTime(send.confirmedAt!),
          ),
          textKey: ValueKey('$keyPrefix-confirmed'),
          strong: true,
        ),
        (MenuSendPhase.changesRequested, final send?) => _StatusLine(
          icon: Icons.rate_review_outlined,
          color: colors.tertiary,
          text: l10n.menuSendChangesOn(
            formats.instantDayMonth(send.changesRequestedAt!),
            formats.instantTime(send.changesRequestedAt!),
          ),
          textKey: ValueKey('$keyPrefix-changes'),
          strong: true,
        ),
        (MenuSendPhase.sent, final send?) => _StatusLine(
          icon: Icons.send_outlined,
          color: colors.primary,
          text: sentLine(send),
          textKey: ValueKey('$keyPrefix-sent'),
        ),
        _ => _StatusLine(
          icon: Icons.outbox_outlined,
          color: colors.onSurfaceVariant,
          text: l10n.menuSendNotSent,
          textKey: ValueKey('$keyPrefix-not-sent'),
        ),
      },
      if (status.phase == MenuSendPhase.changesRequested)
        if (send?.changesText case final text?)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 28, top: 4),
            child: _ClientMessage(
              text: text,
              textKey: ValueKey('$keyPrefix-changes-text'),
            ),
          ),
      // Confirmado o con cambios pedidos: cuándo y por dónde había salido.
      if (send != null && status.phase != MenuSendPhase.sent)
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 28, top: 4),
          child: MergeSemantics(
            child: Text(
              sentLine(send),
              key: ValueKey('$keyPrefix-sent-on'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      // Salió con una versión anterior del presupuesto y nadie lo confirmó:
      // para los avisos sigue pendiente.
      if (status.sentWithEarlierQuote)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: _StatusLine(
            icon: Icons.update,
            color: colors.error,
            text: l10n.menuSendOldQuote,
            textKey: ValueKey('$keyPrefix-earlier-quote'),
            strong: true,
          ),
        ),
      if (status.changedSinceSent)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: _StatusLine(
            icon: Icons.update,
            color: colors.error,
            text: l10n.menuSendChangedSince,
            textKey: ValueKey('$keyPrefix-changed-since'),
            strong: true,
          ),
        ),
    ];
    return Column(
      key: ValueKey(keyPrefix),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// Un renglón del estado: el ícono y el texto, un solo nodo para el lector de
/// pantalla.
class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.icon,
    required this.color,
    required this.text,
    required this.textKey,
    this.strong = false,
  });

  final IconData icon;
  final Color color;
  final String text;
  final Key textKey;

  /// Resaltado: lo que pide hacer algo o responde la clienta.
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 20, color: color),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              key: textKey,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: strong ? FontWeight.w600 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// El mensaje de la clienta al pedir cambios, entero y como lo escribió (con
/// sus saltos de línea), para leerlo y copiarlo.
class _ClientMessage extends StatelessWidget {
  const _ClientMessage({required this.text, required this.textKey});

  final String text;
  final Key textKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        border: BorderDirectional(
          start: BorderSide(color: colors.tertiary, width: 3),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: SelectableText(
          text,
          key: textKey,
          style: theme.textTheme.bodyMedium,
        ),
      ),
    );
  }
}
