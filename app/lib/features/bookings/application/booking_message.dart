// Mensaje de WhatsApp a la clienta cuando se confirma la reserva: en el
// idioma de la clienta (requests.locale), no en el de la app, con las fechas
// y la hora. Nunca la dirección ni las alergias (CLAUDE.md). Sale del teléfono
// de quien confirma: si es un colaborador de Evelyn, escribe de parte de ella.
import 'dart:ui' show Locale;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/bookings/application/confirm_booking_controller.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/domain/contact_links.dart';
import 'package:radici/l10n/app_localizations.dart';

/// `wa.me` con la confirmación de [result] para la clienta de [request],
/// firmada por [chefName]: «Ti confermo le 4 sessioni…», una fecha por línea,
/// y la hora de llegada. Con [onBehalf] (un colaborador de la cocinera, que lo
/// manda desde su propio teléfono) escribe de parte de ella, sin decir que es
/// ella ni que es quien llega: «ti scrivo da parte di Evelyn…». null sin un
/// teléfono válido (o sin semanas).
Uri? bookingWhatsAppUri({
  required ChefRequest request,
  required BookingResult result,
  required String chefName,
  bool onBehalf = false,
}) {
  final weeks = result.weeks;
  if (weeks.isEmpty) return null;
  final locale = request.locale.name;
  final l10n = lookupAppLocalizations(Locale(locale));
  final client = request.client;
  final name = client.firstName.isNotEmpty
      ? client.firstName
      : client.displayName;
  final format = _messageDateFormat(locale);
  final dates = [
    for (final week in weeks) format.format(week.date.toDateTime()),
  ];
  final compose = onBehalf
      ? l10n.bookingWhatsAppMessageOnBehalf
      : l10n.bookingWhatsAppMessage;
  return whatsAppUri(
    phoneE164: client.phoneE164,
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

/// Fecha de cada sesión en el mensaje: «lunedì 23 novembre», «Monday,
/// November 23» y, en español, «lunes 23 de noviembre» (en prosa, sin la coma
/// del formato de intl: «del lunes 23 de noviembre»).
DateFormat _messageDateFormat(String locale) => locale == 'es'
    ? DateFormat("EEEE d 'de' MMMM", 'es')
    : DateFormat.MMMMEEEEd(locale);

/// El WhatsApp de la reserva recién confirmada en la hoja de [requestId];
/// null mientras no esté confirmada o sin teléfono válido.
final bookingWhatsAppProvider = Provider.autoDispose.family<Uri?, String>((
  ref,
  requestId,
) {
  final result = ref.watch(
    confirmBookingProvider(requestId).select((state) => state.result),
  );
  final request = ref.watch(chefRequestProvider(requestId)).value;
  if (result == null || request == null) return null;
  final chef = ref.watch(currentChefProvider);
  return bookingWhatsAppUri(
    request: request,
    result: result,
    chefName: chef?.displayName ?? '',
    onBehalf: chef?.collaborator ?? false,
  );
});
