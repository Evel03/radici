// Enlaces de la ficha de la sesión: WhatsApp (con un mensaje en el idioma de
// la clienta, la fecha y la hora de llegada: nunca la dirección ni las
// alergias), llamar y «Cómo llegar» (la dirección de la ficha en Mapas).
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

/// Arma los links de [session]. [chefName] firma el WhatsApp.
SessionLinks sessionLinksFor(
  CookingSession session, {
  required String chefName,
  required bool appleMaps,
}) {
  final locale = session.locale.name;
  final l10n = lookupAppLocalizations(Locale(locale));
  final name = session.firstName.isNotEmpty
      ? session.firstName
      : session.displayName;
  final phone = session.phoneE164;
  final message = session.isLive
      ? l10n.sessionWhatsAppMessage(
          name,
          chefName,
          l10n.appTitle,
          messageDateFormat(locale).format(session.date.toDateTime()),
          session.start.toHhMm(),
        )
      : l10n.contactWhatsAppMessage(name, chefName, l10n.appTitle);
  return SessionLinks(
    whatsApp: whatsAppUri(phoneE164: phone, message: message),
    call: phoneCallUri(phone),
    directions: directionsUri(address: session.address, apple: appleMaps),
  );
}

/// Los links de la ficha de la sesión [id], o null mientras no esté cargada.
final sessionLinksProvider = Provider.autoDispose.family<SessionLinks?, String>(
  (ref, id) {
    final session = ref.watch(sessionDetailProvider(id)).value?.session;
    if (session == null) return null;
    return sessionLinksFor(
      session,
      chefName: ref.watch(currentChefProvider)?.displayName ?? '',
      appleMaps: ref.watch(appleMapsProvider),
    );
  },
);
