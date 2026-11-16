// Bloquear (o desbloquear) un rango de días, por ejemplo unas vacaciones:
// el calendario de rango y después un resumen con la nota. Se bloquean todos
// los días del rango, también los que no trabaja, por si mañana suma el
// sábado. Para un solo día es más rápido el botón de la tarjeta del día.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/availability/application/availability_controller.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/availability/presentation/availability_actions.dart';
import 'package:radici/features/requests/application/agenda_controller.dart';
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Lo que eligió la cocinera en el resumen del rango.
sealed class BlockRangeChoice {
  const BlockRangeChoice();
}

/// Bloquear los días que faltan, con [note] (null = sin nota).
final class BlockRangeBlock extends BlockRangeChoice {
  const BlockRangeBlock(this.note);

  final String? note;
}

/// Desbloquear los días bloqueados del rango.
final class BlockRangeUnblock extends BlockRangeChoice {
  const BlockRangeUnblock();
}

/// Elige el rango (de hoy a un año) y bloquea o desbloquea. [context] tiene
/// que estar dentro del ScaffoldMessenger de la agenda.
Future<void> pickAndBlockRange(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  final container = ProviderScope.containerOf(context, listen: false);
  final actions = AvailabilityActions.of(context);
  final today = container.read(romeTodayProvider);

  // Para un solo día hay que tocarlo dos veces: «Salva» se habilita recién
  // con el primero y el último.
  final range = await showDateRangePicker(
    context: context,
    firstDate: today.toDateTime(),
    lastDate: today.addDays(maxRangeDays - 1).toDateTime(),
    currentDate: today.toDateTime(),
    initialEntryMode: DatePickerEntryMode.calendarOnly,
    helpText: l10n.blockRangePickerHelp,
  );
  final snapshot = container.read(availabilityControllerProvider).value;
  if (range == null || snapshot == null || !context.mounted) return;

  final first = CalendarDate.fromDateTime(range.start);
  final last = CalendarDate.fromDateTime(range.end);
  final summary = summarizeRange(first, last, snapshot);
  // Los días del rango con sesiones: bloquearlos no las cancela.
  final sessions = container.read(agendaSessionsByDateProvider);
  final sessionDays = summary.dates.where(sessions.containsKey).length;
  final choice = await showBlockRangeDialog(
    context,
    first: first,
    last: last,
    summary: summary,
    sessionDays: sessionDays,
  );
  switch (choice) {
    case BlockRangeBlock(:final note):
      await actions.block(summary.toBlock, note: note);
    case BlockRangeUnblock():
      await actions.unblock(summary.alreadyBlocked);
    case null:
      break;
  }
}

/// Muestra el resumen del rango de [first] a [last] ([sessionDays]: cuántos
/// de sus días tienen sesiones). Devuelve lo que se eligió, o null si se
/// canceló.
Future<BlockRangeChoice?> showBlockRangeDialog(
  BuildContext context, {
  required CalendarDate first,
  required CalendarDate last,
  required RangeSummary summary,
  int sessionDays = 0,
}) => showDialog<BlockRangeChoice>(
  context: context,
  builder: (_) => BlockRangeDialog(
    first: first,
    last: last,
    summary: summary,
    sessionDays: sessionDays,
  ),
);

class BlockRangeDialog extends StatefulWidget {
  const BlockRangeDialog({
    super.key,
    required this.first,
    required this.last,
    required this.summary,
    this.sessionDays = 0,
  });

  final CalendarDate first;
  final CalendarDate last;
  final RangeSummary summary;

  /// Días del rango con sesiones: bloquearlos no las cancela.
  final int sessionDays;

  @override
  State<BlockRangeDialog> createState() => _BlockRangeDialogState();
}

class _BlockRangeDialogState extends State<BlockRangeDialog> {
  final TextEditingController _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _close(BlockRangeChoice? choice) => Navigator.of(context).pop(choice);

  /// "Dal 21 dic 2026 al 6 gen 2027", o solo la fecha si es un día. Cada
  /// fecha va con espacios que no cortan: el renglón se parte entre las
  /// fechas, nunca en medio de una.
  String _title(AppLocalizations l10n) {
    final formats = RequestFormats(context);
    String date(CalendarDate day) =>
        formats.dayMonthYear(day).replaceAll(' ', '\u00a0');
    return widget.first == widget.last
        ? date(widget.first)
        : l10n.blockRangeTitle(date(widget.first), date(widget.last));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final summary = widget.summary;
    final toBlock = summary.toBlock.length;
    final blocked = summary.alreadyBlocked.length;
    final counts = [
      l10n.blockRangeTotalDays(summary.total),
      l10n.blockRangeWorkingDays(summary.working),
      if (blocked > 0) l10n.blockRangeAlreadyBlocked(blocked),
    ].join(' · ');

    // El alto del teclado se descuenta acá, en el mismo cuadro en que llega:
    // el Dialog lo animaría (100 ms) y el campo enfocado buscaría su lugar
    // antes de tiempo, con el diálogo todavía alto, y quedaría debajo del
    // teclado.
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: _dialog(l10n, counts, toBlock: toBlock, blocked: blocked),
      ),
    );
  }

  Widget _dialog(
    AppLocalizations l10n,
    String counts, {
    required int toBlock,
    required int blocked,
  }) {
    return AlertDialog(
      key: const ValueKey('block-range-dialog'),
      alignment: Alignment.topCenter,
      // Con el teclado abierto el diálogo se achica: el título y la nota se
      // desplazan (el campo enfocado queda a la vista) y los botones quedan
      // fijos abajo. Sin esto, a 375×667 la nota quedaba en una franja de
      // unos pocos píxeles.
      scrollable: true,
      // Más chico que el de los otros diálogos: son dos fechas.
      titleTextStyle: Theme.of(context).textTheme.titleLarge,
      // En un teléfono los tres botones no entran en una fila y se apilan.
      actionsOverflowButtonSpacing: 8,
      title: Text(_title(l10n)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(counts, key: const ValueKey('block-range-summary')),
          if (widget.sessionDays > 0) ...[
            const SizedBox(height: 8),
            Text(
              l10n.blockRangeSessionDays(widget.sessionDays),
              key: const ValueKey('block-range-sessions'),
            ),
          ],
          if (toBlock > 0) ...[
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('block-range-note'),
              controller: _note,
              maxLength: maxNoteLength,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: l10n.availabilityNoteLabel,
                hintText: l10n.availabilityNoteHint,
                // Fuera de la pista: se ve siempre (también sin foco) y no
                // se corta en una línea.
                helperText: l10n.availabilityNoteHelper,
                helperMaxLines: 2,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('block-range-cancel'),
          onPressed: () => _close(null),
          child: Text(l10n.actionCancel),
        ),
        if (blocked > 0)
          OutlinedButton(
            key: const ValueKey('block-range-unblock'),
            onPressed: () => _close(const BlockRangeUnblock()),
            child: Text(l10n.blockRangeUnblock(blocked)),
          ),
        if (toBlock > 0)
          FilledButton(
            key: const ValueKey('block-range-confirm'),
            onPressed: () => _close(BlockRangeBlock(normalizeNote(_note.text))),
            child: Text(l10n.blockRangeConfirm(toBlock)),
          ),
      ],
    );
  }
}

/// Botón flotante «Blocca giorni» de la agenda. Deshabilitado mientras la
/// disponibilidad carga.
class BlockRangeButton extends ConsumerWidget {
  const BlockRangeButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final ready = ref.watch(availabilityReadyProvider);
    return FloatingActionButton.extended(
      key: const ValueKey('agenda-block-range'),
      onPressed: ready ? () => unawaited(pickAndBlockRange(context)) : null,
      icon: const Icon(Icons.event_busy_outlined),
      label: Text(l10n.blockRangeAction),
      // Sin onPressed el botón flotante no cambia de aspecto: se atenúa acá.
      backgroundColor: ready ? null : colors.onSurface.withValues(alpha: 0.12),
      foregroundColor: ready ? null : colors.onSurface.withValues(alpha: 0.38),
      elevation: ready ? null : 0,
    );
  }
}
