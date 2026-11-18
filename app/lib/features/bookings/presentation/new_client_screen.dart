// «Nuova cliente»: los datos de una ficha nueva para una reserva a mano, en
// el orden de la decisión del dueño (nombre, teléfono, zona, dirección,
// adultos y niños, y el idioma de sus mensajes). Lo escrito vive en el
// borrador del flujo (newClientFormProvider): volver al elegir no lo borra.
//
// Abajo, en el cuerpo para que quede arriba del teclado, «Continua» o, si el
// teléfono ya es de una ficha, «Usa la scheda di…» (la acción principal) y
// «Crea una scheda nuova». Arriba de «Continua» (o debajo de «Crea una scheda
// nuova», lo único que frena cuando el teléfono ya es de una ficha), lo que
// impide seguir con «Vedi», que lleva al campo y le da el foco: a 375×667 el
// campo queda fuera de la vista.
//
// Ningún campo lleva autofillHints: en /gestione/, Safari ofrecería en un
// campo de teléfono los números de la tarjeta propia del iPhone, y el
// WhatsApp de la reserva iría a Evelyn. Letra de 16 px (con menos, iOS
// agranda la página al enfocar). Solo lee providers.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/bookings/application/new_client_form_controller.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/presentation/booking_widgets.dart';
import 'package:radici/features/bookings/presentation/counter_row.dart';
import 'package:radici/features/clients/application/client_directory_controller.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart'
    show maxClientAddressLength;
import 'package:radici/l10n/app_localizations.dart';

class NewClientScreen extends ConsumerStatefulWidget {
  const NewClientScreen({super.key});

  @override
  ConsumerState<NewClientScreen> createState() => _NewClientScreenState();
}

class _NewClientScreenState extends ConsumerState<NewClientScreen> {
  // Lo escrito vuelve del borrador al volver a abrir el formulario.
  late final NewClientForm _initial = ref.read(newClientFormProvider);
  late final TextEditingController _name = TextEditingController(
    text: _initial.name,
  );
  late final TextEditingController _phone = TextEditingController(
    text: _initial.phoneText,
  );
  late final TextEditingController _zone = TextEditingController(
    text: _initial.zone,
  );
  late final TextEditingController _address = TextEditingController(
    text: _initial.address,
  );

  final Map<NewClientField, FocusNode> _focus = {
    for (final field in NewClientField.values) field: FocusNode(),
  };
  final Map<NewClientField, GlobalKey> _fieldKeys = {
    for (final field in NewClientField.values) field: GlobalKey(),
  };

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _zone.dispose();
    _address.dispose();
    for (final node in _focus.values) {
      node.dispose();
    }
    super.dispose();
  }

  NewClientFormController get _controller =>
      ref.read(newClientFormProvider.notifier);

  /// Lleva [field] a la vista y le da el foco.
  void _show(NewClientField field) {
    final target = _fieldKeys[field]!.currentContext;
    if (target != null) {
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignment: 0.2,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        ),
      );
    }
    _focus[field]!.requestFocus();
  }

  /// El campo de lo que dice la barra.
  void _showBlocker(NewClientForm form) {
    switch (form.blocker) {
      case NewClientBlocker.nameMissing:
        _show(NewClientField.name);
      case NewClientBlocker.phoneInvalid:
        _show(NewClientField.phone);
      case NewClientBlocker.tooLong:
        _show(
          NewClientField.values.firstWhere(form.tooLong.contains),
        );
      case null:
        break;
    }
  }

  /// «Continua» o «Crea una scheda nuova»: con todo bien, la hoja de la
  /// ficha nueva; si no, quedan a la vista los errores.
  void _continue() {
    if (_controller.submit()) context.push(AppRoutes.newBookingSheet());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final form = ref.watch(newClientFormProvider);
    final match = ref.watch(newClientPhoneMatchProvider);
    final found = match is PhoneMatchFound ? match.client : null;
    String? tooLong(NewClientField field) =>
        form.submitted && form.tooLong.contains(field)
        ? l10n.newClientTooLong
        : null;

    final blocker = form.blocker;
    final canGo = blocker == null;
    // Lo que impide seguir. Con el teléfono de una ficha va debajo de «Crea
    // una scheda nuova», que es lo único que frena: «Usa la scheda di…» no
    // necesita el nombre ni los demás campos.
    final blockerLine = blocker == null
        ? null
        : BookingBarLine(
            textKey: 'new-client-blocker',
            text: switch (blocker) {
              NewClientBlocker.nameMissing =>
                found == null
                    ? l10n.newClientNameMissing
                    : l10n.newClientCreateNeedsName,
              NewClientBlocker.phoneInvalid => l10n.newClientPhoneInvalidShort,
              NewClientBlocker.tooLong => l10n.newClientTooLong,
            },
            color: blocker == NewClientBlocker.nameMissing
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.error,
            actionKey: 'new-client-blocker-show',
            actionLabel: l10n.bookingShowProblem,
            onAction: () => _showBlocker(form),
            padding: found == null
                ? const EdgeInsets.only(bottom: 8)
                : const EdgeInsets.only(top: 8),
          );

    return Scaffold(
      appBar: AppBar(title: Text(l10n.newClientAction)),
      body: Column(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: bookingMaxContentWidth,
                ),
                child: SingleChildScrollView(
                  key: const ValueKey('new-client-form'),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      KeyedSubtree(
                        key: _fieldKeys[NewClientField.name],
                        child: TextField(
                          key: const ValueKey('new-client-name'),
                          controller: _name,
                          focusNode: _focus[NewClientField.name],
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.next,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(
                              maxClientNameLength,
                            ),
                          ],
                          style: theme.textTheme.bodyLarge,
                          decoration: InputDecoration(
                            labelText: l10n.newClientNameLabel,
                            errorText: tooLong(NewClientField.name),
                          ),
                          onChanged: _controller.setName,
                        ),
                      ),
                      const SizedBox(height: 16),
                      KeyedSubtree(
                        key: _fieldKeys[NewClientField.phone],
                        child: TextField(
                          key: const ValueKey('new-client-phone'),
                          controller: _phone,
                          focusNode: _focus[NewClientField.phone],
                          keyboardType: TextInputType.phone,
                          textInputAction: TextInputAction.next,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(
                              maxClientPhoneLength,
                            ),
                          ],
                          // Al enfocarlo sube con lugar para la tarjeta del
                          // teléfono repetido.
                          scrollPadding: const EdgeInsets.fromLTRB(
                            20,
                            20,
                            20,
                            160,
                          ),
                          style: theme.textTheme.bodyLarge,
                          decoration: InputDecoration(
                            labelText: l10n.newClientPhoneLabel,
                            helperText: form.showPhoneError
                                ? null
                                : l10n.newClientPhoneHelper,
                            helperMaxLines: 2,
                            // liveRegion: el lector de pantalla lo anuncia.
                            error: form.showPhoneError
                                ? Semantics(
                                    liveRegion: true,
                                    child: Text(
                                      l10n.newClientPhoneInvalid,
                                      key: const ValueKey(
                                        'new-client-phone-error',
                                      ),
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme.colorScheme.error,
                                          ),
                                    ),
                                  )
                                : null,
                          ),
                          onChanged: _controller.setPhone,
                        ),
                      ),
                      _PhoneCheck(match: match),
                      const SizedBox(height: 16),
                      KeyedSubtree(
                        key: _fieldKeys[NewClientField.zone],
                        child: TextField(
                          key: const ValueKey('new-client-zone'),
                          controller: _zone,
                          focusNode: _focus[NewClientField.zone],
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.next,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(
                              maxClientZoneLength,
                            ),
                          ],
                          style: theme.textTheme.bodyLarge,
                          decoration: InputDecoration(
                            labelText: l10n.newClientZoneLabel,
                            hintText: l10n.newClientZoneHint,
                            errorText: tooLong(NewClientField.zone),
                          ),
                          onChanged: _controller.setZone,
                        ),
                      ),
                      const SizedBox(height: 16),
                      KeyedSubtree(
                        key: _fieldKeys[NewClientField.address],
                        child: TextField(
                          key: const ValueKey('new-client-address'),
                          controller: _address,
                          focusNode: _focus[NewClientField.address],
                          keyboardType: TextInputType.streetAddress,
                          textCapitalization: TextCapitalization.sentences,
                          textInputAction: TextInputAction.done,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(
                              maxClientAddressLength,
                            ),
                          ],
                          style: theme.textTheme.bodyLarge,
                          decoration: InputDecoration(
                            labelText: l10n.newClientAddressLabel,
                            hintText: l10n.sessionAddressHint,
                            helperText: l10n.sessionAddressHelper,
                            helperMaxLines: 3,
                            errorText: tooLong(NewClientField.address),
                            errorMaxLines: 2,
                          ),
                          onChanged: _controller.setAddress,
                        ),
                      ),
                      const SizedBox(height: 8),
                      CounterRow(
                        keyPrefix: 'new-client-adults',
                        label: l10n.quoteAdults,
                        value: '${form.household.adults}',
                        onDecrement: form.household.canDecrement(
                              HouseholdCounter.adults,
                            )
                            ? () => _controller.stepAdults(-1)
                            : null,
                        onIncrement: form.household.canIncrement(
                              HouseholdCounter.adults,
                            )
                            ? () => _controller.stepAdults(1)
                            : null,
                      ),
                      CounterRow(
                        keyPrefix: 'new-client-kids',
                        label: l10n.quoteKids,
                        value: '${form.household.kids}',
                        onDecrement: form.household.canDecrement(
                              HouseholdCounter.kids,
                            )
                            ? () => _controller.stepKids(-1)
                            : null,
                        onIncrement: form.household.canIncrement(
                              HouseholdCounter.kids,
                            )
                            ? () => _controller.stepKids(1)
                            : null,
                      ),
                      BookingSectionTitle(l10n.clientMessagesLanguage),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final language in ClientLocale.values)
                            ChoiceChip(
                              key: ValueKey('new-client-locale-${language.name}'),
                              label: Text(l10n.language(language)),
                              selected: form.locale == language,
                              onSelected: (_) =>
                                  _controller.setLocale(language),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          BookingBottomBar(
            children: [
              if (found == null) ?blockerLine,
              if (found != null) ...[
                // El teléfono ya es de esa ficha: usarla es la acción
                // principal (no la modifica). Crear otra se puede igual.
                FilledButton(
                  key: const ValueKey('new-client-use-existing'),
                  onPressed: () => context.pushReplacement(
                    AppRoutes.newBookingSheet(
                      clientId: found.id,
                      fromForm: true,
                    ),
                  ),
                  child: Text(l10n.newClientUseExisting(found.displayName)),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  key: const ValueKey('new-client-create-anyway'),
                  onPressed: canGo ? _continue : null,
                  child: Text(l10n.newClientCreateAnyway),
                ),
                ?blockerLine,
              ] else
                FilledButton(
                  key: const ValueKey('new-client-continue'),
                  onPressed: canGo ? _continue : null,
                  child: Text(l10n.newClientContinue),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Debajo del teléfono: si ya es de una ficha (la tarjeta, que el lector de
/// pantalla anuncia aunque el foco siga en el campo), si todavía se está
/// comprobando o si no se pudo comprobar. Nada de esto impide continuar.
class _PhoneCheck extends ConsumerWidget {
  const _PhoneCheck({required this.match});

  final PhoneMatch match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final secondary = theme.textTheme.bodyMedium?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return switch (match) {
      PhoneMatchFound(:final client) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: DecoratedBox(
          key: const ValueKey('new-client-phone-taken'),
          decoration: BoxDecoration(
            color: colors.tertiaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: colors.onTertiaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      l10n.newClientPhoneTaken(client.displayName),
                      key: const ValueKey('new-client-phone-taken-text'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onTertiaryContainer,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      PhoneMatchChecking() => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.newClientPhoneChecking,
                key: const ValueKey('new-client-phone-checking'),
                style: secondary,
              ),
            ),
          ],
        ),
      ),
      PhoneMatchUnchecked() => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                l10n.newClientPhoneUnchecked,
                key: const ValueKey('new-client-phone-unchecked'),
                style: secondary,
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const ValueKey('new-client-phone-retry'),
              onPressed: () => ref.invalidate(clientDirectoryProvider),
              child: Text(l10n.actionRetry),
            ),
          ],
        ),
      ),
      NoPhoneMatch() => const SizedBox.shrink(),
    };
  }
}
