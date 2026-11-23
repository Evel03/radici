// Por dónde se llega al menú de una semana:
//
// - [WeekMenuBlock], en la ficha de la sesión: «Menú de la semana», si ya
//   tiene menú (cuántos platos y renglones), qué pasó con su envío a la
//   clienta y los botones para armarlo o editarlo y para mandárselo. Una
//   sesión cocinada o cobrada muestra el que tiene, sin botones; una
//   cancelada, nada. Otra semana de un presupuesto sin aceptar no se manda
//   todavía (sale cuando la clienta lo acepte): lo dice.
// - [BookingWeekMenus], en el detalle de una reserva (un pedido aceptado):
//   sus semanas vivas con el menú de cada una y su envío; tocar una abre su
//   menú (y ahí se manda).
//
// Solo muestran providers (week_menu_summaries.dart).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/presentation/session_labels.dart';
import 'package:radici/features/sessions/presentation/session_widgets.dart';
import 'package:radici/features/week_menu/application/week_menu_summaries.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';
import 'package:radici/features/week_menu/presentation/menu_send_screen.dart';
import 'package:radici/features/week_menu/presentation/menu_send_status_view.dart';
import 'package:radici/features/week_menu/presentation/week_menu_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

/// «Menú de la semana» en la ficha de [session].
class WeekMenuBlock extends ConsumerWidget {
  const WeekMenuBlock({super.key, required this.session, this.quoteRole});

  final CookingSession session;

  /// Una semana de un presupuesto sin aceptar: la 1 sale con él; las demás
  /// ([QuoteWeekRole.later]) se mandan cuando lo acepte («Mandar»
  /// deshabilitado, con el porqué).
  final QuoteWeekRole? quoteRole;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!session.isLive) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final editable = isMenuEditable(session.status);
    final summary = ref.watch(weekMenuSummaryProvider(session.id));
    final saved = summary.value?.saved ?? false;
    // Una cocinada o cobrada sin menú no dice nada (son todas las de antes).
    if (!editable && !saved) return const SizedBox.shrink();
    final version = summary.value?.version;
    final everSent = ref.watch(
      latestMenuSendProvider(session.id).select((send) => send.value != null),
    );
    // Se manda el menú guardado, con algún plato: su versión (null si no).
    // Otra semana de un presupuesto sin aceptar, todavía no.
    final afterQuote = quoteRole == QuoteWeekRole.later;
    final sendVersion =
        isMenuSendable(session) &&
            !afterQuote &&
            (summary.value?.dishes ?? 0) > 0
        ? version
        : null;

    return Column(
      key: const ValueKey('session-menu'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SessionSection(l10n.weekMenuTitle),
        ...summary.when(
          data: (summary) => [
            MergeSemantics(
              child: Text(
                summary.saved
                    ? l10n.weekMenuSummaryText(summary)
                    : l10n.weekMenuNone,
                key: const ValueKey('session-menu-summary'),
                style: theme.textTheme.bodyLarge,
              ),
            ),
          ],
          loading: () => [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(
                key: const ValueKey('session-menu-loading'),
                semanticsLabel: l10n.weekMenuTitle,
              ),
            ),
          ],
          error: (_, _) => [
            MergeSemantics(
              child: Text(
                l10n.weekMenuLoadFailed,
                key: const ValueKey('session-menu-error'),
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: const ValueKey('session-menu-retry'),
                onPressed: () =>
                    ref.invalidate(weekMenuSummaryProvider(session.id)),
                child: Text(l10n.actionRetry),
              ),
            ),
          ],
        ),
        if (session.requestId != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SessionMenuSendStatus(
              sessionId: session.id,
              savedVersion: version,
              keyPrefix: 'session-menu-status',
              confirmedWeek: session.status.shown == SessionStatus.confirmed,
            ),
          ),
        if (editable) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                key: const ValueKey('session-menu-open'),
                onPressed: () =>
                    unawaited(context.push(AppRoutes.sessionMenu(session.id))),
                icon: const Icon(Icons.restaurant_menu),
                label: Text(saved ? l10n.weekMenuEdit : l10n.weekMenuBuild),
              ),
              if (isMenuSendable(session))
                OutlinedButton.icon(
                  key: const ValueKey('session-menu-send'),
                  onPressed: sendVersion == null
                      ? null
                      : () => unawaited(
                          showMenuSendScreen(
                            context,
                            sessionId: session.id,
                            menuVersion: sendVersion,
                          ),
                        ),
                  icon: const Icon(Icons.send_outlined),
                  label: Text(
                    everSent ? l10n.menuSendAgain : l10n.menuSendAction,
                  ),
                ),
            ],
          ),
          if (afterQuote && isMenuSendable(session))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: MergeSemantics(
                child: Text(
                  l10n.menuSendAfterQuote,
                  key: const ValueKey('session-menu-after-quote'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// «Menús de las semanas» en el detalle de la reserva [requestId].
class BookingWeekMenus extends ConsumerWidget {
  const BookingWeekMenus({super.key, required this.requestId});

  final String requestId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final weeks = ref.watch(bookingWeekMenusProvider(requestId));
    // Sin semanas vivas (todas canceladas), nada.
    if (weeks.value?.isEmpty ?? false) return const SizedBox.shrink();
    return Column(
      key: const ValueKey('booking-menus'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SessionSection(l10n.bookingMenusTitle),
        ...weeks.when(
          data: (weeks) => [for (final week in weeks) _WeekTile(week: week)],
          loading: () => [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(
                key: const ValueKey('booking-menus-loading'),
                semanticsLabel: l10n.bookingMenusTitle,
              ),
            ),
          ],
          error: (_, _) => [
            MergeSemantics(
              child: Text(
                l10n.weekMenuLoadFailed,
                key: const ValueKey('booking-menus-error'),
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: const ValueKey('booking-menus-retry'),
                onPressed: () =>
                    ref.invalidate(bookingWeekMenusProvider(requestId)),
                child: Text(l10n.actionRetry),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Una semana de la reserva: la fecha, su menú y qué pasó con su envío (con
/// el mensaje de la clienta entero, si pidió cambios). Abre el editor si
/// todavía se puede armar.
class _WeekTile extends StatelessWidget {
  const _WeekTile({required this.week});

  final BookingWeekMenu week;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final formats = RequestFormats(context);
    final session = week.session;
    final date = formats.shortDate(session.date);
    final editable = isMenuEditable(session.status);
    final summary = week.summary;
    final tile = ListTile(
      key: ValueKey('booking-menu-${session.id}'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        summary.saved ? Icons.restaurant_menu : Icons.edit_note_outlined,
      ),
      title: Text(
        week.weeks > 1 ? l10n.bookingWeekTitle(week.week, date) : date,
      ),
      subtitle: Text(
        [
          if (summary.saved)
            l10n.weekMenuSummaryText(summary)
          else
            l10n.weekMenuNone,
          if (session.status.shown != SessionStatus.confirmed)
            l10n.sessionStatus(session.status),
        ].join(' · '),
        key: ValueKey('booking-menu-summary-${session.id}'),
      ),
      trailing: editable ? const Icon(Icons.chevron_right) : null,
      onTap: editable
          ? () => unawaited(context.push(AppRoutes.sessionMenu(session.id)))
          : null,
    );
    // Sin menú guardado ni envío, el renglón ya lo dice todo.
    if (!summary.saved && week.send == null) return tile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        tile,
        // Fuera del renglón que se toca: el mensaje de la clienta se puede
        // seleccionar. Alineado con el título (ícono de 24 y espacio de 16).
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 40, bottom: 8),
          child: MenuSendStatusView(
            status: bookingWeekSendStatus(week),
            keyPrefix: 'booking-menu-status-${session.id}',
          ),
        ),
      ],
    );
  }
}
