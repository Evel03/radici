// Disponibilidad de un día en la agenda: si la web lo ofrece, el feriado,
// cuántos pedidos lo preferían y los botones para bloquearlo o desbloquearlo,
// con su nota privada. En la vista de semana va compacta.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/availability/application/availability_controller.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/availability/presentation/availability_actions.dart';
import 'package:radici/features/availability/presentation/availability_labels.dart';
import 'package:radici/features/availability/presentation/note_dialog.dart';
import 'package:radici/l10n/app_localizations.dart';

class DayAvailabilityCard extends ConsumerWidget {
  const DayAvailabilityCard({super.key, required this.day, this.compact = false});

  final CalendarDate day;

  /// Vista de semana: solo el bloqueo (con su nota), el feriado y el botón;
  /// la carga y los errores se muestran una sola vez arriba
  /// ([AvailabilityLoadState]).
  final bool compact;

  Future<void> _editNote(BuildContext context, String? current) async {
    final actions = AvailabilityActions.of(context);
    final note = await showNoteDialog(context, initial: current);
    if (note == null) return;
    await actions.setNote(day, note);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(agendaDayAvailabilityProvider(day));
    if (info == null) {
      return compact ? const SizedBox.shrink() : const AvailabilityLoadState();
    }

    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final iso = day.toIso();
    final saving = ref.watch(
      availabilitySavingProvider.select((days) => days.contains(day)),
    );
    final secondary = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    final String? status = switch (info.status) {
      DayStatus.blocked => l10n.availabilityDayBlocked,
      DayStatus.open when !compact => l10n.availabilityDayOpen(
        formatHours(info.hours),
      ),
      DayStatus.closed when !compact => l10n.availabilityDayClosed,
      DayStatus.past when !compact => l10n.availabilityDayPast,
      _ => null,
    };
    final holiday = info.holiday;
    final note = info.note;
    final showRequests =
        !compact &&
        info.requestCount > 0 &&
        (info.status == DayStatus.open || info.status == DayStatus.blocked);

    final buttons = <Widget>[
      if (info.canBlock)
        _actionButton(
          key: ValueKey('availability-block-$iso'),
          label: l10n.availabilityBlockDay,
          tonal: !compact,
          onPressed: saving
              ? null
              : () => unawaited(AvailabilityActions.of(context).block([day])),
        ),
      if (info.canUnblock && !compact)
        TextButton.icon(
          key: ValueKey('availability-note-$iso'),
          onPressed: saving ? null : () => unawaited(_editNote(context, note)),
          icon: const Icon(Icons.edit_note),
          label: Text(
            note == null ? l10n.availabilityAddNote : l10n.availabilityEditNote,
          ),
        ),
      if (info.canUnblock)
        OutlinedButton(
          key: ValueKey('availability-unblock-$iso'),
          onPressed: saving
              ? null
              : () => unawaited(AvailabilityActions.of(context).unblock([day])),
          child: Text(l10n.availabilityUnblockDay),
        ),
      if (saving)
        const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
    ];

    final children = <Widget>[
      if (status != null)
        Text(status, key: ValueKey('availability-status-$iso')),
      if (holiday != null)
        _IconLine(
          icon: Icons.celebration_outlined,
          text: l10n.holidayLine(holiday),
          style: secondary,
        ),
      if (note != null)
        _IconLine(
          icon: Icons.sticky_note_2_outlined,
          iconLabel: l10n.availabilityNoteLabel,
          text: note,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontStyle: FontStyle.italic,
          ),
        ),
      if (showRequests)
        _IconLine(
          icon: Icons.info_outline,
          text: l10n.availabilityRequestsThatDay(info.requestCount),
          style: secondary,
        ),
      if (buttons.isNotEmpty)
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: buttons,
        ),
    ];
    if (children.isEmpty) return const SizedBox.shrink();

    return Padding(
      key: ValueKey('availability-day-$iso'),
      padding: compact
          ? const EdgeInsets.fromLTRB(16, 4, 16, 0)
          : const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, child) in children.indexed) ...[
            if (i > 0) const SizedBox(height: 8),
            child,
          ],
        ],
      ),
    );
  }

  /// En la tarjeta del día, botón tonal; en la semana, con borde (la tarjeta
  /// de hoy ya es del color del tonal).
  Widget _actionButton({
    required Key key,
    required String label,
    required bool tonal,
    required VoidCallback? onPressed,
  }) => tonal
      ? FilledButton.tonal(key: key, onPressed: onPressed, child: Text(label))
      : OutlinedButton(key: key, onPressed: onPressed, child: Text(label));
}

/// Mientras carga, una barra fina; si no se pudo cargar, el aviso con
/// «Riprova»; si está cargada, nada.
class AvailabilityLoadState extends ConsumerWidget {
  const AvailabilityLoadState({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(availabilityReadyProvider)) return const SizedBox.shrink();
    final availability = ref.watch(availabilityControllerProvider);
    if (availability.isLoading || !availability.hasError) {
      return const Padding(
        key: ValueKey('availability-loading'),
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      );
    }
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey('availability-load-error'),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            l10n.availabilityLoadFailed,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          TextButton(
            key: const ValueKey('availability-retry'),
            onPressed: () => ref.invalidate(availabilityControllerProvider),
            child: Text(l10n.actionRetry),
          ),
        ],
      ),
    );
  }
}

/// Una línea con ícono. El ícono es decorativo salvo que traiga [iconLabel].
class _IconLine extends StatelessWidget {
  const _IconLine({
    required this.icon,
    required this.text,
    this.iconLabel,
    this.style,
  });

  final IconData icon;
  final String text;
  final String? iconLabel;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final glyph = Icon(icon, size: 18, color: color, semanticLabel: iconLabel);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (iconLabel == null) ExcludeSemantics(child: glyph) else glyph,
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: style)),
      ],
    );
  }
}
