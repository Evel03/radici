// La tira de Hoy: hoy y los 6 días siguientes, como las celdas del mes de la
// agenda: un punto por sesión, el número tachado si el día está bloqueado (la
// señal que no depende del color) y un punto si es feriado en un día de
// trabajo. Tocar un día abre la Agenda con ese día elegido. Cada celda es un
// botón con la acción de tocar en su nodo (en /gestione/ el clic de VoiceOver
// solo llega a un nodo que la tiene) y su texto dice todo.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/availability/presentation/availability_labels.dart';
import 'package:radici/features/availability/presentation/day_availability_card.dart';
import 'package:radici/features/requests/application/agenda_controller.dart';
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/features/today/application/today_providers.dart';
import 'package:radici/features/today/domain/today.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Cuántas sesiones se marcan como mucho en una celda (un punto cada una); el
/// texto accesible dice todas.
const int _maxSessionDots = 3;

class TodayStrip extends ConsumerWidget {
  const TodayStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(todayStripProvider);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // La carga y los errores de la disponibilidad (con «Riprova»).
          const AvailabilityLoadState(),
          Row(
            children: [
              for (final (i, day) in days.indexed)
                Expanded(child: _StripDay(day: day, isToday: i == 0)),
            ],
          ),
        ],
      ),
    );
  }
}

class _StripDay extends ConsumerWidget {
  const _StripDay({required this.day, required this.isToday});

  final TodayStripDay day;
  final bool isToday;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final formats = RequestFormats(context);
    final iso = day.date.toIso();
    final blocked = day.isBlocked;
    // Como en la agenda: el punto del feriado solo en un día de trabajo que
    // no está bloqueado.
    final holiday = day.status == DayStatus.open ? day.holiday : null;
    final numberColor = day.status == DayStatus.closed
        ? colors.onSurfaceVariant
        : colors.onSurface;

    void open() {
      ref.read(agendaControllerProvider.notifier).select(day.date);
      context.go(AppRoutes.agenda);
    }

    final label = [
      formats.longDate(day.date),
      if (day.sessionCount > 0) l10n.agendaSessionCount(day.sessionCount),
      if (blocked) l10n.availabilityBlockedA11y,
      if (holiday != null) l10n.holidayLine(holiday),
    ].join(', ');

    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: open,
      child: InkWell(
        key: ValueKey('today-strip-$iso'),
        onTap: open,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 76),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formats.weekdayShort(day.date),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: blocked ? colors.surfaceContainerHighest : null,
                    border: isToday
                        ? Border.all(color: colors.primary, width: 1.5)
                        : null,
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Text(
                        '${day.date.day}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: numberColor,
                          fontWeight: isToday ? FontWeight.w700 : null,
                          decoration: blocked
                              ? TextDecoration.lineThrough
                              : null,
                          decorationColor: numberColor,
                          decorationThickness: 2,
                        ),
                      ),
                      if (holiday != null)
                        Positioned(
                          bottom: 3,
                          child: Container(
                            key: ValueKey('today-strip-$iso-holiday'),
                            width: 4,
                            height: 4,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: colors.tertiary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 8,
                  child: day.sessionCount == 0
                      ? null
                      : Row(
                          key: ValueKey('today-strip-$iso-sessions'),
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (
                              var i = 0;
                              i < math.min(day.sessionCount, _maxSessionDots);
                              i++
                            )
                              Container(
                                width: 6,
                                height: 6,
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 1,
                                ),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: colors.primary,
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
