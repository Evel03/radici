// Los mensajes al cliente van en SU idioma (requests.locale), no en el del
// dispositivo de Evelyn.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/requests/application/contact_actions.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/request_fixtures.dart';

void main() {
  test('cliente italiano: WhatsApp, llamada y email en italiano', () {
    final links = contactLinksFor(buildRequest(), chefName: 'Evelyn');

    expect(links.whatsApp!.host, 'wa.me');
    expect(links.whatsApp!.path, '/393331234567');
    expect(
      links.whatsApp!.queryParameters['text'],
      'Ciao Giulia, sono Evelyn di Radici. Ho ricevuto la tua richiesta e ti '
      'scrivo per organizzarci.',
    );
    expect(links.call.toString(), 'tel:+393331234567');
    expect(links.email!.path, 'giulia@example.test');
    expect(links.email!.queryParameters['subject'], 'La tua richiesta a Radici');
    expect(links.email!.queryParameters['body'], 'Ciao Giulia,\n\n');
  });

  test('cliente hispanohablante con número español', () {
    final links = contactLinksFor(
      buildRequest(
        name: 'Lucía Fernández',
        phone: '+34 612 345 678',
        locale: ClientLocale.es,
      ),
      chefName: 'Evelyn',
    );
    expect(links.whatsApp!.path, '/34612345678');
    expect(
      links.whatsApp!.queryParameters['text'],
      'Hola Lucía, soy Evelyn de Radici. Recibí tu solicitud y te escribo '
      'para organizarnos.',
    );
    expect(links.email!.queryParameters['subject'], 'Tu solicitud a Radici');
    expect(links.email!.queryParameters['body'], 'Hola Lucía:\n\n');
  });

  test('cliente en inglés', () {
    final links = contactLinksFor(
      buildRequest(name: 'John', locale: ClientLocale.en),
      chefName: 'Evelyn',
    );
    expect(
      links.whatsApp!.queryParameters['text'],
      startsWith('Hi John, this is Evelyn from Radici.'),
    );
    expect(links.email!.queryParameters['subject'], 'Your request to Radici');
  });

  test('un colaborador de la cocinera escribe de parte de ella, en el idioma del cliente', () {
    // Sale de su propio teléfono: el mensaje no dice «sono Evelyn».
    String message(ClientLocale locale) =>
        contactLinksFor(
          buildRequest(locale: locale),
          chefName: 'Evelyn',
          onBehalf: true,
        ).whatsApp!.queryParameters['text']!;

    expect(
      message(ClientLocale.it),
      'Ciao Giulia, ti scrivo da parte di Evelyn di Radici: abbiamo ricevuto '
      'la tua richiesta e vorremmo organizzarci con te.',
    );
    expect(
      message(ClientLocale.es),
      'Hola Giulia, te escribo de parte de Evelyn de Radici: recibimos tu '
      'solicitud y queremos organizarnos contigo.',
    );
    expect(
      message(ClientLocale.en),
      "Hi Giulia, I'm writing on behalf of Evelyn from Radici: we got your "
      'request and would like to sort out the details with you.',
    );
    // La llamada y el email no firman: son los mismos.
    final links = contactLinksFor(buildRequest(), chefName: 'Evelyn', onBehalf: true);
    expect(links.call.toString(), 'tel:+393331234567');
    expect(links.email!.queryParameters['body'], 'Ciao Giulia,\n\n');
  });

  test('sin teléfono válido no hay WhatsApp ni llamada; sin email, no hay email', () {
    final links = contactLinksFor(
      buildRequest(phone: '612 345 678', email: null),
      chefName: 'Evelyn',
    );
    expect(links.whatsApp, isNull);
    expect(links.call, isNull);
    expect(links.email, isNull);
  });
}
