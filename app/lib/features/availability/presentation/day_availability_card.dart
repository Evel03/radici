// Disponibilidad de un día en la agenda: si la web lo ofrece, el feriado,
// cuántos pedidos lo preferían, si tiene sesiones (bloquearlo no las cancela)
// y los botones para bloquearlo o desbloquearlo, con su nota privada. En la
// vista de semana va compacta.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/availability/application/availability_controller.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/availability/presentation/availability_actions.dart';
import 'package:radici/features/availability/presentation/availability_labels.dart';
import 'package:radici/features/availability/presentation/note_dialog.dart';
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Lo que tarda en entrar un aviso (SnackBar, 250 ms), que mientras tanto
/// empuja hacia arriba el botón flotante.
const Duration _snackBarEntrance = Duration(milliseconds: 300);

/// Desplaza la lista lo justo para que la caja de [context] se vea entera y
/// por encima del botón flotante de la agenda. Con [afterSnackBar], espera a
/// que termine de entrar el aviso que se acaba de mostrar: a 375×667, el de
/// «Annulla» sube el botón hasta dejar 120 px ocupados abajo, y el de error
/// (dos renglones), 140.
void revealAgendaCard(BuildContext context, {bool afterSnackBar = false}) {
  final binding = WidgetsBinding.instance;
  Duration? start;
  void afterFrame(Duration timeStamp) {
    if (!context.mounted) return;
    final elapsed = timeStamp - (start ??= timeStamp);
    if (afterSnackBar && elapsed < _snackBarEntrance) {
      binding
        ..addPostFrameCallback(afterFrame)
        ..scheduleFrame();
      return;
    }
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    box.showOnScreen(
      rect: Offset.zero &
          Size(box.size.width, box.size.height + _clearance(context)),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  binding.addPostFrameCallback(afterFrame);
}

/// Cuánto ocupa, desde abajo de la lista que contiene a [context], el botón
/// flotante con lo que tenga debajo (el aviso, si hay uno), más un margen.
double _clearance(BuildContext context) {
  final list = Scrollable.maybeOf(context)?.context.findRenderObject();
  final fabTop = _floatingButtonTop(context);
  if (list is! RenderBox || !list.hasSize || fabTop == null) return 0;
  final listBottom = list.localToGlobal(Offset(0, list.size.height)).dy;
  return math.max(0, listBottom - fabTop) + 8;
}

/// El borde de arriba del botón flotante del Scaffold de [context] (el más
/// alto, si hay varios), en coordenadas de la pantalla. Se busca en el árbol
/// porque Scaffold.geometryOf solo se puede leer mientras se pinta.
double? _floatingButtonTop(BuildContext context) {
  final scaffold = Scaffold.maybeOf(context);
  if (scaffold == null) return null;
  double? top;
  void visit(Element element) {
    if (element.widget is FloatingActionButton) {
      final box = element.renderObject;
      if (box is RenderBox && box.attached && box.hasSize) {
        final y = box.localToGlobal(Offset.zero).dy;
        top = math.min(top ?? y, y);
      }
      return;
    }
    element.visitChildren(visit);
  }

  scaffold.context.visitChildElements(visit);
  return top;
}

class DayAvailabilityCard extends ConsumerWidget {
  const DayAvailabilityCard({super.key, required this.day, this.compact = false});

  final CalendarDate day;

  /// Vista de semana: solo el bloqueo (con su nota), el feriado y el botón;
  /// la carga y los errores se muestran una sola vez arriba
  /// ([AvailabilityLoadState]).
  final bool compact;

  /// Corre [action] y vuelve a traer la tarjeta a la vista: cambió de alto
  /// (otros botones, la nota) y el aviso que aparece empuja hacia arriba el
  /// botón flotante.
  Future<void> _run(
    BuildContext context,
    Future<void> Function(AvailabilityActions actions) action,
  ) async {
    await action(AvailabilityActions.of(context));
    if (context.mounted) revealAgendaCard(context, afterSnackBar: true);
  }

  Future<void> _editNote(BuildContext context, String? current) async {
    final actions = AvailabilityActions.of(context);
    final note = await showNoteDialog(context, initial: current);
    if (note == null) return;
    await actions.setNote(day, note);
    if (context.mounted) revealAgendaCard(context, afterSnackBar: true);
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
    // Bloquear un día con sesiones no las cancela (se cancelan desde su
    // ficha): se avisa también en la semana, junto al botón.
    final showSessions =
        info.sessionCount > 0 &&
        (info.status == DayStatus.open || info.status == DayStatus.blocked);
    // En la semana hay un botón igual en cada día: VoiceOver dice también la
    // fecha (en la tarjeta del mes, el título de arriba ya la dice).
    String? spokenWithDate(String label) =>
        compact ? '$label, ${RequestFormats(context).longDate(day)}' : null;

    final buttons = <Widget>[
      if (info.canBlock)
        _actionButton(
          key: ValueKey('availability-block-$iso'),
          label: l10n.availabilityBlockDay,
          semanticsLabel: spokenWithDate(l10n.availabilityBlockDay),
          tonal: !compact,
          onPressed: saving
              ? null
              : () => unawaited(_run(context, (a) => a.block([day]))),
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
              : () => unawaited(_run(context, (a) => a.unblock([day]))),
          child: Text(
            l10n.availabilityUnblockDay,
            semanticsLabel: spokenWithDate(l10n.availabilityUnblockDay),
          ),
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
      if (showSessions)
        _IconLine(
          key: ValueKey('availability-sessions-$iso'),
          icon: Icons.restaurant_outlined,
          text: l10n.availabilitySessionsThatDay(info.sessionCount),
          style: secondary,
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
    required String? semanticsLabel,
    required bool tonal,
    required VoidCallback? onPressed,
  }) {
    final text = Text(label, semanticsLabel: semanticsLabel);
    return tonal
        ? FilledButton.tonal(key: key, onPressed: onPressed, child: text)
        : OutlinedButton(key: key, onPressed: onPressed, child: text);
  }
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
    super.key,
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
