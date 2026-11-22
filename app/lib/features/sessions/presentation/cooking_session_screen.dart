// Ficha de una sesión de cocina (`/sessioni/:id`, a pantalla completa): el día
// y las horas (salidas de la sesión), «Semana k de N» sin contar las
// canceladas, «Come arrivare» (la dirección en Mapas), WhatsApp y llamar (sin
// dirección, el botón para agregarla: el formulario web no la pide); las
// alergias resaltadas (la nota del pedido y, con gluten, la de contaminación
// cruzada, SPEC §5.6); el menú de la semana (cuántos platos y renglones, qué
// pasó con su envío a la clienta y los botones para armarlo o editarlo y para
// mandárselo, SPEC 5.8); los datos de la clienta y las semanas de su reserva;
// en la última sesión viva de una reserva semanal, «Rinnova» al final. Una
// semana de un presupuesto sin aceptar (`held`, SPEC 5.8) avisa que moverla o
// cancelarla cambia el presupuesto (el detalle del pedido dice entonces que
// hay que mandarlo de nuevo).
// Abajo, Mover (con «Annulla» después) y Cancelar (con confirmación y
// «también las siguientes»; si alguna ya está cobrada, el aviso dice cuál y
// qué se puede hacer). Abierta con un enlace directo, la flecha de volver
// lleva a la Agenda.
//
// Solo lee providers: la lógica está en SessionDetailController y
// SessionCommands. Lleva la dirección y datos de salud: nada se loguea.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart'
    show LoadErrorView;
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/features/sessions/application/session_links.dart';
import 'package:radici/features/sessions/application/session_renewal.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_api.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';
import 'package:radici/features/sessions/presentation/cancel_session_dialog.dart';
import 'package:radici/features/sessions/presentation/client_address_dialog.dart';
import 'package:radici/features/sessions/presentation/has_payments_dialog.dart';
import 'package:radici/features/sessions/presentation/move_session_screen.dart';
import 'package:radici/features/sessions/presentation/session_actions.dart';
import 'package:radici/features/sessions/presentation/session_labels.dart';
import 'package:radici/features/sessions/presentation/session_widgets.dart';
import 'package:radici/features/week_menu/application/week_menu_summaries.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart'
    show quoteWeekRole;
import 'package:radici/features/week_menu/presentation/week_menu_block.dart';
import 'package:radici/l10n/app_localizations.dart';

class CookingSessionScreen extends ConsumerWidget {
  const CookingSessionScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final detail = ref.watch(sessionDetailProvider(sessionId));
    final data = detail.value;
    final session = data?.session;

    // Sus propios avisos: el de «Annulla» después de mover sale solo acá. Con
    // el ScaffoldMessenger de la app, mientras la hoja «Sposta» se cerraba el
    // aviso también se armaba en su Scaffold, y en la web (con la semántica
    // activa) el foco recorría botones ya desmontados: un error en consola.
    // Uno por sesión: si la ruta pasa a otra sesión (go reutiliza la página),
    // el aviso de la anterior no queda en esta.
    return ScaffoldMessenger(
      key: ValueKey('session-messenger-$sessionId'),
      child: Scaffold(
        appBar: AppBar(
          // Abierta con un enlace directo, sin nada debajo en la pila (y sin
          // la flecha de siempre): vuelve a la Agenda. Es lo mismo que mira
          // la barra para poner su flecha, así nunca van las dos.
          leading: ModalRoute.of(context)?.impliesAppBarDismissal ?? false
              ? null
              : BackButton(
                  key: const ValueKey('session-back'),
                  onPressed: () => context.go(AppRoutes.agenda),
                ),
          title: Text(
            session?.displayName ?? l10n.sessionTitle,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: detail.when(
          data: (data) => data == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      l10n.sessionNotFound,
                      key: const ValueKey('session-not-found'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : _SessionView(detail: data),
          error: (_, _) => LoadErrorView(
            message: l10n.sessionLoadError,
            onRetry: () => ref.invalidate(sessionDetailProvider(sessionId)),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
        ),
        // Mover y cancelar, abajo: la acción principal en el tercio inferior.
        bottomNavigationBar:
            data != null && (data.session.canMove || data.session.canCancel)
            ? _ActionsBar(detail: data)
            : null,
      ),
    );
  }
}

class _SessionView extends ConsumerWidget {
  const _SessionView({required this.detail});

  final SessionDetail detail;

  /// Deslizar para actualizar: si falla, queda lo que había y se avisa.
  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = AppLocalizations.of(context).inboxRefreshError;
    // El menú también puede haber cambiado en otro teléfono, y la clienta
    // puede haber contestado al envío.
    ref
      ..invalidate(weekMenuSummaryProvider(detail.session.id))
      ..invalidate(latestMenuSendProvider(detail.session.id));
    try {
      await ref
          .read(sessionDetailProvider(detail.session.id).notifier)
          .reload();
    } on SessionFailure {
      if (messenger.mounted) {
        messenger.showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = detail.session;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: sessionMaxContentWidth),
        child: RefreshIndicator(
          onRefresh: () => _refresh(context, ref),
          child: ListView(
            key: const ValueKey('session-detail'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _Header(detail: detail),
              // Una semana de un presupuesto sin aceptar: moverla o
              // cancelarla cambia el presupuesto (SPEC 5.8). Con una sola
              // semana viva, «una fecha».
              if (session.status == SessionStatus.held)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: MergeSemantics(
                    child: Text(
                      AppLocalizations.of(context)
                          .sessionQuoteHeldHint(detail.position?.weeks ?? 1),
                      key: const ValueKey('session-quote-held'),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              _ContactButtons(session: session),
              SessionAllergies(session: session),
              WeekMenuBlock(
                session: session,
                quoteRole: quoteWeekRole(session, detail.booking),
              ),
              _Client(session: session),
              if (detail.weeks.length > 1) _Weeks(detail: detail),
              // Al final: el día de la última sesión es el de cocinar, y
              // «Come arrivare», WhatsApp y las alergias van primero.
              _LastOfBooking(session: session),
            ],
          ),
        ),
      ),
    );
  }
}

/// El día, «Semana k de N», el estado (si no está confirmada; una vieja en
/// shopping_done se ve como confirmada) y las horas.
class _Header extends StatelessWidget {
  const _Header({required this.detail});

  final SessionDetail detail;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = RequestFormats(context);
    final session = detail.session;
    final position = detail.position;
    final status = session.status.shown == SessionStatus.confirmed
        ? null
        : [
            l10n.sessionStatus(session.status),
            if (!session.isLive) ?l10n.cancelReasonOf(session.cancelReason),
          ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          formats.longDate(session.date),
          key: const ValueKey('session-date'),
          style: theme.textTheme.titleLarge,
        ),
        if (position != null || status != null) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (position != null)
                Text(
                  l10n.sessionWeekOf(position.week, position.weeks),
                  key: const ValueKey('session-week'),
                  style: theme.textTheme.titleSmall,
                ),
              if (status != null)
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: session.isLive
                        ? theme.colorScheme.secondaryContainer
                        : theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    child: Text(
                      status,
                      key: const ValueKey('session-status'),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: session.isLive
                            ? theme.colorScheme.onSecondaryContainer
                            : theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Text(
          l10n.sessionTimesLine(session),
          key: const ValueKey('session-times'),
          style: theme.textTheme.bodyLarge,
        ),
      ],
    );
  }
}

/// «Come arrivare», WhatsApp y llamar. Sin dirección (las reservas que llegan
/// por la web), WhatsApp pasa a ser el principal y en lugar de «Come
/// arrivare» va «Aggiungi indirizzo».
class _ContactButtons extends ConsumerWidget {
  const _ContactButtons({required this.session});

  final CookingSession session;

  Future<void> _launch(BuildContext context, WidgetRef ref, Uri uri) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = AppLocalizations.of(context).launchFailed;
    // Directo desde el toque: en la web, esperar algo antes haría que el
    // navegador bloquee la ventana nueva.
    final opened = await ref.read(linkLauncherProvider).launch(uri);
    if (!opened && messenger.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final links = ref.watch(sessionLinksProvider(session.id));
    final directions = links?.directions;
    final whatsApp = links?.whatsApp;
    final call = links?.call;
    final hasAddress = session.address != null;
    VoidCallback? launch(Uri? uri) =>
        uri == null ? null : () => _launch(context, ref, uri);
    const whatsAppKey = ValueKey('session-whatsapp');
    const whatsAppIcon = Icon(Icons.chat_outlined);
    final whatsAppLabel = Text(l10n.actionWhatsApp);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (hasAddress) ...[
              FilledButton.icon(
                key: const ValueKey('session-directions'),
                onPressed: launch(directions),
                icon: const Icon(Icons.directions_outlined),
                label: Text(l10n.sessionDirections),
              ),
              OutlinedButton.icon(
                key: whatsAppKey,
                onPressed: launch(whatsApp),
                icon: whatsAppIcon,
                label: whatsAppLabel,
              ),
            ] else
              FilledButton.icon(
                key: whatsAppKey,
                onPressed: launch(whatsApp),
                icon: whatsAppIcon,
                label: whatsAppLabel,
              ),
            OutlinedButton.icon(
              key: const ValueKey('session-call'),
              onPressed: launch(call),
              icon: const Icon(Icons.call_outlined),
              label: Text(l10n.actionCall),
            ),
            if (!hasAddress)
              OutlinedButton.icon(
                key: const ValueKey('session-add-address'),
                onPressed: () => unawaited(editClientAddress(context, session)),
                icon: const Icon(Icons.add_location_alt_outlined),
                label: Text(l10n.sessionAddAddress),
              ),
          ],
        ),
        if (!hasAddress) ...[
          const SizedBox(height: 8),
          // Un nodo propio: el lector de pantalla lo lee después de los
          // botones, como se ve (si no, iba antes, como su padre).
          MergeSemantics(
            child: Text(
              l10n.sessionNoAddress,
              key: const ValueKey('session-no-address'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// La dirección, la zona, el teléfono, el pedido, las porciones y las notas.
class _Client extends StatelessWidget {
  const _Client({required this.session});

  final CookingSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final request = session.request;
    final notes = request?.notes?.trim() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SessionSection(l10n.sessionSectionClient),
        if (session.address case final address?)
          Row(
            children: [
              Expanded(
                child: SessionInfoRow(
                  label: l10n.sessionAddress,
                  value: address,
                  selectable: true,
                  valueKey: const ValueKey('session-address'),
                ),
              ),
              IconButton(
                key: const ValueKey('session-edit-address'),
                tooltip: l10n.sessionEditAddress,
                onPressed: () => unawaited(editClientAddress(context, session)),
                icon: const Icon(Icons.edit_location_alt_outlined),
              ),
            ],
          ),
        if (session.zone case final zone? when zone.isNotEmpty)
          SessionInfoRow(label: l10n.detailZone, value: zone),
        if (session.contactPhone case final phone?)
          SessionInfoRow(
            label: l10n.detailPhone,
            value: phone,
            selectable: true,
          ),
        if (request != null)
          SessionInfoRow(
            label: l10n.detailSectionRequest,
            value: l10n.requestSummary(request),
            valueKey: const ValueKey('session-request'),
          ),
        if (session.portions > 0)
          SessionInfoRow(
            label: l10n.quotePortions,
            value: '${session.portions}',
          ),
        if (session.client.kitchenNotes case final kitchen?)
          SessionInfoRow(
            label: l10n.sessionKitchenNotes,
            value: kitchen,
            valueKey: const ValueKey('session-kitchen-notes'),
          ),
        if (notes.isNotEmpty)
          SessionInfoRow(
            label: l10n.detailSectionNotes,
            value: notes,
            valueKey: const ValueKey('session-request-notes'),
          ),
      ],
    );
  }
}

/// Las semanas de la reserva (también las canceladas): cada una abre su
/// ficha en lugar de esta.
class _Weeks extends StatelessWidget {
  const _Weeks({required this.detail});

  final SessionDetail detail;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final formats = RequestFormats(context);
    final current = detail.session;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SessionSection(l10n.sessionSectionWeeks),
        for (final week in detail.weeks)
          Builder(
            builder: (context) {
              final position = bookingPosition(week, detail.booking);
              final date = formats.shortDate(week.date);
              return ListTile(
                key: ValueKey('session-week-${week.id}'),
                contentPadding: EdgeInsets.zero,
                selected: week.id == current.id,
                leading: Icon(
                  week.isLive ? Icons.event_outlined : Icons.event_busy,
                ),
                title: Text(
                  position == null
                      ? date
                      : l10n.bookingWeekTitle(position.week, date),
                ),
                subtitle: Text(
                  [
                    week.start.toHhMm(),
                    if (week.status.shown != SessionStatus.confirmed)
                      l10n.sessionStatus(week.status),
                  ].join(' · '),
                ),
                onTap: week.id == current.id
                    ? null
                    : () => context.pushReplacement(
                        AppRoutes.sessionDetail(week.id),
                      ),
              );
            },
          ),
      ],
    );
  }
}

/// «Rinnova» en la última sesión viva de una reserva semanal (decisión 3):
/// «È l'ultima sessione…», «Ha già un'altra sessione: …» si la clienta ya
/// tiene otra sesión viva después (una renovación u otra reserva: el botón
/// sigue) y el botón, que abre la hoja prellenada. También en una cocinada o
/// cobrada, que no tienen la barra de abajo.
class _LastOfBooking extends ConsumerWidget {
  const _LastOfBooking({required this.session});

  final CookingSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(sessionRenewalOfferProvider(session.id))) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = SessionFormats(context);
    final later = ref.watch(sessionLaterSessionProvider(session.id));
    return Padding(
      key: const ValueKey('session-last-of-booking'),
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Nodos propios: el lector de pantalla los lee en orden.
          MergeSemantics(
            child: Text(
              l10n.sessionLastOfBooking,
              style: theme.textTheme.bodyLarge,
            ),
          ),
          if (later != null) ...[
            const SizedBox(height: 4),
            MergeSemantics(
              child: Text(
                l10n.sessionLaterSession(formats.inText(later)),
                key: const ValueKey('session-later-session'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          FilledButton.tonal(
            key: const ValueKey('session-renew'),
            onPressed: () =>
                unawaited(context.push(AppRoutes.sessionRenew(session.id))),
            child: Text(l10n.actionRenew),
          ),
        ],
      ),
    );
  }
}

/// Mover y Cancelar. Mientras la sesión espera al servidor, deshabilitados.
class _ActionsBar extends ConsumerWidget {
  const _ActionsBar({required this.detail});

  final SessionDetail detail;

  Future<void> _move(BuildContext context) async {
    final picked = await pickSessionDate(context, initial: detail.session.date);
    if (picked == null || !context.mounted) return;
    await openMoveSheet(context, detail.session.id, date: picked);
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final choice = await showCancelSessionDialog(
      context,
      session: detail.session,
      following: detail.following,
    );
    if (choice == null || !context.mounted) return;
    await _cancelSessions(context, ref, [
      detail.session,
      if (choice.withFollowing) ...detail.following,
    ], reason: choice.reason);
  }

  /// Cancela [sessions] (la de la ficha primero, si va). Un 409 hasPayments
  /// se explica con el aviso de las semanas cobradas, también si llega al
  /// tocar «Riprova» después de una falla de red.
  Future<void> _cancelSessions(
    BuildContext context,
    WidgetRef ref,
    List<CookingSession> sessions, {
    required CancelReason reason,
  }) => SessionActions.of(context).cancel(
    sessions,
    reason: reason,
    detailId: detail.session.id,
    onHasPayments: (failure) async {
      if (!context.mounted) return false;
      await _explainPayments(context, ref, failure, sessions, reason: reason);
      return true;
    },
  );

  /// 409 hasPayments: no se canceló nada (todo o nada). El aviso dice cuáles
  /// están cobradas y ofrece lo que se puede hacer (hasPaymentsPlan): pasar
  /// la semana de la ficha al final de la reserva (decisión 5 del plan) si
  /// solo se cancelaba esa, o cancelar solo las que no están cobradas si se
  /// cancelaban varias. Cancelarla con la devolución llega con los cobros.
  Future<void> _explainPayments(
    BuildContext context,
    WidgetRef ref,
    SessionFailure failure,
    List<CookingSession> requested, {
    required CancelReason reason,
  }) async {
    final current =
        ref.read(sessionDetailProvider(detail.session.id)).value ?? detail;
    // Las pedidas como están ahora en la ficha (una pudo moverse).
    final now = {
      for (final session in current.booking) session.id: session,
      current.session.id: current.session,
    };
    final plan = hasPaymentsPlan(
      current: current.session,
      booking: current.booking,
      requested: [for (final session in requested) now[session.id] ?? session],
      paidIds: failure.sessionIds,
    );
    final action = await showHasPaymentsDialog(context, plan: plan);
    if (!context.mounted) return;
    switch (action) {
      case HasPaymentsAction.moveToEnd:
        await openMoveSheet(context, current.session.id, date: plan.moveToEnd);
      case HasPaymentsAction.cancelUnpaid:
        await _cancelSessions(context, ref, plan.unpaid, reason: reason);
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final session = detail.session;
    final busy = ref.watch(
      sessionsBusyProvider.select((ids) => ids.contains(session.id)),
    );

    return SessionBottomBar(
      children: [
        if (busy) ...[
          const LinearProgressIndicator(key: ValueKey('session-busy')),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            if (session.canCancel)
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('session-cancel'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colors.error,
                  ),
                  onPressed: busy
                      ? null
                      : () => unawaited(_cancel(context, ref)),
                  child: Text(l10n.sessionCancelAction),
                ),
              ),
            if (session.canCancel && session.canMove) const SizedBox(width: 12),
            if (session.canMove)
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('session-move'),
                  onPressed: busy ? null : () => unawaited(_move(context)),
                  icon: const Icon(Icons.edit_calendar_outlined),
                  label: Text(l10n.sessionMoveAction),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
