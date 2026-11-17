// La tira de Hoy: hoy y los 6 días siguientes, como las celdas del mes de la
// agenda: un punto por sesión, el número tachado si el día está bloqueado (la
// señal que no depende del color) y un punto si es feriado en un día de
// trabajo. Tocar un día abre la Agenda con ese día elegido. Cada celda es un
// botón con la acción de tocar en su nodo (en /gestione/ el clic de VoiceOver
// solo llega a un nodo que la tiene) y su texto dice todo (también cuál es
// hoy). Si los 7 no entran con 48 dp cada uno (un teléfono de 360 dp o
// menos), van en dos filas: 4 y 3.
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

/// Cuánto crecen como mucho el día y el número de una celda con la letra del
/// sistema más grande: el número va en un círculo fijo de 32, como en el mes
/// de la agenda, y más que esto no entra.
const double _maxCellTextScale = 1.5;

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
          // La carga y los errores de la disponibilidad (con «Riprova»),
          // separados del borde de la tarjeta.
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: AvailabilityLoadState(),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              // Los 7 en una fila si cada uno llega a 48 dp; si no, en dos
              // (4 y 3), todos del mismo ancho.
              final perRow =
                  constraints.maxWidth / days.length >= kMinInteractiveDimension
                  ? days.length
                  : (days.length + 1) ~/ 2;
              return Column(
                children: [
                  for (var start = 0; start < days.length; start += perRow)
                    Row(
                      children: [
                        for (var i = start; i < start + perRow; i++)
                          Expanded(
                            child: i < days.length
                                ? _StripDay(day: days[i], isToday: i == 0)
                                : const SizedBox.shrink(),
                          ),
                      ],
                    ),
                ],
              );
            },
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
      // El aro que marca hoy no se lee: lo dice el texto.
      if (isToday) l10n.todayStripToday,
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
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: _maxCellTextScale,
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
      ),
    );
  }
}
