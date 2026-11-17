// Agenda en vista mensual o semanal: las sesiones de cada día (en la semana,
// bloques «Spesa · Arrivo · fino alle» con las horas de la sesión; cada una
// abre su ficha), los pedidos que todavía no son una reserva por su fecha
// preferida, con la franja, la lista "senza data" y la disponibilidad de cada
// día: bloqueados (la web no los ofrece), feriados y el botón «Blocca giorni»
// para un rango.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/availability/application/availability_controller.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/availability/presentation/availability_labels.dart';
import 'package:radici/features/availability/presentation/block_range_dialog.dart';
import 'package:radici/features/availability/presentation/day_availability_card.dart';
import 'package:radici/features/requests/application/agenda_controller.dart';
import 'package:radici/features/requests/application/chef_data_refresh.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/domain/agenda.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/chef_shell.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart';
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/presentation/session_block.dart';
import 'package:radici/features/sessions/presentation/sessions_load_error.dart';
import 'package:radici/l10n/app_localizations.dart';

class AgendaScreen extends ConsumerWidget {
  const AgendaScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final inbox = ref.watch(chefInboxProvider);

    // Sus propios avisos: así el de «Annulla» empuja hacia arriba el botón
    // flotante en lugar de taparlo (con el ScaffoldMessenger de la app, el
    // aviso sale en el Scaffold de afuera, el de la barra de navegación).
    return ScaffoldMessenger(
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.navAgenda),
          actions: const [ChefAccountMenuButton()],
        ),
        body: inbox.hasError && !inbox.hasValue
            ? LoadErrorView(
                message: l10n.inboxLoadError,
                onRetry: () => ref.invalidate(chefInboxProvider),
              )
            : const _AgendaList(),
        floatingActionButton: const BlockRangeButton(),
      ),
    );
  }
}

class _AgendaList extends ConsumerWidget {
  const _AgendaList();

  /// Deslizar para actualizar: la bandeja, la disponibilidad y las sesiones
  /// juntas. Si alguna falla, queda lo que había y se avisa.
  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = AppLocalizations.of(context).inboxRefreshError;
    final ok = await ref.read(refreshChefDataProvider)();
    if (!ok && messenger.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final loading = ref.watch(
      chefInboxProvider.select((inbox) => inbox.isLoading && !inbox.hasValue),
    );
    final view = ref.watch(agendaControllerProvider.select((s) => s.view));

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: RefreshIndicator(
          onRefresh: () => _refresh(context, ref),
          child: ListView(
            key: const ValueKey('agenda'),
            // Deslizar para actualizar aunque todo entre en la pantalla.
            physics: const AlwaysScrollableScrollPhysics(),
            // Abajo, lugar para el botón flotante: no tapa nada.
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
            children: [
              if (loading) const LinearProgressIndicator(),
              const _AgendaToolbar(),
              const SessionsLoadError(),
              const SizedBox(height: 8),
              switch (view) {
                AgendaView.month => const _MonthView(),
                AgendaView.week => const _WeekView(),
              },
              _SectionTitle(l10n.requestNoDate),
              const _WithoutDateList(),
            ],
          ),
        ),
      ),
    );
  }
}

class _AgendaToolbar extends ConsumerWidget {
  const _AgendaToolbar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = RequestFormats(context);
    final agenda = ref.watch(agendaControllerProvider);
    final controller = ref.read(agendaControllerProvider.notifier);
    final day = agenda.selectedDay;

    final title = switch (agenda.view) {
      AgendaView.month => formats.monthTitle(day),
      AgendaView.week => l10n.agendaWeekRange(
        formats.dayMonth(day.startOfWeek),
        formats.dayMonthYear(day.startOfWeek.addDays(6)),
      ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: SegmentedButton<AgendaView>(
            key: const ValueKey('agenda-view'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: AgendaView.month,
                label: Text(
                  l10n.agendaViewMonth,
                  key: const ValueKey('agenda-view-month'),
                ),
                icon: const Icon(Icons.calendar_view_month),
              ),
              ButtonSegment(
                value: AgendaView.week,
                label: Text(
                  l10n.agendaViewWeek,
                  key: const ValueKey('agenda-view-week'),
                ),
                icon: const Icon(Icons.view_week_outlined),
              ),
            ],
            selected: {agenda.view},
            onSelectionChanged: (selection) =>
                controller.setView(selection.single),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            IconButton(
              key: const ValueKey('agenda-previous'),
              tooltip: l10n.agendaPrevious,
              onPressed: controller.previous,
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                title,
                key: const ValueKey('agenda-title'),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
            ),
            TextButton(
              key: const ValueKey('agenda-today'),
              onPressed: controller.today,
              child: Text(l10n.agendaToday),
            ),
            IconButton(
              key: const ValueKey('agenda-next'),
              tooltip: l10n.agendaNext,
              onPressed: controller.next,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ],
    );
  }
}

class _MonthView extends ConsumerStatefulWidget {
  const _MonthView();

  @override
  ConsumerState<_MonthView> createState() => _MonthViewState();
}

class _MonthViewState extends ConsumerState<_MonthView> {
  /// El título del día elegido y su tarjeta.
  final GlobalKey _dayKey = GlobalKey();

  /// Elige [day] y trae su tarjeta a la vista: en un teléfono, con un mes de
  /// seis semanas, queda debajo de la pantalla (o la tapa el botón flotante).
  void _select(CalendarDate day) {
    ref.read(agendaControllerProvider.notifier).select(day);
    final dayContext = _dayKey.currentContext;
    if (dayContext != null) revealAgendaCard(dayContext);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = RequestFormats(context);
    final selected = ref.watch(
      agendaControllerProvider.select((s) => s.selectedDay),
    );
    final byDate = ref.watch(agendaByDateProvider);
    final sessionsByDate = ref.watch(agendaSessionsByDateProvider);
    final weeks = monthGrid(selected);
    final dayRequests = byDate[selected] ?? const <ChefRequest>[];
    final daySessions = sessionsByDate[selected] ?? const <CookingSession>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Nombres de los días (lunes a domingo).
        ExcludeSemantics(
          child: Row(
            children: [
              for (final day in weeks.first)
                Expanded(
                  child: Text(
                    formats.weekdayShort(day),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        for (final week in weeks)
          Row(
            children: [
              for (final day in week)
                Expanded(
                  child: _DayCell(
                    day: day,
                    inMonth: day.isSameMonth(selected),
                    count: byDate[day]?.length ?? 0,
                    sessionCount: sessionsByDate[day]?.length ?? 0,
                    onTap: () => _select(day),
                  ),
                ),
            ],
          ),
        Column(
          key: _dayKey,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionTitle(formats.longDate(selected)),
            DayAvailabilityCard(day: selected),
            // Las sesiones del día (cada una abre su ficha), con la tarjeta:
            // al elegir el día se ven sin desplazar.
            for (final session in daySessions) SessionBlock(session: session),
          ],
        ),
        if (dayRequests.isEmpty && daySessions.isEmpty)
          _EmptyText(l10n.agendaNoRequestsDay, key: const ValueKey('agenda-day-empty'))
        else
          for (final request in dayRequests)
            RequestTile(request: request, showSlotOnly: true),
      ],
    );
  }
}

/// Cuántas sesiones se marcan como mucho en una celda del mes (un punto cada
/// una); el texto accesible dice todas.
const int _maxSessionDots = 3;

class _DayCell extends ConsumerWidget {
  const _DayCell({
    required this.day,
    required this.inMonth,
    required this.count,
    required this.sessionCount,
    required this.onTap,
  });

  final CalendarDate day;
  final bool inMonth;

  /// Pedidos que lo preferían.
  final int count;

  /// Sesiones vivas de ese día.
  final int sessionCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final formats = RequestFormats(context);
    final isSelected = ref.watch(
      agendaControllerProvider.select((s) => s.selectedDay == day),
    );
    final isToday = ref.watch(romeTodayProvider) == day;
    final availability = ref.watch(agendaDayAvailabilityProvider(day));
    final isBlocked = availability?.status == DayStatus.blocked;
    // El punto: un feriado en un día de trabajo que no pasó ni está bloqueado.
    final holiday = availability?.status == DayStatus.open
        ? availability?.holiday
        : null;

    final Color numberColor;
    if (isSelected) {
      numberColor = colors.onPrimary;
    } else if (!inMonth) {
      // Sin transparencia: con alfa, sobre la crema del tema quedaba por
      // debajo del contraste mínimo (2,6:1). Igual se distinguen: los días del
      // mes van en onSurface.
      numberColor = colors.onSurfaceVariant;
    } else {
      numberColor = colors.onSurface;
    }

    final label = [
      formats.longDate(day),
      if (sessionCount > 0) l10n.agendaSessionCount(sessionCount),
      l10n.agendaDayCount(count),
      if (isBlocked) l10n.availabilityBlockedA11y,
      if (holiday != null) l10n.holidayLine(holiday),
    ].join(', ');

    return Semantics(
      button: true,
      selected: isSelected,
      label: label,
      excludeSemantics: true,
      // La acción va en el nodo: excludeSemantics descarta la del InkWell, y
      // en /gestione/ el clic de VoiceOver solo llega a un nodo que la tiene.
      onTap: onTap,
      child: InkWell(
        key: ValueKey('agenda-day-${day.toIso()}'),
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          height: 52,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Sin alignment: así el Stack ocupa todo el círculo y el punto
              // del feriado queda debajo del número (con alignment, el Stack
              // medía lo que el texto y el punto caía sobre las cifras).
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isSelected
                      ? colors.primary
                      : isBlocked
                      ? colors.surfaceContainerHighest
                      : null,
                  border: isToday && !isSelected
                      ? Border.all(color: colors.primary, width: 1.5)
                      : null,
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Text(
                      '${day.day}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: numberColor,
                        fontWeight: isToday ? FontWeight.w700 : null,
                        // Tachado: la señal de bloqueado que no depende del color.
                        decoration: isBlocked ? TextDecoration.lineThrough : null,
                        decorationColor: numberColor,
                        decorationThickness: 2,
                      ),
                    ),
                    if (holiday != null)
                      Positioned(
                        bottom: 3,
                        child: Container(
                          key: ValueKey('agenda-day-holiday-${day.toIso()}'),
                          width: 4,
                          height: 4,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isSelected ? colors.onPrimary : colors.tertiary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 2),
              // Debajo del número: un punto por sesión (en el color principal)
              // y la cantidad de pedidos que lo preferían.
              SizedBox(
                height: 12,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (sessionCount > 0)
                      Row(
                        key: ValueKey('agenda-day-sessions-${day.toIso()}'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (
                            var i = 0;
                            i < math.min(sessionCount, _maxSessionDots);
                            i++
                          )
                            Container(
                              width: 6,
                              height: 6,
                              margin: const EdgeInsets.symmetric(horizontal: 1),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: colors.primary,
                              ),
                            ),
                        ],
                      ),
                    if (sessionCount > 0 && count > 0) const SizedBox(width: 3),
                    if (count > 0)
                      Text(
                        '$count',
                        key: ValueKey('agenda-day-count-${day.toIso()}'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.tertiary,
                          fontWeight: FontWeight.w700,
                          height: 1,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WeekView extends ConsumerWidget {
  const _WeekView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final formats = RequestFormats(context);
    final selected = ref.watch(
      agendaControllerProvider.select((s) => s.selectedDay),
    );
    final today = ref.watch(romeTodayProvider);
    final byDate = ref.watch(agendaByDateProvider);
    final sessionsByDate = ref.watch(agendaSessionsByDateProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // La carga y los errores de la disponibilidad, una sola vez.
        const AvailabilityLoadState(),
        for (final day in weekDays(selected))
          Card(
            key: ValueKey('agenda-week-day-${day.toIso()}'),
            margin: const EdgeInsets.symmetric(vertical: 4),
            color: day == today ? theme.colorScheme.secondaryContainer : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Semantics(
                      header: true,
                      child: Text(
                        formats.longDate(day),
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ),
                  DayAvailabilityCard(day: day, compact: true),
                  // Bloques «Spesa · Arrivo · fino alle», con las horas de
                  // cada sesión.
                  for (final session
                      in sessionsByDate[day] ?? const <CookingSession>[])
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: SessionBlock(session: session),
                    ),
                  for (final request in byDate[day] ?? const <ChefRequest>[])
                    RequestTile(request: request, showSlotOnly: true),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _WithoutDateList extends ConsumerWidget {
  const _WithoutDateList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final requests = ref.watch(agendaWithoutDateProvider);
    if (requests.isEmpty) {
      return _EmptyText(
        l10n.agendaWithoutDateEmpty,
        key: const ValueKey('agenda-without-date-empty'),
      );
    }
    return Column(
      key: const ValueKey('agenda-without-date'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final request in requests) RequestTile(request: request),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

class _EmptyText extends StatelessWidget {
  const _EmptyText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
