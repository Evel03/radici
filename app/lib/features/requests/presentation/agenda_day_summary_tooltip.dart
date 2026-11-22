// El cartel de un día del mes de la agenda: al pasar el mouse por la celda
// (web y escritorio) o al mantenerla apretada (teléfono), el resumen de sus
// sesiones y de los pedidos que lo preferían (agendaDaySummary). Tocar la
// celda sigue eligiendo el día.
//
// Va debajo de la celda (arriba si abajo no entra) sin taparla, no atrapa el
// mouse (al bajar a la celda de abajo se abre la suya) y se cierra al salir de
// la celda, unos segundos después de soltarla o al tocar cualquier otra cosa.
// En el teléfono se queda con el toque: tocarlo lo cierra sin tocar lo que
// tapa. Es una tarjeta como las de la app, con el punto de la celda: el
// principal para una sesión y el terciario para un pedido. El lector de
// pantalla no lo lee acá: el mismo texto va en la celda (agendaSummaryText).
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/domain/agenda_day_summary.dart';
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/presentation/session_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Cuánto hay que dejar el mouse sobre la celda para que se abra el cartel:
/// al recorrer el mes no se abre uno en cada celda. Con uno abierto, el de la
/// celda siguiente se abre enseguida.
const Duration agendaSummaryHoverDelay = Duration(milliseconds: 400);

/// Cuánto queda abierto el cartel después de soltar la celda en el teléfono
/// (si antes no se toca otra cosa): lo que hace falta para leerlo.
const Duration agendaSummaryTouchDelay = Duration(seconds: 6);

/// Espacio que no corta.
const String _nbsp = '\u00a0';

/// Separador de los tramos de un renglón, como en las horas de una sesión
/// (session_labels.dart): el renglón se parte solo después de un «·».
const String _separator = '$_nbsp· ';

/// Los tramos de un renglón, cada uno con espacios que no cortan.
String _line(Iterable<String> parts) =>
    [for (final part in parts) part.replaceAll(' ', _nbsp)].join(_separator);

extension AgendaSummaryLabels on AppLocalizations {
  /// «10:00–13:00 · Settimana 2 di 4 · 4 persone · Confermata · Città Alta»:
  /// la llegada y el fin de la cocina, y lo demás si lo hay.
  String agendaSessionSummaryLine(AgendaSessionSummary item) => _line([
    '${SessionTimes.hhmm(item.arrival)}–${SessionTimes.hhmm(item.end)}',
    if (item.week case final week?) sessionWeekOf(week.week, week.weeks),
    if (item.people case final people?) requestPeopleCount(people),
    sessionStatus(item.status),
    ?item.zone,
  ]);

  /// «Settimana di pasti · Nuova».
  String agendaRequestSummaryLine(AgendaRequestSummary item) => _line([
    requestType(item.type),
    requestStatusOf(item.status, seen: item.seen),
  ]);

  /// El renglón de [item] debajo de su nombre.
  String agendaSummaryLine(AgendaSummaryItem item) => switch (item) {
    final AgendaSessionSummary session => agendaSessionSummaryLine(session),
    final AgendaRequestSummary request => agendaRequestSummaryLine(request),
  };

  /// Todo el cartel en un texto, para el lector de pantalla: «Giulia Rossi,
  /// 10:00–13:00 · …; Marco Bianchi, Settimana di pasti · Nuova; e altre 2».
  String agendaSummaryText(AgendaDaySummary summary) => [
    for (final item in summary.items)
      [
        if (item.name.trim().isNotEmpty) item.name.trim(),
        agendaSummaryLine(item),
      ].join(', '),
    if (summary.more > 0) agendaSummaryMore(summary.more),
  ].join('; ');
}

/// El cartel de [day] sobre [child] (la celda). Sin [summary], solo [child].
class AgendaDaySummaryTooltip extends StatefulWidget {
  const AgendaDaySummaryTooltip({
    super.key,
    required this.day,
    required this.summary,
    required this.child,
  });

  final CalendarDate day;
  final AgendaDaySummary summary;
  final Widget child;

  @override
  State<AgendaDaySummaryTooltip> createState() =>
      _AgendaDaySummaryTooltipState();
}

class _AgendaDaySummaryTooltipState extends State<AgendaDaySummaryTooltip> {
  /// Si lo último que pasó por la celda o la apretó fue un mouse (al
  /// principio, sí). Con el dedo o el lápiz, no.
  bool _mouse = true;

  /// Anota si [event] es de un mouse. Llega antes de que se abra el cartel:
  /// el mouse tiene que quedarse encima (agendaSummaryHoverDelay) y el dedo,
  /// apretar medio segundo.
  void _track(PointerEvent event) {
    final mouse = event.kind == PointerDeviceKind.mouse;
    if (mouse != _mouse) setState(() => _mouse = mouse);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.summary.isEmpty) return widget.child;
    return RawTooltip(
      // Lo lee la celda (agendaSummaryText): acá no se repite.
      semanticsTooltip: null,
      hoverDelay: agendaSummaryHoverDelay,
      touchDelay: agendaSummaryTouchDelay,
      // Con el mouse no lo atrapa: tapa las celdas de abajo, que siguen
      // respondiendo (al bajar a una se abre la suya). Con el dedo se queda
      // con el toque: tocarlo lo cierra, como tocar cualquier otra cosa, sin
      // tocar lo que tapa y no se ve (otra celda, «Blocca questo giorno», una
      // sesión).
      ignorePointer: _mouse,
      positionDelegate: _belowOrAboveCell,
      tooltipBuilder: (context, animation) => FadeTransition(
        opacity: animation,
        child: _SummaryCard(day: widget.day, summary: widget.summary),
      ),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _track,
        // En una computadora con pantalla táctil, el mouse vuelve a pasar.
        onPointerHover: _track,
        child: widget.child,
      ),
    );
  }
}

/// Separación entre la celda y el cartel.
const double _gap = 4;

/// Centrado debajo de la celda, o arriba si abajo no entra: nunca la tapa.
Offset _belowOrAboveCell(TooltipPositionContext context) =>
    positionDependentBox(
      size: context.overlaySize,
      childSize: context.tooltipSize,
      target: context.target,
      verticalOffset: context.targetSize.height / 2 + _gap,
      preferBelow: true,
    );

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.day, required this.summary});

  final CalendarDate day;
  final AgendaDaySummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return ExcludeSemantics(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        // Como las tarjetas de la app (color y borde lino), con sombra: flota
        // sobre el mes.
        child: Material(
          key: ValueKey('agenda-day-summary-${day.toIso()}'),
          color: theme.cardTheme.color ?? colors.surfaceContainerLow,
          shape:
              theme.cardTheme.shape ??
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          elevation: 3,
          shadowColor: colors.shadow,
          surfaceTintColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                for (final item in summary.items) _SummaryItem(item: item),
                if (summary.more > 0)
                  Text(
                    l10n.agendaSummaryMore(summary.more),
                    key: ValueKey('agenda-day-summary-more-${day.toIso()}'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
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

class _SummaryItem extends StatelessWidget {
  const _SummaryItem({required this.item});

  final AgendaSummaryItem item;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (itemKey, marker) = switch (item) {
      AgendaSessionSummary(:final sessionId) => (
        'agenda-day-summary-session-$sessionId',
        colors.primary,
      ),
      AgendaRequestSummary(:final requestId) => (
        'agenda-day-summary-request-$requestId',
        colors.tertiary,
      ),
    };
    final name = item.name.trim();
    return Row(
      key: ValueKey(itemKey),
      // Del ancho del texto (hasta el del cartel): uno corto no lo estira.
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // El punto de la celda, a la altura del nombre.
        Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(top: 6, right: 8),
          decoration: BoxDecoration(shape: BoxShape.circle, color: marker),
        ),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (name.isNotEmpty)
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colors.onSurface,
                  ),
                ),
              Text(
                l10n.agendaSummaryLine(item),
                key: ValueKey('$itemKey-line'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
