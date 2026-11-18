// Hoja «Conferma prenotazione», a pantalla completa desde el detalle de un
// pedido nuevo: semanas (1 a 8), una fecha por semana con lo que dice el
// servidor de cada una (libre, un aviso o un choque), la hora de llegada en
// chips, los minutos de cocina y el precio del servicio de toda la reserva.
// Abajo, a mano también con el teclado abierto en un teléfono en vertical
// (en /gestione/, WebAppNotices esconde sus avisos mientras tanto), «Conferma N
// settimane» y, arriba del botón, el precio que se va a confirmar (después
// ninguna ruta lo cambia) o lo primero que impide confirmar, con un botón que
// lleva hasta ahí: en un teléfono, el precio y las últimas semanas quedan
// fuera de la vista. Al confirmar, el WhatsApp para la clienta, en su idioma.
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
import 'package:radici/features/availability/presentation/availability_labels.dart';
import 'package:radici/features/bookings/application/booking_message.dart';
import 'package:radici/features/bookings/application/booking_seed.dart';
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
  final FocusNode _priceFocus = FocusNode();

  /// El campo del precio y cada semana, para llevarlos a la vista desde la
  /// barra de abajo.
  final GlobalKey _priceKey = GlobalKey();
  final List<GlobalKey> _weekKeys = List.generate(
    maxBookingWeeks,
    (_) => GlobalKey(),
  );
  bool _priceShown = false;

  @override
  void dispose() {
    _price.dispose();
    _priceFocus.dispose();
    super.dispose();
  }

  /// Mientras Evelyn no lo escriba, el campo muestra el precio que propone la
  /// hoja, con los decimales de la interfaz.
  String _suggestedPriceText(ConfirmBookingState state, String locale) {
    final cents = state.suggestedPriceCents;
    return cents == null ? '' : formatCentsForInput(cents, locale: locale);
  }

  /// Lleva a la vista una parte del formulario ([key]).
  Future<void> _reveal(GlobalKey key) async {
    final target = key.currentContext;
    if (target == null) return;
    await Scrollable.ensureVisible(
      target,
      alignment: 0.3,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// El precio a la vista y con el foco, para cambiarlo o escribirlo.
  void _showPrice() {
    unawaited(_reveal(_priceKey));
    _priceFocus.requestFocus();
  }

  void _showWeek(int index) => unawaited(_reveal(_weekKeys[index]));

  BookingSource get _source => BookingSource.request(widget.request.id);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final provider = confirmBookingProvider(_source);
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
        // Un instante, hasta que la hoja toma el pedido (su seed).
        body: state.seedStatus != BookingSeedStatus.ready
            ? const Center(
                child: CircularProgressIndicator(
                  key: ValueKey('booking-loading'),
                ),
              )
            : Column(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: _maxContentWidth,
                        ),
                        child: result == null
                            ? _BookingForm(
                                request: widget.request,
                                state: state,
                                controller: controller,
                                price: _price,
                                priceFocus: _priceFocus,
                                priceKey: _priceKey,
                                weekKeys: _weekKeys,
                              )
                            : _BookingDone(source: _source, state: state),
                      ),
                    ),
                  ),
                  if (result == null)
                    _ConfirmBar(
                      state: state,
                      controller: controller,
                      onShowPrice: _showPrice,
                      onShowWeek: _showWeek,
                    )
                  else
                    _DoneBar(source: _source),
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
    required this.priceFocus,
    required this.priceKey,
    required this.weekKeys,
  });

  final ChefRequest request;
  final ConfirmBookingState state;
  final ConfirmBookingController controller;
  final TextEditingController price;
  final FocusNode priceFocus;
  final GlobalKey priceKey;
  final List<GlobalKey> weekKeys;

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
      helpText: l10n.bookingChangeDate(state.weeks, index + 1),
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
    // Mientras se manda, o mientras espera el reintento de una confirmación
    // sin respuesta, nada cambia: vale lo que se mandó.
    final frozen = state.frozen;

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
              onDecrement: !frozen && weeks > 1
                  ? () => controller.setWeeks(weeks - 1)
                  : null,
              onIncrement: !frozen && weeks < state.maxWeeks
                  ? () => controller.setWeeks(weeks + 1)
                  : null,
            ),

          _SectionTitle(
            weeks > 1 ? l10n.bookingDatesSection : l10n.bookingDateSection,
          ),
          for (var i = 0; i < weeks; i++)
            _WeekTile(
              key: weekKeys[i],
              index: i,
              // Con una sola fecha (un evento o una semana) no hay «Semana 1».
              title: weeks > 1
                  ? l10n.bookingWeekTitle(
                      i + 1,
                      formats.shortDate(state.dates[i]),
                    )
                  : formats.shortDate(state.dates[i]),
              changeLabel: l10n.bookingChangeDate(weeks, i + 1),
              status: _weekStatus(context, i, issues[i]),
              onEdit: frozen ? null : () => _pickDate(context, i),
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
            if (!frozen)
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
          if (weeks > 1) _Help(l10n.bookingDatesMoveHelp),
          _Help(l10n.bookingWarningsHelp),

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
                  onSelected: frozen ? null : (_) => controller.setStart(time),
                ),
              ActionChip(
                key: const ValueKey('booking-start-other'),
                avatar: const Icon(Icons.schedule),
                label: Text(l10n.bookingStartOther),
                onPressed: frozen ? null : () => _pickTime(context),
              ),
            ],
          ),
          if (state.suggestedStart case final suggested?) ...[
            const SizedBox(height: 8),
            _Help(l10n.bookingStartSuggested(suggested.toHhMm())),
          ],

          // La fila ya dice «Tempo in cucina»: sin otro título igual arriba.
          const SizedBox(height: 16),
          _CounterRow(
            keyPrefix: 'booking-cook',
            label: l10n.quoteCookTime,
            value: l10n.quoteMinutes(state.cookMinutes),
            onDecrement: !frozen && state.cookMinutes > minBookingCookMinutes
                ? () => controller.stepCookMinutes(-1)
                : null,
            onIncrement: !frozen && state.cookMinutes < maxBookingCookMinutes
                ? () => controller.stepCookMinutes(1)
                : null,
          ),
          _Help(l10n.bookingCookHelp(maxBookingCookMinutes)),

          const SizedBox(height: 24),
          KeyedSubtree(
            key: priceKey,
            child: TextField(
              key: const ValueKey('booking-price'),
              controller: price,
              focusNode: priceFocus,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              textInputAction: TextInputAction.done,
              readOnly: frozen,
              // Al abrir el teclado el campo sube con lugar para su ayuda o su
              // error (hasta dos líneas) arriba de la barra: con el margen de
              // 20 de siempre, en iOS (también /gestione/ en el iPhone)
              // quedaban tapados.
              scrollPadding: const EdgeInsets.fromLTRB(20, 20, 20, 72),
              // 16 px o más: con menos, iOS agranda la página al enfocar el campo.
              style: theme.textTheme.bodyLarge,
              decoration: InputDecoration(
                labelText: l10n.bookingPriceLabel(weeks),
                suffixText: '€',
                helperText: priceHelper,
                helperMaxLines: 2,
                errorText: priceError,
                errorMaxLines: 2,
              ),
              onChanged: controller.setPriceText,
            ),
          ),
          const SizedBox(height: 8),
          _Help(l10n.bookingGroceriesNote),
        ],
      ),
    );
  }

  /// Ícono, color y texto de la semana [index], en este orden: lo que impide
  /// mandar la fecha; un choque o un aviso del servidor; los avisos de la app
  /// (la llegada de hoy que ya pasó y el feriado, que el servidor no marca);
  /// «libre» o «verifica in corso».
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
    if (check != null && check.status != BookingDayStatus.ok) {
      return check.status == BookingDayStatus.busy
          ? (
              icon: Icons.block,
              color: colors.error,
              text: l10n.bookingDayStatus(check.status),
            )
          : (
              icon: Icons.warning_amber_outlined,
              color: colors.tertiary,
              text: l10n.bookingDayStatus(check.status),
            );
    }
    if (state.arrivalPassed(index)) {
      return (
        icon: Icons.warning_amber_outlined,
        color: colors.tertiary,
        text: l10n.bookingTodayArrivalPassed,
      );
    }
    if (state.holidayFor(index) case final holiday?) {
      return (
        icon: Icons.warning_amber_outlined,
        color: colors.tertiary,
        text: l10n.holidayLine(holiday),
      );
    }
    if (check != null) {
      return (
        icon: Icons.check_circle_outline,
        color: colors.primary,
        text: l10n.bookingDayStatus(check.status),
      );
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

/// Una semana: su fecha y lo que dijo el servidor. Toda la fila abre el
/// calendario: un solo objetivo, también para el lector de pantalla (el ícono
/// de la derecha es solo un dibujo y [changeLabel] va como pista).
class _WeekTile extends StatelessWidget {
  const _WeekTile({
    super.key,
    required this.index,
    required this.title,
    required this.changeLabel,
    required this.status,
    required this.onEdit,
  });

  final int index;
  final String title;
  final String changeLabel;
  final _WeekStatus? status;

  /// null: no se puede cambiar (se está mandando).
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = this.status;
    return Semantics(
      hint: onEdit == null ? null : changeLabel,
      child: ListTile(
        key: ValueKey('booking-week-$index'),
        enabled: onEdit != null,
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

/// Barra de abajo, a mano también con el teclado abierto en un teléfono en
/// vertical (en horizontal puede no entrar): la acción principal queda en el
/// tercio inferior.
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

/// Una línea de la barra de abajo, arriba del botón, con un botón a la
/// derecha que lleva hasta lo que dice (deshabilitado mientras nada se puede
/// cambiar).
class _BarLine extends StatelessWidget {
  const _BarLine({
    required this.textKey,
    required this.text,
    required this.actionKey,
    required this.actionLabel,
    required this.onAction,
    this.color,
  });

  final String textKey;
  final String text;
  final Color? color;
  final String actionKey;
  final String actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              key: ValueKey(textKey),
              style: theme.textTheme.bodyMedium?.copyWith(color: color),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: ValueKey(actionKey),
            onPressed: onAction,
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}

class _ConfirmBar extends StatelessWidget {
  const _ConfirmBar({
    required this.state,
    required this.controller,
    required this.onShowPrice,
    required this.onShowWeek,
  });

  final ConfirmBookingState state;
  final ConfirmBookingController controller;
  final VoidCallback onShowPrice;
  final void Function(int week) onShowWeek;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = RequestFormats(context);
    final locale = Localizations.localeOf(context).toString();
    final failure = state.failure;
    // Arriba del botón: la falla, si la hay; si no, lo que impide confirmar;
    // si nada lo impide, «Controllo le date…» mientras corre el dryRun (si
    // no, el botón gris no diría por qué) o el precio que se va a confirmar.
    // Sin respuesta (se reintenta lo mismo), la falla y el precio que se
    // reintenta.
    final blocker = failure == null ? state.blocker : null;
    final checking = failure == null && blocker == null && state.checking;
    final showSummary =
        state.retryPending || (failure == null && blocker == null && !checking);
    return _BottomBar(
      children: [
        if (failure != null) ...[
          // liveRegion: el lector de pantalla la anuncia al aparecer.
          Semantics(
            liveRegion: true,
            child: Text(
              l10n.bookingFailure(failure, formatDate: formats.shortDate),
              key: const ValueKey('booking-failure'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (blocker != null)
          _BarLine(
            textKey: 'booking-blocker',
            text: l10n.bookingBlockerText(state, blocker, locale: locale),
            color: theme.colorScheme.error,
            actionKey: 'booking-blocker-show',
            actionLabel: l10n.bookingShowProblem,
            onAction: switch (blocker) {
              (kind: BookingBlockKind.price, week: _) => onShowPrice,
              (kind: _, week: final week?) => () => onShowWeek(week),
              _ => null,
            },
          )
        else if (checking)
          // liveRegion: el lector de pantalla dice por qué el botón espera.
          // Con el alto de las otras líneas: el botón no salta.
          Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      l10n.bookingChecking,
                      key: const ValueKey('booking-checking'),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ),
              ],
            ),
          )
        else if (showSummary)
          _BarLine(
            textKey: 'booking-summary',
            text: l10n.bookingSummary(state, locale: locale),
            actionKey: 'booking-edit-price',
            actionLabel: l10n.bookingEditPrice,
            onAction: state.frozen ? null : onShowPrice,
          ),
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
              : Text(
                  state.retryPending
                      ? l10n.actionRetry
                      : l10n.bookingConfirmAction(state.weeks),
                ),
        ),
      ],
    );
  }
}

/// Después de confirmar: las semanas guardadas con su hora y el precio.
class _BookingDone extends ConsumerWidget {
  const _BookingDone({required this.source, required this.state});

  final BookingSource source;

  /// Con la reserva ([ConfirmBookingState.result]).
  final ConfirmBookingState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = RequestFormats(context);
    final locale = Localizations.localeOf(context).toString();
    final whatsApp = ref.watch(bookingWhatsAppProvider(source));
    final result = state.result!;
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
          // liveRegion: el lector de pantalla anuncia que quedó confirmada (el
          // botón que tenía el foco ya no está).
          Semantics(
            liveRegion: true,
            child: Text(
              l10n.bookingDoneBody(weeks.length),
              key: const ValueKey('booking-done-body'),
              style: theme.textTheme.bodyLarge,
            ),
          ),
          if (state.savedDiffers) ...[
            const SizedBox(height: 8),
            Text(
              l10n.bookingDoneDuplicateDiffers,
              key: const ValueKey('booking-done-differs'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ] else if (result.duplicate) ...[
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
                  if (weeks.length > 1)
                    l10n.bookingWeekTitle(i + 1, formats.shortDate(week.date))
                  else
                    formats.shortDate(week.date),
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
  const _DoneBar({required this.source});

  final BookingSource source;

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
    final whatsApp = ref.watch(bookingWhatsAppProvider(source));
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
