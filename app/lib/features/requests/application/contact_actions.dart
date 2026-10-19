// Links de contacto de un pedido, con los textos en el idioma del cliente
// (requests.locale), no en el del dispositivo de Evelyn.
import 'dart:ui' show Locale;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mestolo/features/auth/application/session_controller.dart';
import 'package:mestolo/features/requests/application/chef_inbox_controller.dart';
import 'package:mestolo/features/requests/domain/chef_request.dart';
import 'package:mestolo/features/requests/domain/contact_links.dart';
import 'package:mestolo/l10n/app_localizations.dart';

/// Links para contactar al cliente; null si no hay teléfono o email válido.
class ContactLinks {
  const ContactLinks({this.whatsApp, this.call, this.email});

  final Uri? whatsApp;
  final Uri? call;
  final Uri? email;
}

/// Arma los links de [request]. [chefName] firma el mensaje de WhatsApp.
ContactLinks contactLinksFor(ChefRequest request, {required String chefName}) {
  final l10n = lookupAppLocalizations(Locale(request.locale.name));
  final client = request.client;
  final name = client.firstName.isNotEmpty
      ? client.firstName
      : client.displayName;
  final phone = client.phoneE164;
  return ContactLinks(
    whatsApp: whatsAppUri(
      phoneE164: phone,
      message: l10n.contactWhatsAppMessage(name, chefName, l10n.appTitle),
    ),
    call: phoneCallUri(phone),
    email: emailUri(
      email: client.contactEmail,
      subject: l10n.contactEmailSubject(l10n.appTitle),
      body: '${l10n.contactEmailGreeting(name)}\n\n',
    ),
  );
}

/// Links del pedido [requestId], o null mientras no esté cargado.
final contactLinksProvider = Provider.autoDispose.family<ContactLinks?, String>((
  ref,
  requestId,
) {
  final request = ref.watch(chefRequestProvider(requestId)).value;
  if (request == null) return null;
  final chefName = ref.watch(currentChefProvider)?.displayName ?? '';
  return contactLinksFor(request, chefName: chefName);
});
