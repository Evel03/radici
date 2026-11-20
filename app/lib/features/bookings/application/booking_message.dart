// Mensaje de WhatsApp a la clienta cuando se confirma la reserva: en el
// idioma de la clienta (el del pedido o, a mano, el que eligió Evelyn), no en
// el de la app, con las fechas y la hora. Nunca la dirección ni las alergias
// (CLAUDE.md). Sale del teléfono de quien confirma: si es un colaborador de
// Evelyn, escribe de parte de ella.
import 'dart:ui' show Locale;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/bookings/application/booking_seed.dart';
import 'package:radici/features/bookings/application/confirm_booking_controller.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/domain/contact_links.dart';
import 'package:radici/l10n/app_localizations.dart';

/// `wa.me` con la confirmación de [result] para [party], en [locale] y
/// firmada por [chefName]: «Ti confermo le 4 sessioni…», una fecha por línea,
/// y la hora de llegada. Con [onBehalf] (un colaborador de la cocinera, que lo
/// manda desde su propio teléfono) escribe de parte de ella, sin decir que es
/// ella ni que es quien llega: «ti scrivo da parte di Evelyn…». null sin un
/// teléfono válido (o sin semanas).
Uri? bookingWhatsAppUriFor({
  required BookingParty party,
  required ClientLocale locale,
  required BookingResult result,
  required String chefName,
  bool onBehalf = false,
}) {
  final weeks = result.weeks;
  if (weeks.isEmpty) return null;
  final l10n = lookupAppLocalizations(Locale(locale.name));
  final name = party.firstName.isNotEmpty ? party.firstName : party.displayName;
  final format = messageDateFormat(locale.name);
  final dates = [
    for (final week in weeks) format.format(week.date.toDateTime()),
  ];
  final compose = onBehalf
      ? l10n.bookingWhatsAppMessageOnBehalf
      : l10n.bookingWhatsAppMessage;
  return whatsAppUri(
    phoneE164: party.phoneE164,
    message: compose(
      weeks.length,
      name,
      chefName,
      l10n.appTitle,
      weeks.first.start?.toHhMm() ?? '',
      dates.length == 1
          ? dates.single
          : [for (final date in dates) '• $date'].join('\n'),
    ),
  );
}

/// El mismo mensaje para la clienta de [request], en su idioma
/// (`requests.locale`).
Uri? bookingWhatsAppUri({
  required ChefRequest request,
  required BookingResult result,
  required String chefName,
  bool onBehalf = false,
}) => bookingWhatsAppUriFor(
  party: BookingParty.fromRequest(request),
  locale: request.locale,
  result: result,
  chefName: chefName,
  onBehalf: onBehalf,
);

/// Fecha de una sesión en un mensaje a la clienta: «lunedì 23 novembre»,
/// «Monday, November 23» y, en español, «lunes 23 de noviembre» (en prosa,
/// sin la coma del formato de intl: «del lunes 23 de noviembre»). También la
/// usa el WhatsApp de la ficha de la sesión.
DateFormat messageDateFormat(String locale) => locale == 'es'
    ? DateFormat("EEEE d 'de' MMMM", 'es')
    : DateFormat.MMMMEEEEd(locale);

/// El WhatsApp de la reserva recién confirmada en la hoja de [source]: el
/// resultado, el destinatario y el idioma salen del estado de la hoja (no del
/// seed, que después de confirmar una ficha nueva ya no está). null mientras
/// no esté confirmada o sin teléfono válido.
final bookingWhatsAppProvider = Provider.autoDispose
    .family<Uri?, BookingSource>((ref, source) {
      final (result, party, locale) = ref.watch(
        confirmBookingProvider(
          source,
        ).select((state) => (state.result, state.party, state.locale)),
      );
      if (result == null || party == null) return null;
      final chef = ref.watch(currentChefProvider);
      return bookingWhatsAppUriFor(
        party: party,
        locale: locale,
        result: result,
        chefName: chef?.displayName ?? '',
        onBehalf: chef?.collaborator ?? false,
      );
    });
