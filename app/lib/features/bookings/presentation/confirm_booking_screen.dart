// Hoja «Conferma prenotazione», a pantalla completa desde el detalle de un
// pedido nuevo: semanas (1 a 8), una fecha por semana con lo que dice el
// servidor de cada una (libre, un aviso o un choque), la hora de llegada en
// chips, los minutos de cocina y el precio del servicio de toda la reserva.
// Abajo, siempre a mano, «Conferma N settimane». Al confirmar, el WhatsApp
// para la clienta, en su idioma.
//
// Solo lee providers: la lógica está en ConfirmBookingController y el
// mensaje, en booking_message.dart. El campo del precio tiene letra de 16 px
// (con menos, iOS agranda la página al enfocarlo).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/money.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/application/booking_message.dart';
import 'package:radici/features/bookings/application/confirm_booking_controller.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/bookings/presentation/booking_labels.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart'
    show LoadErrorView;
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Ancho máximo del contenido en pantallas anchas (como el detalle).
const double _maxContentWidth = 720;

class ConfirmBookingScreen extends ConsumerWidget {
  const ConfirmBookingScreen({super.key, required this.requestId});

  final String requestId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final detail = ref.watch(chefRequestProvider(requestId));
    final request = detail.value;
    if (request != null) return _ConfirmBookingView(request: request);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.actionConfirmBooking)),
      body: detail.when(
        data: (_) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              l10n.requestNotFound,
              key: const ValueKey('booking-request-not-found'),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        error: (_, _) => LoadErrorView(
          message: l10n.inboxLoadError,
          onRetry: () => ref.invalidate(chefRequestProvider(requestId)),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _ConfirmBookingView extends ConsumerStatefulWidget {
  const _ConfirmBookingView({required this.request});

  final ChefRequest request;

  @override
  ConsumerState<_ConfirmBookingView> createState() =>
      _ConfirmBookingViewState();
}

class _ConfirmBookingViewState extends ConsumerState<_ConfirmBookingView> {
  final TextEditingController _price = TextEditingController();
  bool _priceShown = false;

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  /// Mientras Evelyn no lo escriba, el campo muestra el precio que propone la
  /// hoja, con los decimales de la interfaz.
  String _suggestedPriceText(ConfirmBookingState state, String locale) {
    final cents = state.suggestedPriceCents;
    return cents == null ? '' : formatCentsForInput(cents, locale: locale);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final provider = confirmBookingProvider(widget.request.id);
    final state = ref.watch(provider);
    final controller = ref.read(provider.notifier);
    final locale = Localizations.localeOf(context).toString();

    if (!_priceShown) {
      // Primer cuadro: el campo todavía no se construyó (no tiene oyentes).
      _priceShown = true;
      _price.text = _suggestedPriceText(state, locale);
    }
    ref.listen(provider, (previous, next) {
      if (next.priceEdited) return;
      final text = _suggestedPriceText(next, locale);
      if (_price.text != text) _price.text = text;
    });

    final result = state.result;
    return PopScope(
      // Mientras se manda, la hoja no se cierra.
      canPop: !state.sending,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            key: const ValueKey('booking-close'),
            icon: const Icon(Icons.close),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: state.sending
                ? null
                : () => Navigator.of(context).maybePop(),
          ),
          title: Text(
            result == null ? l10n.actionConfirmBooking : l10n.bookingDoneTitle,
          ),
        ),
        // La barra va en el cuerpo y no en bottomNavigationBar: así queda
        // arriba del teclado mientras se escribe el precio.
        body: Column(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _maxContentWidth),
                  child: result == null
                      // Mientras se manda, nada cambia: vale lo que se mandó.
                      ? AbsorbPointer(
                          absorbing: state.sending,
                          child: _BookingForm(
                            request: widget.request,
                            state: state,
                            controller: controller,
                            price: _price,
                          ),
                        )
                      : _BookingDone(request: widget.request, result: result),
                ),
              ),
            ),
            if (result == null)
              _ConfirmBar(state: state, controller: controller)
            else
              _DoneBar(requestId: widget.request.id),
          ],
        ),
      ),
    );
  }
}

class _BookingForm extends StatelessWidget {
  const _BookingForm({
    required this.request,
    required this.state,
    required this.controller,
    required this.price,
  });

  final ChefRequest request;
  final ConfirmBookingState state;
  final ConfirmBookingController controller;
  final TextEditingController price;

  Future<void> _pickDate(BuildContext context, int index) async {
    final l10n = AppLocalizations.of(context);
    final first = state.today.addDays(-bookingDateRangeDays);
    final last = state.today.addDays(bookingDateRangeDays);
    var initial = state.dates[index];
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.toDateTime(),
      firstDate: first.toDateTime(),
      lastDate: last.toDateTime(),
      helpText: l10n.bookingChangeDate(index + 1),
    );
    if (picked == null || !context.mounted) return;
    controller.setDate(index, CalendarDate.fromDateTime(picked));
  }

  Future<void> _pickTime(BuildContext context) async {
    final current = state.start ?? defaultBookingArrival;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current.hour, minute: current.minute),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null || !context.mounted) return;
    controller.setStart(ClockTime.hm(picked.hour, picked.minute));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = RequestFormats(context);
    final locale = Localizations.localeOf(context).toString();
    final issues = state.dateIssues;
    final weeks = state.weeks;

    final priceIssue = state.priceIssue;
    final cents = state.serviceTotalCents;
    String? priceHelper;
    String? priceError;
    switch (priceIssue) {
      case BookingPriceIssue.required:
        priceHelper = l10n.bookingPriceRequired;
      case BookingPriceIssue.invalid:
        priceError = l10n.bookingPriceInvalid;
      case BookingPriceIssue.tooHigh:
        priceError = l10n.bookingPriceTooHigh(
          formatCents(maxBookingCents, locale: locale),
        );
      case null:
        if (cents != null && weeks > 1) {
          final share = weeklyShare(cents, weeks);
          final amount = formatCents(share.firstWeekCents, locale: locale);
          priceHelper = share.even
              ? l10n.bookingPricePerWeek(amount)
              : l10n.bookingPricePerWeekApprox(amount);
        }
    }

    // Pocas filas (8 semanas como mucho): todo construido, así el campo del
    // precio existe aunque esté abajo y se puede llevar a la vista al
    // enfocarlo.
    return SingleChildScrollView(
      key: const ValueKey('booking-form'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // De quién es la reserva.
          Text(
            request.client.displayName,
            style: theme.textTheme.titleLarge,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            l10n.requestSummary(request),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),

          if (state.maxWeeks > 1)
            _CounterRow(
              keyPrefix: 'booking-weeks',
              label: l10n.quoteWeeks,
              value: '$weeks',
              onDecrement: weeks > 1
                  ? () => controller.setWeeks(weeks - 1)
                  : null,
              onIncrement: weeks < state.maxWeeks
                  ? () => controller.setWeeks(weeks + 1)
                  : null,
            ),

          _SectionTitle(l10n.bookingDatesSection),
          for (var i = 0; i < weeks; i++)
            _WeekTile(
              index: i,
              title: l10n.bookingWeekTitle(
                i + 1,
                formats.shortDate(state.dates[i]),
              ),
              status: _weekStatus(context, i, issues[i]),
              onEdit: () => _pickDate(context, i),
            ),
          if (state.checksStatus == BookingChecksStatus.failed &&
              state.checksCurrent) ...[
            const SizedBox(height: 4),
            Text(
              l10n.bookingChecksFailed,
              key: const ValueKey('booking-checks-failed'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: const ValueKey('booking-checks-retry'),
                onPressed: controller.retryChecks,
                child: Text(l10n.actionRetry),
              ),
            ),
          ],
          const SizedBox(height: 4),
          _Help(l10n.bookingDatesHelp),

          _SectionTitle(l10n.bookingStartSection),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final time in arrivalOptions(
                suggested: state.suggestedStart,
                selected: state.start,
              ))
                ChoiceChip(
                  key: ValueKey('booking-start-${time.toHhMm()}'),
                  label: Text(time.toHhMm()),
                  selected: time == state.start,
                  onSelected: (_) => controller.setStart(time),
                ),
              ActionChip(
                key: const ValueKey('booking-start-other'),
                avatar: const Icon(Icons.schedule),
                label: Text(l10n.bookingStartOther),
                onPressed: () => _pickTime(context),
              ),
            ],
          ),
          if (state.suggestedStart case final suggested?) ...[
            const SizedBox(height: 8),
            _Help(l10n.bookingStartSuggested(suggested.toHhMm())),
          ],

          _SectionTitle(l10n.quoteCookTime),
          _CounterRow(
            keyPrefix: 'booking-cook',
            label: l10n.quoteCookTime,
            value: l10n.quoteMinutes(state.cookMinutes),
            onDecrement: state.cookMinutes > minBookingCookMinutes
                ? () => controller.stepCookMinutes(-1)
                : null,
            onIncrement: state.cookMinutes < maxBookingCookMinutes
                ? () => controller.stepCookMinutes(1)
                : null,
          ),
          _Help(l10n.bookingCookHelp(maxBookingCookMinutes)),

          const SizedBox(height: 24),
          TextField(
            key: const ValueKey('booking-price'),
            controller: price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            ],
            textInputAction: TextInputAction.done,
            readOnly: state.sending,
            // 16 px o más: con menos, iOS agranda la página al enfocar el campo.
            style: theme.textTheme.bodyLarge,
            decoration: InputDecoration(
              labelText: l10n.bookingPriceLabel,
              suffixText: '€',
              helperText: priceHelper,
              helperMaxLines: 2,
              errorText: priceError,
              errorMaxLines: 2,
            ),
            onChanged: controller.setPriceText,
          ),
          const SizedBox(height: 8),
          _Help(l10n.bookingGroceriesNote),
        ],
      ),
    );
  }

  /// Ícono, color y texto de la semana [index]: lo que impide mandar la
  /// fecha, lo que dijo el servidor o «verifica in corso».
  _WeekStatus? _weekStatus(
    BuildContext context,
    int index,
    BookingDateIssue? issue,
  ) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    if (issue != null) {
      return (
        icon: Icons.error_outline,
        color: colors.error,
        text: l10n.bookingDateIssue(issue),
      );
    }
    if (state.blocked) return null;
    final check = state.checkFor(index);
    if (check != null) {
      return switch (check.status) {
        BookingDayStatus.ok => (
          icon: Icons.check_circle_outline,
          color: colors.primary,
          text: l10n.bookingDayStatus(check.status),
        ),
        BookingDayStatus.busy => (
          icon: Icons.block,
          color: colors.error,
          text: l10n.bookingDayStatus(check.status),
        ),
        _ => (
          icon: Icons.warning_amber_outlined,
          color: colors.tertiary,
          text: l10n.bookingDayStatus(check.status),
        ),
      };
    }
    if (state.checksStatus == BookingChecksStatus.loading) {
      return (
        icon: Icons.hourglass_empty,
        color: colors.onSurfaceVariant,
        text: l10n.bookingStatusChecking,
      );
    }
    return null;
  }
}

typedef _WeekStatus = ({IconData icon, Color color, String text});

/// Una semana: su fecha, lo que dijo el servidor y el botón del calendario.
class _WeekTile extends StatelessWidget {
  const _WeekTile({
    required this.index,
    required this.title,
    required this.status,
    required this.onEdit,
  });

  final int index;
  final String title;
  final _WeekStatus? status;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final status = this.status;
    return ListTile(
      key: ValueKey('booking-week-$index'),
      contentPadding: EdgeInsets.zero,
      leading: status == null
          ? const Icon(Icons.event_outlined)
          : Icon(status.icon, color: status.color),
      title: Text(title),
      subtitle: status == null
          ? null
          : Text(
              status.text,
              key: ValueKey('booking-week-$index-status'),
              style: theme.textTheme.bodyMedium?.copyWith(color: status.color),
            ),
      trailing: IconButton(
        key: ValueKey('booking-week-$index-edit'),
        icon: const Icon(Icons.edit_calendar_outlined),
        tooltip: l10n.bookingChangeDate(index + 1),
        onPressed: onEdit,
      ),
      onTap: onEdit,
    );
  }
}

/// Etiqueta, − valor + (botones de 48 dp).
class _CounterRow extends StatelessWidget {
  const _CounterRow({
    required this.keyPrefix,
    required this.label,
    required this.value,
    required this.onDecrement,
    required this.onIncrement,
  });

  final String keyPrefix;
  final String label;
  final String value;
  final VoidCallback? onDecrement;
  final VoidCallback? onIncrement;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            // El lector de pantalla lee "Settimane, 4" en un solo nodo.
            child: Semantics(
              value: value,
              child: Text(label, style: textTheme.titleMedium),
            ),
          ),
          IconButton.filledTonal(
            key: ValueKey('$keyPrefix-decrement'),
            tooltip: l10n.counterDecrease(label),
            onPressed: onDecrement,
            icon: const Icon(Icons.remove),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 72),
            child: ExcludeSemantics(
              child: Text(
                value,
                key: ValueKey('$keyPrefix-value'),
                textAlign: TextAlign.center,
                style: textTheme.titleMedium,
              ),
            ),
          ),
          IconButton.filledTonal(
            key: ValueKey('$keyPrefix-increment'),
            tooltip: l10n.counterIncrease(label),
            onPressed: onIncrement,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 4),
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

class _Help extends StatelessWidget {
  const _Help(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Barra de abajo, siempre a mano (también con el teclado abierto): en un
/// teléfono, la acción principal queda en el tercio inferior.
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final side = math.max(16.0, (width - _maxContentWidth) / 2);
    return Material(
      color: colors.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.outlineVariant)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(side, 12, side, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

class _ConfirmBar extends StatelessWidget {
  const _ConfirmBar({required this.state, required this.controller});

  final ConfirmBookingState state;
  final ConfirmBookingController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = RequestFormats(context);
    final failure = state.failure;
    return _BottomBar(
      children: [
        if (failure != null) ...[
          Text(
            l10n.bookingFailure(failure, formatDate: formats.shortDate),
            key: const ValueKey('booking-failure'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 8),
        ],
        FilledButton(
          key: const ValueKey('booking-confirm'),
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
                    Flexible(child: Text(l10n.bookingSending)),
                  ],
                )
              : Text(l10n.bookingConfirmAction(state.weeks)),
        ),
      ],
    );
  }
}

/// Después de confirmar: las semanas creadas con su hora y el precio.
class _BookingDone extends ConsumerWidget {
  const _BookingDone({required this.request, required this.result});

  final ChefRequest request;
  final BookingResult result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = RequestFormats(context);
    final locale = Localizations.localeOf(context).toString();
    final whatsApp = ref.watch(bookingWhatsAppProvider(request.id));
    final weeks = result.weeks;
    final service = weeks.fold<int>(0, (sum, week) => sum + week.serviceCents);

    return SingleChildScrollView(
      key: const ValueKey('booking-done'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(
            Icons.event_available,
            size: 48,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.bookingDoneBody(weeks.length),
            key: const ValueKey('booking-done-body'),
            style: theme.textTheme.bodyLarge,
          ),
          if (result.duplicate) ...[
            const SizedBox(height: 8),
            Text(
              l10n.bookingDoneDuplicate,
              key: const ValueKey('booking-done-duplicate'),
            ),
          ],
          const SizedBox(height: 8),
          for (final (i, week) in weeks.indexed)
            ListTile(
              key: ValueKey('booking-done-week-$i'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: Text(
                [
                  l10n.bookingWeekTitle(i + 1, formats.shortDate(week.date)),
                  ?week.start?.toHhMm(),
                ].join(' · '),
              ),
            ),
          const Divider(),
          Text(
            '${l10n.quoteServiceTotal(weeks.length)}: '
            '${formatCents(service, locale: locale)}',
            key: const ValueKey('booking-done-service'),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          _Help(l10n.bookingGroceriesNote),
          if (whatsApp == null) ...[
            const SizedBox(height: 16),
            Text(
              l10n.bookingNoPhone,
              key: const ValueKey('booking-no-phone'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DoneBar extends ConsumerWidget {
  const _DoneBar({required this.requestId});

  final String requestId;

  Future<void> _launch(BuildContext context, WidgetRef ref, Uri uri) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = AppLocalizations.of(context).launchFailed;
    // Directo desde el toque: en la web, esperar algo antes haría que el
    // navegador bloquee la ventana nueva.
    final opened = await ref.read(linkLauncherProvider).launch(uri);
    if (!opened) messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final whatsApp = ref.watch(bookingWhatsAppProvider(requestId));
    return _BottomBar(
      children: [
        FilledButton.icon(
          key: const ValueKey('booking-whatsapp'),
          onPressed: whatsApp == null
              ? null
              : () => _launch(context, ref, whatsApp),
          icon: const Icon(Icons.chat_outlined),
          label: Text(l10n.bookingSendWhatsApp),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const ValueKey('booking-done-close'),
          onPressed: () => Navigator.of(context).maybePop(),
          child: Text(l10n.bookingDoneClose),
        ),
      ],
    );
  }
}
