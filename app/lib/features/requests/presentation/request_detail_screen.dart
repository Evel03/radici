// Detalle de un pedido: todos los datos (incluidas las restricciones, que
// solo ve la cocinera, o lo que contestó el cliente a la pregunta de
// alergias), la estimación guardada y las acciones: WhatsApp, llamar, email,
// rechazar, deshacer el rechazo y marcar a la persona como clienta (así no se
// borra a los 90 días). Un pedido nuevo, además, «Conferma prenotazione»
// (abajo). Al abrirlo se marca como visto.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/money.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/quote/domain/quote.dart' show defaultPricing;
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/application/contact_actions.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart';
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

class RequestDetailScreen extends ConsumerStatefulWidget {
  const RequestDetailScreen({super.key, required this.requestId});

  final String requestId;

  @override
  ConsumerState<RequestDetailScreen> createState() =>
      _RequestDetailScreenState();
}

class _RequestDetailScreenState extends ConsumerState<RequestDetailScreen> {
  @override
  void initState() {
    super.initState();
    // Marcar como visto después del primer frame: no se cambia el estado de
    // un provider mientras se construye la pantalla.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(chefInboxProvider.notifier).open(widget.requestId));
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final detail = ref.watch(chefRequestProvider(widget.requestId));
    final request = detail.value;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          request?.client.displayName ?? l10n.requestDetailTitle,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: detail.when(
        data: (request) => request == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    l10n.requestNotFound,
                    key: const ValueKey('request-not-found'),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : _RequestDetail(request: request),
        error: (_, _) => LoadErrorView(
          message: l10n.inboxLoadError,
          onRetry: () => ref.invalidate(chefRequestProvider(widget.requestId)),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
      // Un pedido nuevo se confirma como reserva: la acción principal, abajo.
      bottomNavigationBar: request != null && request.canConfirmBooking
          ? _ConfirmBookingBar(requestId: request.id)
          : null,
    );
  }
}

/// «Conferma prenotazione»: abre la hoja a pantalla completa.
class _ConfirmBookingBar extends StatelessWidget {
  const _ConfirmBookingBar({required this.requestId});

  final String requestId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.outlineVariant)),
        ),
        child: SafeArea(
          top: false,
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const ValueKey('action-confirm-booking'),
                    onPressed: () =>
                        context.push(AppRoutes.requestBooking(requestId)),
                    icon: const Icon(Icons.event_available),
                    label: Text(l10n.actionConfirmBooking),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RequestDetail extends ConsumerWidget {
  const _RequestDetail({required this.request});

  final ChefRequest request;

  Future<void> _launch(BuildContext context, WidgetRef ref, Uri uri) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = AppLocalizations.of(context).launchFailed;
    // Se llama directo desde el toque: en la web, esperar algo antes haría
    // que el navegador bloquee la ventana nueva.
    final opened = await ref.read(linkLauncherProvider).launch(uri);
    if (!opened) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _reject(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await _confirm(
      context,
      keyPrefix: 'reject',
      title: l10n.rejectConfirmTitle(request.client.displayName),
      body: l10n.rejectConfirmBody,
      confirmLabel: l10n.actionReject,
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await ref.read(chefInboxProvider.notifier).reject(request.id);
      messenger.showSnackBar(SnackBar(content: Text(l10n.rejectDone)));
    } on RequestsFailure catch (failure) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            failure.kind == RequestsFailureKind.conflict
                ? l10n.rejectConflict
                : l10n.rejectFailed,
          ),
        ),
      );
    }
  }

  Future<void> _undoReject(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await _confirm(
      context,
      keyPrefix: 'undo-reject',
      title: l10n.undoRejectConfirmTitle(request.client.displayName),
      body: l10n.undoRejectConfirmBody,
      confirmLabel: l10n.undoRejectConfirmAction,
    );
    if (!confirmed) return;
    try {
      await ref.read(chefInboxProvider.notifier).undoReject(request.id);
      messenger.showSnackBar(SnackBar(content: Text(l10n.undoRejectDone)));
    } on RequestsFailure catch (failure) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            failure.kind == RequestsFailureKind.conflict
                ? l10n.undoRejectConflict
                : l10n.undoRejectFailed,
          ),
        ),
      );
    }
  }

  Future<void> _markClient(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await _confirm(
      context,
      keyPrefix: 'mark-client',
      title: l10n.markClientConfirmTitle(request.client.displayName),
      body: l10n.markClientConfirmBody,
      confirmLabel: l10n.markClientConfirmAction,
    );
    if (!confirmed) return;
    try {
      await ref
          .read(chefInboxProvider.notifier)
          .markClientAsCustomer(request.id);
      messenger.showSnackBar(SnackBar(content: Text(l10n.markClientDone)));
    } on RequestsFailure catch (failure) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            failure.kind == RequestsFailureKind.conflict
                ? l10n.markClientConflict
                : l10n.markClientFailed,
          ),
        ),
      );
    }
  }

  /// Diálogo de confirmación (claves `<keyPrefix>-dialog`, `-cancel` y
  /// `-confirm`). Devuelve true solo si se confirmó.
  Future<bool> _confirm(
    BuildContext context, {
    required String keyPrefix,
    required String title,
    required String body,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final colors = Theme.of(context).colorScheme;
        return AlertDialog(
          key: ValueKey('$keyPrefix-dialog'),
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              key: ValueKey('$keyPrefix-cancel'),
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.actionCancel),
            ),
            FilledButton(
              key: ValueKey('$keyPrefix-confirm'),
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: colors.error,
                      foregroundColor: colors.onError,
                    )
                  : null,
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = RequestFormats(context);
    final links = ref.watch(contactLinksProvider(request.id));
    final whatsApp = links?.whatsApp;
    final call = links?.call;
    final email = links?.email;

    final date = request.preferredDate;
    final slot = request.preferredSlot;
    final weekly = request.type == RequestType.week;
    final restrictions = request.restrictions ?? const RequestRestrictions();
    final notes = request.notes?.trim() ?? '';
    final client = request.client;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          key: const ValueKey('request-detail'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            // Encabezado: estado, cuándo llegó y de dónde.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(
                  key: const ValueKey('request-status'),
                  label: Text(l10n.requestStatus(request)),
                  backgroundColor: request.isNew
                      ? theme.colorScheme.primaryContainer
                      : null,
                ),
                Text(
                  l10n.requestReceivedAt(
                    formats.instantDate(request.createdAt),
                    formats.instantTime(request.createdAt),
                  ),
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  switch (request.source) {
                    RequestSource.web => l10n.requestSourceWeb,
                    RequestSource.app => l10n.requestSourceApp,
                  },
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Contactar.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const ValueKey('action-whatsapp'),
                  onPressed: whatsApp == null
                      ? null
                      : () => _launch(context, ref, whatsApp),
                  icon: const Icon(Icons.chat_outlined),
                  label: Text(l10n.actionWhatsApp),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('action-call'),
                  onPressed: call == null
                      ? null
                      : () => _launch(context, ref, call),
                  icon: const Icon(Icons.call_outlined),
                  label: Text(l10n.actionCall),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('action-email'),
                  onPressed: email == null
                      ? null
                      : () => _launch(context, ref, email),
                  icon: const Icon(Icons.mail_outline),
                  label: Text(l10n.actionEmail),
                ),
              ],
            ),

            _Section(title: l10n.detailSectionRequest),
            _InfoRow(label: l10n.detailType, value: l10n.requestType(request.type)),
            // Un pedido semanal: cuántas semanas (una sesión por semana).
            if (weekly)
              _InfoRow(
                label: l10n.quoteWeeks,
                value: '${request.weeks}',
                valueKey: const ValueKey('detail-weeks'),
              ),
            if (request.adults != null)
              _InfoRow(label: l10n.quoteAdults, value: '${request.adults}'),
            if (request.kids != null)
              _InfoRow(label: l10n.quoteKids, value: '${request.kids}'),
            if (request.days != null)
              _InfoRow(
                label: weekly ? l10n.quoteDaysPerWeek : l10n.quoteDays,
                value: '${request.days}',
              ),
            if (request.meals.isNotEmpty)
              _InfoRow(
                label: l10n.quoteMealsSection,
                value: l10n.meals(request.meals),
              ),
            _InfoRow(
              label: l10n.detailPreferredDate,
              value: date == null ? l10n.requestNoDate : formats.longDate(date),
            ),
            // El mismo día de cada semana siguiente. Espacios duros dentro de
            // cada fecha: la línea se corta entre dos fechas, no en medio.
            if (date != null && request.weeks > 1)
              _InfoRow(
                label: l10n.detailNextDates,
                value: [
                  for (var week = 1; week < request.weeks; week++)
                    formats
                        .shortDate(date.addDays(7 * week))
                        .replaceAll(' ', '\u00a0'),
                ].join(' · '),
                valueKey: const ValueKey('detail-next-dates'),
              ),
            if (slot != null)
              _InfoRow(label: l10n.detailPreferredSlot, value: l10n.slot(slot)),

            _Section(title: l10n.detailSectionRestrictions),
            ...switch (request.allergyAnswer) {
              AllergyAnswer.none => [
                Text(
                  l10n.detailNoAllergies,
                  key: const ValueKey('detail-no-allergies'),
                ),
              ],
              // Sin respuesta: que pregunte antes de armar el menú (se destaca).
              AllergyAnswer.unknown => [
                Text(
                  l10n.detailAllergiesUnknown,
                  key: const ValueKey('detail-allergies-unknown'),
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              AllergyAnswer.listed => [
                if (restrictions.allergens.isNotEmpty)
                  _ChipsRow(
                    label: l10n.detailAllergens,
                    values: [
                      for (final a in restrictions.allergens) l10n.allergen(a),
                    ],
                  ),
                if (restrictions.diets.isNotEmpty)
                  _ChipsRow(
                    label: l10n.detailDiets,
                    values: [for (final d in restrictions.diets) l10n.diet(d)],
                  ),
                if (restrictions.note.isNotEmpty)
                  _InfoRow(
                    label: l10n.detailRestrictionsNote,
                    value: restrictions.note,
                  ),
              ],
            },

            _Section(title: l10n.detailSectionNotes),
            SelectableText(
              notes.isEmpty ? l10n.detailNoNotes : notes,
              key: const ValueKey('detail-notes'),
            ),

            _Section(title: l10n.detailSectionEstimate),
            _Estimate(estimate: request.estimate),

            _Section(title: l10n.detailSectionContact),
            if (client.contactPhone case final phone?) ...[
              _InfoRow(label: l10n.detailPhone, value: phone, selectable: true),
              if (client.phoneE164 == null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    l10n.detailPhoneInvalid,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
            if (client.contactEmail case final address?)
              _InfoRow(label: l10n.detailEmail, value: address, selectable: true),
            if (client.zone case final zone? when zone.isNotEmpty)
              _InfoRow(label: l10n.detailZone, value: zone),
            _InfoRow(
              label: l10n.detailWhatsAppOptIn,
              value: request.whatsappOptIn
                  ? l10n.detailWhatsAppOptInYes
                  : l10n.detailWhatsAppOptInNo,
            ),
            _InfoRow(
              label: l10n.detailLanguage,
              value: l10n.language(request.locale),
            ),
            // Prospecto: se borra a los 90 días si no pasa a cliente (contrato §9).
            if (request.canMarkClient) ...[
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                child: Text(
                  l10n.detailProspectNotice,
                  key: const ValueKey('detail-prospect-notice'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  key: const ValueKey('action-mark-client'),
                  onPressed: () => _markClient(context, ref),
                  icon: const Icon(Icons.how_to_reg_outlined),
                  label: Text(l10n.actionMarkClient),
                ),
              ),
            ] else if (client.status != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.detailClientKept,
                  key: const ValueKey('detail-client-kept'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),

            if (request.canReject) ...[
              const SizedBox(height: 32),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  key: const ValueKey('action-reject'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  onPressed: () => _reject(context, ref),
                  icon: const Icon(Icons.block),
                  label: Text(l10n.actionReject),
                ),
              ),
            ],
            if (request.canUndoReject) ...[
              const SizedBox(height: 32),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  key: const ValueKey('action-undo-reject'),
                  onPressed: () => _undoReject(context, ref),
                  icon: const Icon(Icons.undo),
                  label: Text(l10n.actionUndoReject),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// La estimación guardada. Desde el precio por semana: el servicio por semana,
/// el de todas las semanas y el ahorro, o por qué no hay precio automático. Las
/// de antes (servicio por hora): el servicio, como se guardó. Sin compra ni
/// total, tampoco en las de antes: la compra la hace el cliente.
class _Estimate extends StatelessWidget {
  const _Estimate({required this.estimate});

  final RequestEstimate? estimate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final estimate = this.estimate;
    if (estimate == null || estimate.isEmpty) {
      return Text(l10n.detailNoEstimate, key: const ValueKey('detail-no-estimate'));
    }
    final locale = Localizations.localeOf(context).toString();
    String money(int cents) => formatCents(cents, locale: locale);
    final weeks = estimate.weeks ?? 1;
    final savings = estimate.savingsCents ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (estimate.portions case final portions?)
          _InfoRow(label: l10n.quotePortions, value: '$portions'),
        if (estimate.recipes case final recipes?)
          _InfoRow(label: l10n.quoteRecipes, value: '$recipes'),
        if (estimate.cookMinutes case final minutes?)
          _InfoRow(label: l10n.quoteCookTime, value: l10n.quoteMinutes(minutes)),
        if (!estimate.hasAutoPrice)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              estimate.reason == NoAutoPriceReason.extra
                  ? l10n.detailNoAutoPriceExtra
                  : l10n.detailNoAutoPricePeople(
                      estimate.maxPeople ??
                          defaultPricing.weeklyRateMaxPeople,
                    ),
              key: const ValueKey('detail-no-auto-price'),
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (estimate.isLegacy) ...[
          if (estimate.serviceCents case final cents?)
            _InfoRow(
              label: l10n.quoteService,
              value: money(cents),
              valueKey: const ValueKey('detail-estimate-total'),
              emphasized: true,
            ),
        ] else ...[
          if (weeks > 1 && estimate.weeklyServiceCents != null)
            _InfoRow(
              label: l10n.quoteWeeklyService,
              value: money(estimate.weeklyServiceCents!),
              valueKey: const ValueKey('detail-estimate-weekly'),
            ),
          if (estimate.serviceCents case final cents?)
            _InfoRow(
              label: l10n.quoteServiceTotal(weeks),
              value: money(cents),
              valueKey: const ValueKey('detail-estimate-total'),
              emphasized: true,
            ),
          if (savings > 0)
            _InfoRow(
              label: l10n.quoteSavings,
              value: money(savings),
              valueKey: const ValueKey('detail-estimate-savings'),
            ),
        ],
        const SizedBox(height: 4),
        Text(
          l10n.detailEstimateFootnote,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// Etiqueta y valor en una fila (o uno debajo del otro si no entran).
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.selectable = false,
    this.emphasized = false,
    this.valueKey,
  });

  final String label;
  final String value;
  final bool selectable;
  final bool emphasized;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valueStyle = emphasized
        ? theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)
        : theme.textTheme.bodyLarge;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: MergeSemantics(
        child: Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 160),
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (selectable)
              SelectableText(value, key: valueKey, style: valueStyle)
            else
              Text(value, key: valueKey, style: valueStyle),
          ],
        ),
      ),
    );
  }
}

class _ChipsRow extends StatelessWidget {
  const _ChipsRow({required this.label, required this.values});

  final String label;
  final List<String> values;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
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
