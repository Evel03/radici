// Enlaces de la ficha de la sesión: WhatsApp (con un mensaje en el idioma de
// la clienta, la fecha y la hora de llegada: nunca la dirección ni las
// alergias), llamar y «Cómo llegar» (la dirección de la ficha en Mapas). El
// WhatsApp sale del teléfono de quien usa la app: si es un colaborador de
// Evelyn, escribe de parte de ella.
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/bookings/application/booking_message.dart';
import 'package:radici/features/requests/domain/contact_links.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_links.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Links para la sesión; cada uno null si falta el dato (teléfono válido o
/// dirección).
class SessionLinks {
  const SessionLinks({this.whatsApp, this.call, this.directions});

  final Uri? whatsApp;
  final Uri? call;
  final Uri? directions;
}

/// En un iPhone o una Mac (también la web en Safari), Apple Maps; si no,
/// Google Maps. En la web, Flutter deduce la plataforma del navegador.
final appleMapsProvider = Provider<bool>(
  (ref) =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS,
);

/// Arma los links de [session]. [chefName] firma el WhatsApp: con la fecha y
/// la hora si la sesión no está cancelada; si lo está, el saludo del detalle
/// del pedido. Con [onBehalf] (un colaborador de la cocinera, que lo manda
/// desde su propio teléfono) escribe de parte de ella, sin decir que es ella
/// ni que es quien llega: «ti scrivo da parte di Evelyn…».
SessionLinks sessionLinksFor(
  CookingSession session, {
  required String chefName,
  required bool appleMaps,
  bool onBehalf = false,
}) {
  final locale = session.locale.name;
  final l10n = lookupAppLocalizations(Locale(locale));
  final name = session.firstName.isNotEmpty
      ? session.firstName
      : session.displayName;
  final phone = session.phoneE164;
  final brand = l10n.appTitle;
  final String message;
  if (session.isLive) {
    final compose = onBehalf
        ? l10n.sessionWhatsAppMessageOnBehalf
        : l10n.sessionWhatsAppMessage;
    message = compose(
      name,
      chefName,
      brand,
      messageDateFormat(locale).format(session.date.toDateTime()),
      session.start.toHhMm(),
    );
  } else {
    message = onBehalf
        ? l10n.contactWhatsAppMessageOnBehalf(name, chefName, brand)
        : l10n.contactWhatsAppMessage(name, chefName, brand);
  }
  return SessionLinks(
    whatsApp: whatsAppUri(phoneE164: phone, message: message),
    call: phoneCallUri(phone),
    directions: directionsUri(address: session.address, apple: appleMaps),
  );
}

/// Los links de la ficha de la sesión [id], o null mientras no esté cargada.
/// Con la cuenta de un colaborador (ChefAccount.collaborator), el WhatsApp
/// escribe de parte de la cocinera.
final sessionLinksProvider = Provider.autoDispose.family<SessionLinks?, String>(
  (ref, id) {
    final session = ref.watch(sessionDetailProvider(id)).value?.session;
    if (session == null) return null;
    final chef = ref.watch(currentChefProvider);
    return sessionLinksFor(
      session,
      chefName: chef?.displayName ?? '',
      appleMaps: ref.watch(appleMapsProvider),
      onBehalf: chef?.collaborator ?? false,
    );
  },
);
