import 'package:flutter_test/flutter_test.dart';
import 'package:mestolo/features/requests/domain/contact_links.dart';

void main() {
  group('WhatsApp (wa.me)', () {
    test('número sin "+" y mensaje codificado con %20', () {
      final uri = whatsAppUri(
        phoneE164: '+393331234567',
        message: 'Ciao Giulia, sono Evelyn: a presto & grazie!',
      );
      expect(
        uri.toString(),
        'https://wa.me/393331234567'
        '?text=Ciao%20Giulia%2C%20sono%20Evelyn%3A%20a%20presto%20%26%20grazie!',
      );
      // Se puede volver a leer el texto tal cual.
      expect(
        uri!.queryParameters['text'],
        'Ciao Giulia, sono Evelyn: a presto & grazie!',
      );
    });

    test('acentos, ñ y saltos de línea', () {
      final uri = whatsAppUri(phoneE164: '+34612345678', message: 'Hola Ñandú\nsí');
      expect(uri!.host, 'wa.me');
      expect(uri.path, '/34612345678');
      expect(uri.queryParameters['text'], 'Hola Ñandú\nsí');
      expect(uri.toString(), contains('%C3%91and%C3%BA%0As%C3%AD'));
    });

    test('sin teléfono normalizado no hay link', () {
      expect(whatsAppUri(phoneE164: null, message: 'x'), isNull);
      expect(whatsAppUri(phoneE164: '333 1234567', message: 'x'), isNull);
      expect(whatsAppUri(phoneE164: '+0123', message: 'x'), isNull);
    });
  });

  group('llamada', () {
    test('tel:+<dígitos>', () {
      expect(phoneCallUri('+393331234567').toString(), 'tel:+393331234567');
      expect(phoneCallUri(null), isNull);
      expect(phoneCallUri('3331234567'), isNull);
    });
  });

  group('email', () {
    test('mailto con asunto y cuerpo codificados (sin "+" por espacios)', () {
      final uri = emailUri(
        email: 'giulia@example.test',
        subject: 'La tua richiesta a Mestolo',
        body: 'Ciao Giulia,\n\n',
      );
      expect(
        uri.toString(),
        'mailto:giulia@example.test'
        '?subject=La%20tua%20richiesta%20a%20Mestolo'
        '&body=Ciao%20Giulia%2C%0A%0A',
      );
    });

    test('sin cuerpo, solo asunto', () {
      final uri = emailUri(email: ' giulia@example.test ', subject: 'Hola');
      expect(uri.toString(), 'mailto:giulia@example.test?subject=Hola');
    });

    test('sin email válido no hay link', () {
      expect(emailUri(email: null, subject: 'x'), isNull);
      expect(emailUri(email: '  ', subject: 'x'), isNull);
      expect(emailUri(email: 'giulia', subject: 'x'), isNull);
    });
  });
}
