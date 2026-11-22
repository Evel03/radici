// El presupuesto en el detalle de un pedido (SPEC 5.8, «Presupuesto en la
// app»):
//
// - [QuoteSection], en el cuerpo: el bloque «Presupuesto» con su estado
//   (borrador sin mandar y hasta cuándo retiene las fechas; mandado, con la
//   versión, cuándo y hasta cuándo puede aceptarlo la clienta; los cambios que
//   pidió, con su mensaje entero; cambiado sin reenviar; aceptado, rechazado,
//   retirado o vencido), sus semanas (fecha, llegada y precio; cada una abre
//   su ficha para moverla o cancelarla), el total y lo que se puede hacer: el
//   menú de la semana 1, mandarlo de nuevo, otro precio y retirarlo.
// - [RequestActionsBar], abajo: en un pedido nuevo sin presupuesto abierto,
//   «Preparar presupuesto»; con uno abierto al que le falta salir (borrador,
//   cambiado o con cambios pedidos), «Mandar», que abre la vista previa del
//   menú de la semana 1, que lo lleva. Y, en un pedido nuevo o con el
//   presupuesto mandado, «Confirmar sin presupuesto»: con uno abierto, la
//   base lo retira al confirmar y la hoja lo avisa antes.
//
// Solo muestra providers (quote_providers.dart y week_menu_summaries.dart):
// la lógica está en RequestQuote, QuoteCommands y MenuSendController. Lleva
// el mensaje de la clienta: nada se loguea.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/money.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/availability/presentation/availability_actions.dart'
    show errorSnackBarDuration;
import 'package:radici/features/bookings/presentation/booking_labels.dart';
import 'package:radici/features/quotes/application/quote_providers.dart';
import 'package:radici/features/quotes/data/quotes_repository.dart';
import 'package:radici/features/quotes/domain/request_quote.dart';
import 'package:radici/features/quotes/presentation/quote_labels.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/features/sessions/presentation/session_widgets.dart';
import 'package:radici/features/today/application/today_providers.dart'
    show todayNowProvider;
import 'package:radici/features/week_menu/application/week_menu_summaries.dart';
import 'package:radici/features/week_menu/presentation/menu_send_screen.dart';
import 'package:radici/l10n/app_localizations.dart';

/// El pedido admite presupuesto (no es un cambio de una sesión).
bool _quotable(ChefRequest request) => request.type != RequestType.change;

/// El menú de la semana 1 está guardado con algún plato: se puede mandar
/// (null mientras no se sabe).
typedef _WeekOneMenu = ({bool ready, int? version});

_WeekOneMenu? _weekOneMenu(WidgetRef ref, String? sessionId) {
  if (sessionId == null) return null;
  final summary = ref.watch(weekMenuSummaryProvider(sessionId)).value;
  if (summary == null) return null;
  return (ready: summary.saved && summary.dishes > 0, version: summary.version);
}

/// Abre la vista previa del menú de la semana 1 de [quote], que lo lleva.
Future<void> _send(
  BuildContext context,
  WidgetRef ref,
  RequestQuote quote, {
  required String sessionId,
  required int menuVersion,
}) async {
  final inbox = ref.read(chefInboxProvider.notifier);
  final exit = await showMenuSendScreen(
    context,
    sessionId: sessionId,
    menuVersion: menuVersion,
  );
  // Salió: el pedido pasa a «Presupuesto enviado» (la vista previa ya vuelve
  // a leer el presupuesto).
  if (exit == MenuSendExit.sent) unawaited(inbox.reload(quote.requestId));
}

/// «Presupuesto» en el detalle del pedido [request].
class QuoteSection extends ConsumerWidget {
  const QuoteSection({super.key, required this.request});

  final ChefRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!_quotable(request)) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final provider = requestQuoteProvider(request.id);
    // Si el presupuesto dice que el pedido cambió (salió desde otro
    // teléfono, la clienta contestó, venció), la bandeja lo vuelve a leer.
    ref.listen(provider, (previous, next) {
      final quote = next.value;
      if (quote == null || quote == previous?.value) return;
      final status = quote.statusAt(ref.read(todayNowProvider));
      if (requestLooksStale(request.status, quote, status)) {
        unawaited(ref.read(chefInboxProvider.notifier).reload(request.id));
      }
    });
    final quote = ref.watch(provider);
    return quote.when(
      // Sin presupuesto, nada: lo que se puede hacer va abajo.
      data: (quote) => quote == null
          ? const SizedBox.shrink()
          : Column(
              key: const ValueKey('quote-section'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SessionSection(l10n.quoteBlockTitle),
                _QuoteBlock(request: request, quote: quote),
              ],
            ),
      // Mientras carga, nada: la mayoría no tiene presupuesto.
      loading: () => const SizedBox.shrink(),
      error: (_, _) => Column(
        key: const ValueKey('quote-section'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SessionSection(l10n.quoteBlockTitle),
          MergeSemantics(
            child: Text(
              l10n.quoteLoadFailed,
              key: const ValueKey('quote-load-error'),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const ValueKey('quote-retry'),
              onPressed: () => ref.invalidate(provider),
              child: Text(l10n.actionRetry),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuoteBlock extends ConsumerWidget {
  const _QuoteBlock({required this.request, required this.quote});

  final ChefRequest request;
  final RequestQuote quote;

  /// Con VoiceOver o TalkBack el aviso no se va solo: se cierra con la X.
  bool _persist(BuildContext context) =>
      MediaQuery.accessibleNavigationOf(context);

  Future<void> _changePrice(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final persist = _persist(context);
    final weeks = quote.currentTerms.weeks.length;
    final cents = await showQuotePriceDialog(
      context,
      totalCents: quote.currentTerms.totalCents,
      weeks: weeks,
    );
    if (cents == null || !context.mounted) return;
    final commands = ref.read(quoteCommandsProvider);
    try {
      await commands.changePrice(quote, cents);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            quote.wasSent ? l10n.quotePriceDoneResend : l10n.quotePriceDone,
          ),
        ),
      );
    } on QuoteFailure catch (failure) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.quoteFailure(failure, operation: QuoteOperation.changePrice),
          ),
          duration: errorSnackBarDuration,
          persist: persist,
          showCloseIcon: persist,
        ),
      );
    }
  }

  Future<void> _withdraw(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final persist = _persist(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colors = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          key: const ValueKey('quote-withdraw-dialog'),
          title: Text(l10n.quoteWithdrawTitle),
          content: Text(l10n.quoteWithdrawBody),
          actionsOverflowButtonSpacing: 8,
          actions: [
            TextButton(
              key: const ValueKey('quote-withdraw-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.actionCancel),
            ),
            FilledButton(
              key: const ValueKey('quote-withdraw-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.quoteWithdrawConfirm),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(quoteCommandsProvider).withdraw(quote);
      messenger.showSnackBar(SnackBar(content: Text(l10n.quoteWithdrawDone)));
    } on QuoteFailure catch (failure) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.quoteFailure(failure, operation: QuoteOperation.withdraw),
          ),
          duration: errorSnackBarDuration,
          persist: persist,
          showCloseIcon: persist,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final formats = RequestFormats(context);
    final locale = Localizations.localeOf(context).toString();
    final now = ref.watch(todayNowProvider);
    final status = quote.statusAt(now);
    final open = status.isOpen;
    final terms = quote.termsFor(status);
    final weeks = terms?.weeks ?? const <QuoteWeek>[];
    final firstWeek = open ? quote.firstWeek : null;
    final menu = _weekOneMenu(ref, firstWeek?.sessionId);
    final actions = quoteActionsFor(status, hasWeeks: weeks.isNotEmpty);
    final busy = ref.watch(
      quoteBusyProvider.select((ids) => ids.contains(quote.id)),
    );
    final validUntil = l10n.quoteValidUntilText(quote, status, formats);
    final send = quote.lastSend;
    final showChanges =
        send?.changesText != null &&
        (status == QuoteStatus.changesRequested ||
            status == QuoteStatus.changed);

    final (icon, color) = switch (status) {
      QuoteStatus.draft => (Icons.edit_note_outlined, colors.onSurfaceVariant),
      QuoteStatus.sent => (Icons.send_outlined, colors.primary),
      QuoteStatus.changesRequested => (
        Icons.rate_review_outlined,
        colors.tertiary,
      ),
      QuoteStatus.changed => (Icons.update, colors.error),
      QuoteStatus.accepted => (Icons.check_circle_outline, colors.primary),
      QuoteStatus.declined ||
      QuoteStatus.withdrawn ||
      QuoteStatus.expired => (Icons.event_busy, colors.error),
    };

    return Column(
      key: ValueKey('quote-block-${status.name}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (busy) ...[
          const LinearProgressIndicator(key: ValueKey('quote-busy')),
          const SizedBox(height: 8),
        ],
        _Line(
          icon: icon,
          color: color,
          text: l10n.quoteStateText(quote, status, formats),
          textKey: const ValueKey('quote-state'),
          strong: status != QuoteStatus.sent,
        ),
        if (validUntil != null)
          _Indented(
            child: Text(
              validUntil,
              key: const ValueKey('quote-valid-until'),
              style: theme.textTheme.bodyMedium,
            ),
          ),
        if (showChanges && send != null) ...[
          const SizedBox(height: 8),
          _Line(
            icon: Icons.rate_review_outlined,
            color: colors.tertiary,
            text: l10n.quoteStateChangesRequested(
              formats.instantDayMonth(send.changesRequestedAt!),
              formats.instantTime(send.changesRequestedAt!),
            ),
            textKey: const ValueKey('quote-changes'),
            strong: true,
          ),
          _Indented(
            child: _ClientMessage(
              text: send.changesText!,
              textKey: const ValueKey('quote-changes-text'),
            ),
          ),
          if (status == QuoteStatus.changesRequested)
            _Indented(
              child: Text(
                l10n.quoteChangesHint,
                key: const ValueKey('quote-changes-hint'),
                style: theme.textTheme.bodyMedium,
              ),
            ),
        ],
        if (status == QuoteStatus.changed) ...[
          const SizedBox(height: 8),
          _Line(
            icon: Icons.update,
            color: colors.error,
            text: l10n.quoteStateChanged,
            textKey: const ValueKey('quote-changed'),
            strong: true,
          ),
        ],
        if (weeks.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final (index, week) in weeks.indexed)
            ListTile(
              key: ValueKey('quote-week-${week.sessionId}'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: Text(
                l10n.quoteWeekTitle(
                  index + 1,
                  weeks.length,
                  week.date,
                  formats,
                ),
              ),
              subtitle: Text(
                l10n.quoteWeekDetail(
                  week.start.toHhMm(),
                  formatCents(week.serviceCents, locale: locale),
                ),
                key: ValueKey('quote-week-${week.sessionId}-detail'),
              ),
              trailing: open ? const Icon(Icons.chevron_right) : null,
              // Abierto, cada semana se mueve o se cancela desde su ficha.
              onTap: open
                  ? () => unawaited(
                      context.push(AppRoutes.sessionDetail(week.sessionId)),
                    )
                  : null,
            ),
          SessionInfoRow(
            label: l10n.quoteServiceTotal(weeks.length),
            value: formatCents(terms!.totalCents, locale: locale),
            valueKey: const ValueKey('quote-total'),
          ),
          if (open)
            MergeSemantics(
              child: Text(
                l10n.quoteWeeksHint,
                key: const ValueKey('quote-weeks-hint'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
        ] else if (open) ...[
          const SizedBox(height: 8),
          MergeSemantics(
            child: Text(
              l10n.quoteNoWeeks,
              key: const ValueKey('quote-no-weeks'),
              style: theme.textTheme.bodyMedium?.copyWith(color: colors.error),
            ),
          ),
        ],
        if (actions.editMenu && menu != null && !menu.ready) ...[
          const SizedBox(height: 8),
          MergeSemantics(
            child: Text(
              l10n.quoteMenuMissing,
              key: const ValueKey('quote-menu-missing'),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
        if (open) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (actions.editMenu && firstWeek != null)
                FilledButton.tonalIcon(
                  key: const ValueKey('quote-menu'),
                  onPressed: busy
                      ? null
                      : () => unawaited(
                          context.push(
                            AppRoutes.sessionMenu(firstWeek.sessionId),
                          ),
                        ),
                  icon: const Icon(Icons.restaurant_menu),
                  label: Text(
                    (menu?.version != null)
                        ? l10n.weekMenuEdit
                        : l10n.bookingDoneBuildMenu(weeks.length),
                  ),
                ),
              // Mandado y sin novedades, mandarlo de nuevo va acá (no abajo).
              if (actions.resend && !actions.sendIsPrimary && firstWeek != null)
                OutlinedButton.icon(
                  key: const ValueKey('quote-resend'),
                  onPressed: busy || !(menu?.ready ?? false)
                      ? null
                      : () => unawaited(
                          _send(
                            context,
                            ref,
                            quote,
                            sessionId: firstWeek.sessionId,
                            menuVersion: menu!.version!,
                          ),
                        ),
                  icon: const Icon(Icons.send_outlined),
                  label: Text(l10n.quoteActionResend),
                ),
              if (actions.changePrice)
                OutlinedButton.icon(
                  key: const ValueKey('quote-change-price'),
                  onPressed: busy
                      ? null
                      : () => unawaited(_changePrice(context, ref)),
                  icon: const Icon(Icons.euro_outlined),
                  label: Text(l10n.quoteActionChangePrice),
                ),
              if (actions.withdraw)
                OutlinedButton.icon(
                  key: const ValueKey('quote-withdraw'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colors.error,
                  ),
                  onPressed: busy
                      ? null
                      : () => unawaited(_withdraw(context, ref)),
                  icon: const Icon(Icons.block),
                  label: Text(l10n.quoteActionWithdraw),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Abajo, en el detalle del pedido [request]: «Mandar» cuando es el paso que
/// falta de un presupuesto abierto (o por qué todavía no: falta el menú de la
/// semana 1); si no tiene uno abierto y está nuevo, «Preparar presupuesto»
/// (la principal); y, en un pedido nuevo o con el presupuesto mandado,
/// «Confirmar sin presupuesto» (la hoja de siempre: con uno abierto, avisa
/// que lo retira). Si no, nada.
class RequestActionsBar extends ConsumerWidget {
  const RequestActionsBar({super.key, required this.request});

  final ChefRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!_quotable(request)) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final quote = ref.watch(requestQuoteProvider(request.id)).value;
    final open = quote != null && quote.isOpen;
    final toSend =
        quote != null &&
            quote.isOpen &&
            _sendIsTheStep(quote, ref.watch(todayNowProvider))
        ? quote
        : null;
    final menu = _weekOneMenu(ref, toSend?.firstWeek?.sessionId);
    // La principal, a la derecha (como «Mover» en la ficha de una sesión):
    // mandar el presupuesto si es lo que falta o, sin uno abierto, prepararlo.
    final Widget? primary = toSend != null
        ? _QuoteSendButton(quote: toSend, menu: menu)
        : !open && request.canPrepareQuote
        ? FilledButton(
            key: const ValueKey('action-prepare-quote'),
            onPressed: () => context.push(AppRoutes.requestQuote(request.id)),
            child: Text(l10n.actionPrepareQuote, textAlign: TextAlign.center),
          )
        : null;
    final Widget? confirm = request.canConfirmBooking
        ? OutlinedButton(
            key: const ValueKey('action-confirm-booking'),
            onPressed: () => context.push(AppRoutes.requestBooking(request.id)),
            child: Text(
              l10n.actionConfirmWithoutQuote,
              textAlign: TextAlign.center,
            ),
          )
        : null;
    if (primary == null && confirm == null) return const SizedBox.shrink();
    return SessionBottomBar(
      children: [
        if (toSend != null && menu != null && !menu.ready) ...[
          MergeSemantics(
            child: Text(
              l10n.quoteMenuMissing,
              key: const ValueKey('quote-send-needs-menu'),
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: 8),
        ],
        // Una al lado de la otra: con el texto grande, en un teléfono, dos
        // botones apilados tapaban medio pedido.
        // Del mismo alto aunque un texto ocupe más renglones.
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (confirm != null) Expanded(child: confirm),
              if (confirm != null && primary != null) const SizedBox(width: 12),
              if (primary != null) Expanded(child: primary),
            ],
          ),
        ),
      ],
    );
  }
}

/// Mandar [quote] es el paso que falta en [now]: sin mandar, cambiado o con
/// cambios pedidos, con alguna semana viva.
bool _sendIsTheStep(RequestQuote quote, DateTime now) {
  final actions = quoteActionsFor(
    quote.statusAt(now),
    hasWeeks: quote.firstWeek != null,
  );
  return actions.sendIsPrimary && (actions.send || actions.resend);
}

/// «Mandar el presupuesto» o «Mandar de nuevo»: la vista previa del menú de
/// la semana 1, si está guardado con algún plato ([menu]).
class _QuoteSendButton extends ConsumerWidget {
  const _QuoteSendButton({required this.quote, required this.menu});

  final RequestQuote quote;
  final _WeekOneMenu? menu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final firstWeek = quote.firstWeek;
    final status = quote.statusAt(ref.watch(todayNowProvider));
    final busy = ref.watch(
      quoteBusyProvider.select((ids) => ids.contains(quote.id)),
    );
    final version = menu?.version;
    final ready = (menu?.ready ?? false) && version != null;
    return FilledButton(
      key: const ValueKey('quote-send'),
      onPressed: !ready || busy || firstWeek == null
          ? null
          : () => unawaited(
              _send(
                context,
                ref,
                quote,
                sessionId: firstWeek.sessionId,
                menuVersion: version,
              ),
            ),
      child: Text(
        status == QuoteStatus.draft
            ? l10n.quoteActionSend
            : l10n.quoteActionResend,
        textAlign: TextAlign.center,
      ),
    );
  }
}

/// Un renglón del estado: el ícono y el texto, un solo nodo para el lector de
/// pantalla.
class _Line extends StatelessWidget {
  const _Line({
    required this.icon,
    required this.color,
    required this.text,
    required this.textKey,
    this.strong = false,
  });

  final IconData icon;
  final Color color;
  final String text;
  final Key textKey;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 20, color: color),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              key: textKey,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: strong ? FontWeight.w600 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Alineado con el texto de un [_Line] (ícono de 20 y espacio de 8).
class _Indented extends StatelessWidget {
  const _Indented({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.only(start: 28, top: 4),
    child: MergeSemantics(child: child),
  );
}

/// El mensaje de la clienta al pedir cambios, entero y como lo escribió (con
/// sus saltos de línea), para leerlo y copiarlo. Solo se ve en la app.
class _ClientMessage extends StatelessWidget {
  const _ClientMessage({required this.text, required this.textKey});

  final String text;
  final Key textKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        border: BorderDirectional(
          start: BorderSide(color: colors.tertiary, width: 3),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: SelectableText(
          text,
          key: textKey,
          style: theme.textTheme.bodyMedium,
        ),
      ),
    );
  }
}

/// «Otro precio»: el precio del servicio de todas las semanas, con su reparto
/// exacto. Devuelve los centavos, o null si se canceló (o si no cambió).
Future<int?> showQuotePriceDialog(
  BuildContext context, {
  required int totalCents,
  required int weeks,
}) => showDialog<int>(
  context: context,
  builder: (_) => QuotePriceDialog(totalCents: totalCents, weeks: weeks),
);

class QuotePriceDialog extends StatefulWidget {
  const QuotePriceDialog({
    super.key,
    required this.totalCents,
    required this.weeks,
  });

  /// El precio de ahora.
  final int totalCents;

  /// Las semanas vivas, entre las que se reparte.
  final int weeks;

  @override
  State<QuotePriceDialog> createState() => _QuotePriceDialogState();
}

class _QuotePriceDialogState extends State<QuotePriceDialog> {
  late final TextEditingController _price = TextEditingController();
  bool _filled = false;

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  void _save() {
    final read = readQuotePrice(_price.text);
    final cents = read.cents;
    if (cents == null) return;
    Navigator.of(context).pop(cents == widget.totalCents ? null : cents);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toString();
    if (!_filled) {
      _filled = true;
      _price.text = formatCentsForInput(widget.totalCents, locale: locale);
    }
    return AlertDialog(
      key: const ValueKey('quote-price-dialog'),
      // Arriba: el teclado de iOS no la tapa.
      alignment: Alignment.topCenter,
      scrollable: true,
      title: Text(l10n.quotePriceTitle),
      content: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _price,
        builder: (context, value, _) {
          final read = readQuotePrice(value.text);
          final cents = read.cents;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.quotePriceHelp, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('quote-price-field'),
                controller: _price,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _save(),
                // 16 px o más: con menos, iOS agranda la página al enfocar.
                style: theme.textTheme.bodyLarge,
                decoration: InputDecoration(
                  labelText: l10n.bookingPriceLabel(widget.weeks),
                  suffixText: '€',
                  helperText: cents == null
                      ? null
                      : l10n.quotePriceSplitText(
                          cents,
                          widget.weeks,
                          locale: locale,
                        ),
                  helperMaxLines: 3,
                  errorText: switch (read.issue) {
                    QuotePriceIssue.required => l10n.bookingPriceRequired,
                    QuotePriceIssue.invalid => l10n.bookingPriceInvalid,
                    QuotePriceIssue.tooHigh => l10n.bookingPriceTooHigh(
                      formatCents(maxQuoteCents, locale: locale),
                    ),
                    null => null,
                  },
                  errorMaxLines: 2,
                ),
              ),
            ],
          );
        },
      ),
      actionsOverflowButtonSpacing: 8,
      actions: [
        TextButton(
          key: const ValueKey('quote-price-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _price,
          builder: (context, value, _) => FilledButton(
            key: const ValueKey('quote-price-save'),
            onPressed: readQuotePrice(value.text).cents == null ? null : _save,
            child: Text(l10n.quotePriceSave),
          ),
        ),
      ],
    );
  }
}
