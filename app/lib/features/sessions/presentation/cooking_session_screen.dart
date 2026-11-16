// Ficha de una sesión de cocina (`/sessioni/:id`, a pantalla completa): el día
// y las horas (salidas de la sesión), «Semana k de N» sin contar las
// canceladas, «Come arrivare» (la dirección en Mapas), WhatsApp y llamar; las
// alergias resaltadas (la nota del pedido y, con gluten, la de contaminación
// cruzada, SPEC §5.6); los datos de la clienta y las semanas de su reserva.
// Abajo, Mover (con «Annulla» después) y Cancelar (con confirmación y
// «también las siguientes»).
//
// Solo lee providers: la lógica está en SessionDetailController y
// SessionCommands. Lleva la dirección y datos de salud: nada se loguea.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart'
    show LoadErrorView;
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/features/sessions/application/session_links.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';
import 'package:radici/features/sessions/presentation/cancel_session_dialog.dart';
import 'package:radici/features/sessions/presentation/move_session_screen.dart';
import 'package:radici/features/sessions/presentation/session_actions.dart';
import 'package:radici/features/sessions/presentation/session_labels.dart';
import 'package:radici/features/sessions/presentation/session_widgets.dart';
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
              const SizedBox(height: 16),
              _ContactButtons(session: session),
              _Allergies(session: session),
              _Client(session: session),
              if (detail.weeks.length > 1) _Weeks(detail: detail),
            ],
          ),
        ),
      ),
    );
  }
}

/// El día, «Semana k de N», el estado (si no está confirmada) y las horas.
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
    final status = session.status == SessionStatus.confirmed
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

/// «Come arrivare», WhatsApp y llamar.
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const ValueKey('session-directions'),
              onPressed: directions == null
                  ? null
                  : () => _launch(context, ref, directions),
              icon: const Icon(Icons.directions_outlined),
              label: Text(l10n.sessionDirections),
            ),
            OutlinedButton.icon(
              key: const ValueKey('session-whatsapp'),
              onPressed: whatsApp == null
                  ? null
                  : () => _launch(context, ref, whatsApp),
              icon: const Icon(Icons.chat_outlined),
              label: Text(l10n.actionWhatsApp),
            ),
            OutlinedButton.icon(
              key: const ValueKey('session-call'),
              onPressed: call == null
                  ? null
                  : () => _launch(context, ref, call),
              icon: const Icon(Icons.call_outlined),
              label: Text(l10n.actionCall),
            ),
          ],
        ),
        if (session.address == null) ...[
          const SizedBox(height: 8),
          Text(
            l10n.sessionNoAddress,
            key: const ValueKey('session-no-address'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// Alergias y dietas de la ficha y del pedido, la nota del pedido resaltada
/// y, con gluten, la nota de contaminación cruzada (SPEC §5.6).
class _Allergies extends StatelessWidget {
  const _Allergies({required this.session});

  final CookingSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final note = session.allergyNote;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SessionSection(l10n.sessionSectionAllergies),
        ...switch (session.allergyAnswer) {
          AllergyAnswer.none => [
            Text(
              l10n.detailNoAllergies,
              key: const ValueKey('session-no-allergies'),
            ),
          ],
          // Sin respuesta: que pregunte antes de cocinar (se destaca).
          AllergyAnswer.unknown => [
            Text(
              l10n.detailAllergiesUnknown,
              key: const ValueKey('session-allergies-unknown'),
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colors.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          AllergyAnswer.listed => [
            if (session.allergens.isNotEmpty)
              _Chips(
                keyName: 'session-allergens',
                label: l10n.detailAllergens,
                values: [for (final a in session.allergens) l10n.allergen(a)],
              ),
            if (session.diets.isNotEmpty)
              _Chips(
                keyName: 'session-diets',
                label: l10n.detailDiets,
                values: [for (final d in session.diets) l10n.diet(d)],
              ),
            if (note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.tertiaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: MergeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.sessionAllergyNote,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: colors.onTertiaryContainer,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            note,
                            key: const ValueKey('session-allergy-note'),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: colors.onTertiaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        },
        if (session.needsCrossContaminationNote)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.errorContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ExcludeSemantics(
                      child: Icon(
                        Icons.warning_amber_rounded,
                        color: colors.onErrorContainer,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.sessionCrossContamination,
                        key: const ValueKey('session-cross-contamination'),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: colors.onErrorContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Chips extends StatelessWidget {
  const _Chips({
    required this.keyName,
    required this.label,
    required this.values,
  });

  final String keyName;
  final String label;
  final List<String> values;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey(keyName),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final value in values)
                Chip(
                  label: Text(value),
                  backgroundColor: theme.colorScheme.tertiaryContainer,
                  labelStyle: TextStyle(
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
            ],
          ),
        ],
      ),
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
          SessionInfoRow(
            label: l10n.sessionAddress,
            value: address,
            selectable: true,
            valueKey: const ValueKey('session-address'),
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
                    if (week.status != SessionStatus.confirmed)
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
    final actions = SessionActions.of(context);
    final failure = await actions.cancel([
      detail.session,
      if (choice.withFollowing) ...detail.following,
    ], reason: choice.reason);
    if (failure == null || !context.mounted) return;
    await _explainPayments(context, ref, failure);
  }

  /// 409 hasPayments: no se canceló nada. Una semana cobrada se puede pasar
  /// al final de la reserva (decisión 5 del plan); cancelarla con la
  /// devolución llega con los cobros.
  Future<void> _explainPayments(
    BuildContext context,
    WidgetRef ref,
    SessionFailure failure,
  ) async {
    final l10n = AppLocalizations.of(context);
    final current =
        ref.read(sessionDetailProvider(detail.session.id)).value ?? detail;
    final end = current.endOfBooking;
    final canMoveToEnd =
        end != null &&
        current.session.canMove &&
        (failure.sessionIds.isEmpty ||
            failure.sessionIds.contains(current.session.id));
    final moveToEnd = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('has-payments-dialog'),
        title: Text(l10n.cancelHasPaymentsTitle),
        content: Text(
          l10n.cancelHasPaymentsBody(
            failure.sessionIds.isEmpty ? 1 : failure.sessionIds.length,
          ),
        ),
        actionsOverflowButtonSpacing: 8,
        actions: [
          TextButton(
            key: const ValueKey('has-payments-close'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionClose),
          ),
          if (canMoveToEnd)
            FilledButton(
              key: const ValueKey('has-payments-move-to-end'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.moveToEnd),
            ),
        ],
      ),
    );
    if (moveToEnd != true || !context.mounted) return;
    await openMoveSheet(context, current.session.id, date: end);
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
