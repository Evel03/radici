// Agenda: pedidos por fecha preferida en vista mensual o semanal, con la
// franja (mañana, tarde, indistinto), y la lista "senza data".
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/application/agenda_controller.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/domain/agenda.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/chef_shell.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart';
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

class AgendaScreen extends ConsumerWidget {
  const AgendaScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final inbox = ref.watch(chefInboxProvider);
    final agenda = ref.watch(agendaControllerProvider);

    final Widget body;
    if (inbox.hasError && !inbox.hasValue) {
      body = LoadErrorView(
        message: l10n.inboxLoadError,
        onRetry: () => ref.invalidate(chefInboxProvider),
      );
    } else {
      body = Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            key: const ValueKey('agenda'),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
            children: [
              if (inbox.isLoading && !inbox.hasValue)
                const LinearProgressIndicator(),
              const _AgendaToolbar(),
              const SizedBox(height: 8),
              switch (agenda.view) {
                AgendaView.month => const _MonthView(),
                AgendaView.week => const _WeekView(),
              },
              _SectionTitle(l10n.requestNoDate),
              const _WithoutDateList(),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.navAgenda),
        actions: const [ChefAccountMenuButton()],
      ),
      body: body,
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

class _MonthView extends ConsumerWidget {
  const _MonthView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = RequestFormats(context);
    final selected = ref.watch(
      agendaControllerProvider.select((s) => s.selectedDay),
    );
    final byDate = ref.watch(agendaByDateProvider);
    final weeks = monthGrid(selected);
    final dayRequests = byDate[selected] ?? const <ChefRequest>[];

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
                  ),
                ),
            ],
          ),
        _SectionTitle(formats.longDate(selected)),
        if (dayRequests.isEmpty)
          _EmptyText(l10n.agendaNoRequestsDay, key: const ValueKey('agenda-day-empty'))
        else
          for (final request in dayRequests)
            RequestTile(request: request, showSlotOnly: true),
      ],
    );
  }
}

class _DayCell extends ConsumerWidget {
  const _DayCell({required this.day, required this.inMonth, required this.count});

  final CalendarDate day;
  final bool inMonth;
  final int count;

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

    final Color numberColor;
    if (isSelected) {
      numberColor = colors.onPrimary;
    } else if (!inMonth) {
      numberColor = colors.onSurfaceVariant.withValues(alpha: 0.6);
    } else {
      numberColor = colors.onSurface;
    }

    return Semantics(
      button: true,
      selected: isSelected,
      label: '${formats.longDate(day)}, ${l10n.agendaDayCount(count)}',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('agenda-day-${day.toIso()}'),
        customBorder: const CircleBorder(),
        onTap: () => ref.read(agendaControllerProvider.notifier).select(day),
        child: SizedBox(
          height: 52,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isSelected ? colors.primary : null,
                  border: isToday && !isSelected
                      ? Border.all(color: colors.primary, width: 1.5)
                      : null,
                ),
                child: Text(
                  '${day.day}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: numberColor,
                    fontWeight: isToday ? FontWeight.w700 : null,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              SizedBox(
                height: 12,
                child: count == 0
                    ? null
                    : Text(
                        '$count',
                        key: ValueKey('agenda-day-count-${day.toIso()}'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.tertiary,
                          fontWeight: FontWeight.w700,
                          height: 1,
                        ),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
