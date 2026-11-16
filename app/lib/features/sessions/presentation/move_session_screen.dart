// Hoja «Sposta la sessione», a pantalla completa desde la ficha: la fecha
// nueva (toda la fila abre el calendario) con lo que dice el servidor de esa
// fecha antes de confirmar, y la hora de llegada en chips. Si esa semana ya
// tiene otra sesión de la reserva (una por semana), ofrece pasarla al final
// de la reserva. Abajo, siempre a mano, «Sposta a …» con lo que se va a hacer
// o lo que lo impide. Al mover, vuelve a la ficha, que ofrece «Annulla».
//
// Solo lee providers: la lógica está en MoveSessionController. No tiene
// campos de texto propios; los del calendario y del reloj en modo escritura
// usan letra de 16 px o más (con menos, iOS agranda la página).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart'
    show arrivalOptions, bookingDateRangeDays;
import 'package:radici/features/bookings/presentation/booking_labels.dart';
import 'package:radici/features/requests/application/agenda_controller.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart'
    show LoadErrorView;
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/features/sessions/application/move_session_controller.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/domain/session_api.dart';
import 'package:radici/features/sessions/presentation/session_actions.dart';
import 'package:radici/features/sessions/presentation/session_labels.dart';
import 'package:radici/features/sessions/presentation/session_widgets.dart';
import 'package:radici/l10n/app_localizations.dart';

/// El calendario para elegir la fecha nueva de una sesión: de un año antes a
/// un año después de hoy (lo que acepta el servidor, con un día de margen).
Future<CalendarDate?> pickSessionDate(
  BuildContext context, {
  required CalendarDate initial,
}) async {
  final today = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(romeTodayProvider);
  final first = today.addDays(-bookingDateRangeDays);
  final last = today.addDays(bookingDateRangeDays);
  var start = initial;
  if (start.isBefore(first)) start = first;
  if (start.isAfter(last)) start = last;
  final picked = await showDatePicker(
    context: context,
    initialDate: start.toDateTime(),
    firstDate: first.toDateTime(),
    lastDate: last.toDateTime(),
    currentDate: today.toDateTime(),
    helpText: AppLocalizations.of(context).moveSessionPickerHelp,
  );
  return picked == null ? null : CalendarDate.fromDateTime(picked);
}

/// Abre la hoja «Sposta» de [sessionId] (con [date] ya elegida, si la hay) y,
/// si se movió, el aviso con «Annulla».
Future<void> openMoveSheet(
  BuildContext context,
  String sessionId, {
  CalendarDate? date,
}) async {
  final actions = SessionActions.of(context);
  final outcome = await context.push<MoveOutcome>(
    AppRoutes.sessionMove(sessionId, date: date),
  );
  if (outcome != null) actions.showMoved(outcome);
}

class MoveSessionScreen extends ConsumerWidget {
  const MoveSessionScreen({super.key, required this.sessionId, this.date});

  final String sessionId;

  /// La fecha nueva ya elegida en el calendario de la ficha, o null.
  final CalendarDate? date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final detail = ref.watch(sessionDetailProvider(sessionId));
    if (detail.value != null) {
      return _MoveSessionView(args: (sessionId: sessionId, date: date));
    }
    return Scaffold(
      appBar: AppBar(title: Text(l10n.moveSessionTitle)),
      body: detail.when(
        data: (_) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              l10n.sessionNotFound,
              key: const ValueKey('move-session-not-found'),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        error: (_, _) => LoadErrorView(
          message: l10n.sessionLoadError,
          onRetry: () => ref.invalidate(sessionDetailProvider(sessionId)),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _MoveSessionView extends ConsumerWidget {
  const _MoveSessionView({required this.args});

  final MoveSessionArgs args;

  Future<void> _pickDate(
    BuildContext context,
    MoveSessionState state,
    MoveSessionController controller,
  ) async {
    final picked = await pickSessionDate(context, initial: state.date);
    if (picked == null || !context.mounted) return;
    controller.setDate(picked);
  }

  Future<void> _pickTime(
    BuildContext context,
    MoveSessionState state,
    MoveSessionController controller,
  ) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: state.start.hour,
        minute: state.start.minute,
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null || !context.mounted) return;
    controller.setStart(ClockTime.hm(picked.hour, picked.minute));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = RequestFormats(context);
    final provider = moveSessionProvider(args);
    final state = ref.watch(provider);
    final controller = ref.read(provider.notifier);
    ref.listen(provider, (previous, next) {
      final outcome = next.outcome;
      if (previous?.outcome == null && outcome != null) {
        Navigator.of(context).pop(outcome);
      }
    });

    final session = state.session!;
    final frozen = state.sending || state.blocked || state.outcome != null;
    final end = state.endOfBooking;

    return PopScope(
      // Mientras mueve, la hoja no se cierra.
      canPop: !state.sending,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            key: const ValueKey('move-close'),
            icon: const Icon(Icons.close),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: state.sending
                ? null
                : () => Navigator.of(context).maybePop(),
          ),
          title: Text(l10n.moveSessionTitle),
        ),
        body: Column(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: sessionMaxContentWidth,
                  ),
                  child: SingleChildScrollView(
                    key: const ValueKey('move-form'),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          session.displayName,
                          style: theme.textTheme.titleLarge,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          l10n.moveSessionNow(
                            formats.shortDate(session.date),
                            session.start.toHhMm(),
                          ),
                          key: const ValueKey('move-now'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        SessionSection(l10n.moveSessionNewDate),
                        _DateTile(
                          state: state,
                          onEdit: frozen
                              ? null
                              : () => unawaited(
                                  _pickDate(context, state, controller),
                                ),
                        ),
                        // La fila y la barra ya dicen que esa semana tiene
                        // otra sesión de la reserva: acá, la salida.
                        if (state.weekTaken && end != null) ...[
                          const SizedBox(height: 8),
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: OutlinedButton.icon(
                              key: const ValueKey('move-to-end'),
                              onPressed: frozen ? null : controller.moveToEnd,
                              icon: const Icon(Icons.last_page),
                              label: Text(l10n.moveToEnd),
                            ),
                          ),
                          const SizedBox(height: 4),
                          SessionHelp(
                            l10n.moveToEndDate(formats.shortDate(end)),
                          ),
                        ],
                        if (state.checksStatus == MoveChecksStatus.failed &&
                            state.checksCurrent) ...[
                          const SizedBox(height: 8),
                          Text(
                            l10n.moveChecksFailed,
                            key: const ValueKey('move-checks-failed'),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                          if (!frozen)
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: TextButton(
                                key: const ValueKey('move-checks-retry'),
                                onPressed: controller.retryChecks,
                                child: Text(l10n.actionRetry),
                              ),
                            ),
                        ],
                        SessionSection(l10n.bookingStartSection),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final time in arrivalOptions(
                              suggested: state.suggestedStart ?? session.start,
                              selected: state.start,
                            ))
                              ChoiceChip(
                                key: ValueKey('move-start-${time.toHhMm()}'),
                                label: Text(time.toHhMm()),
                                selected: time == state.start,
                                onSelected: frozen
                                    ? null
                                    : (_) => controller.setStart(time),
                              ),
                            ActionChip(
                              key: const ValueKey('move-start-other'),
                              avatar: const Icon(Icons.schedule),
                              label: Text(l10n.bookingStartOther),
                              onPressed: frozen
                                  ? null
                                  : () => unawaited(
                                      _pickTime(context, state, controller),
                                    ),
                            ),
                          ],
                        ),
                        if (state.suggestedStart case final suggested?) ...[
                          const SizedBox(height: 8),
                          SessionHelp(
                            l10n.bookingStartSuggested(suggested.toHhMm()),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            _MoveBar(state: state, controller: controller),
          ],
        ),
      ),
    );
  }
}

/// La fecha nueva y lo que dijo el servidor. Toda la fila abre el
/// calendario: un solo objetivo, también para el lector de pantalla.
class _DateTile extends StatelessWidget {
  const _DateTile({required this.state, required this.onEdit});

  final MoveSessionState state;

  /// null: no se puede cambiar (se está moviendo o ya no se puede).
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final formats = RequestFormats(context);
    final check = state.currentCheck;

    ({IconData icon, Color color, String text})? status;
    if (state.changed) {
      if (check != null) {
        status = switch (check.status) {
          BookingDayStatus.ok when !check.weekTaken => (
            icon: Icons.check_circle_outline,
            color: colors.primary,
            text: l10n.bookingDayStatus(check.status),
          ),
          BookingDayStatus.busy => (
            icon: Icons.block,
            color: colors.error,
            text: l10n.bookingDayStatus(check.status),
          ),
          BookingDayStatus.ok => (
            icon: Icons.block,
            color: colors.error,
            text: l10n.moveBlockWeekTaken,
          ),
          _ => (
            icon: Icons.warning_amber_outlined,
            color: colors.tertiary,
            text: l10n.bookingDayStatus(check.status),
          ),
        };
      } else if (state.checksStatus == MoveChecksStatus.loading) {
        status = (
          icon: Icons.hourglass_empty,
          color: colors.onSurfaceVariant,
          text: l10n.bookingStatusChecking,
        );
      }
    }

    return Semantics(
      hint: onEdit == null ? null : l10n.bookingChangeDate(1, 1),
      child: ListTile(
        key: const ValueKey('move-date'),
        enabled: onEdit != null,
        contentPadding: EdgeInsets.zero,
        leading: status == null
            ? const Icon(Icons.event_outlined)
            : Icon(status.icon, color: status.color),
        title: Text(formats.longDate(state.date)),
        subtitle: status == null
            ? null
            : Text(
                status.text,
                key: const ValueKey('move-date-status'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: status.color,
                ),
              ),
        trailing: const Icon(Icons.edit_calendar_outlined),
        onTap: onEdit,
      ),
    );
  }
}

class _MoveBar extends StatelessWidget {
  const _MoveBar({required this.state, required this.controller});

  final MoveSessionState state;
  final MoveSessionController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = RequestFormats(context);
    final failure = state.failure;
    final blocker = failure == null ? state.blocker : null;
    final date = formats.shortDate(state.date);

    return SessionBottomBar(
      children: [
        if (failure != null) ...[
          // liveRegion: el lector de pantalla la anuncia al aparecer.
          Semantics(
            liveRegion: true,
            child: Text(
              l10n.sessionFailure(
                failure,
                operation: SessionOperation.move,
                formatDate: formats.shortDate,
              ),
              key: const ValueKey('move-failure'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (blocker != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              switch (blocker) {
                MoveBlocker.unchanged => l10n.moveSameAsNow,
                MoveBlocker.weekTaken => l10n.moveBlockWeekTaken,
                MoveBlocker.clash => l10n.moveBlockClash,
              },
              key: const ValueKey('move-blocker'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: blocker == MoveBlocker.unchanged
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.error,
              ),
            ),
          )
        else if (failure == null && state.changed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              l10n.moveSummary(date, state.start.toHhMm()),
              key: const ValueKey('move-summary'),
              style: theme.textTheme.bodyMedium,
            ),
          ),
        FilledButton(
          key: const ValueKey('move-confirm'),
          onPressed: state.canConfirm
              ? () => unawaited(controller.confirm())
              : null,
          child: state.sending
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Flexible(child: Text(l10n.moveSending)),
                  ],
                )
              : Text(l10n.moveConfirm(date)),
        ),
      ],
    );
  }
}
