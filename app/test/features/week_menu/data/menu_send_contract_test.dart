// El contrato entre la app y el envío del menú, leído del repo (como
// session_menu_contract_test.dart con save_session_menu): las columnas que la
// app lee de menu_sends existen y la cocina las puede leer con la RLS; las
// rutas y las claves de los cuerpos son las de chef_api.ts (una clave de más
// es un 400), y los códigos de error que la app traduce existen en la
// función. Sin este test, un cambio de un solo lado dejaría todas las suites
// en verde y fallaría recién al mandar.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/week_menu/data/menu_sends_repository.dart';
import 'package:radici/features/week_menu/domain/menu_send.dart';

import '../../../support/repo_files.dart';

String _migration() =>
    findRepoFile('supabase/migrations/20261121100000_menu_sends.sql')
        .readAsStringSync();

String _chefApi() =>
    findRepoFile('supabase/functions/_shared/chef_api.ts').readAsStringSync();

/// Los textos entre comillas de la constante [name] de chef_api.ts.
Set<String> _tsKeys(String source, String name) {
  final match = RegExp(
    'const ${RegExp.escape(name)}: readonly string\\[\\] = \\[([^\\]]*)\\]',
  ).firstMatch(source);
  if (match == null) throw StateError('No está $name en chef_api.ts');
  return {
    for (final m in RegExp('"([A-Za-z]+)"').allMatches(match.group(1)!))
      m.group(1)!,
  };
}

void main() {
  test('las columnas que lee la app existen en menu_sends y la cocina las lee con la RLS', () {
    final sql = _migration();
    final table = RegExp(r'create table public\.menu_sends \(([\s\S]*?)\n\);')
        .firstMatch(sql);
    expect(table, isNotNull);
    final columns = {
      for (final line in table!.group(1)!.split('\n'))
        if (RegExp(r'^\s+([a-z_]+)\s').firstMatch(line) case final m?)
          m.group(1)!,
    };
    final read = menuSendColumns.split(',').map((c) => c.trim()).toSet();
    expect(
      columns.containsAll(read),
      isTrue,
      reason: '${read.difference(columns)}',
    );
    expect(
      sql,
      contains('grant select on table public.menu_sends to authenticated;'),
    );
    expect(sql, contains('on public.menu_sends for select to authenticated'));
  });

  test('las rutas son las de CHEF_ROUTES', () {
    final ts = _chefApi();
    expect(ts, contains('menuPreview: "/menus/preview"'));
    expect(ts, contains('menuSend: "/menus/send"'));
    expect(SupabaseMenuSendsRepository.previewFunction, 'chef/menus/preview');
    expect(SupabaseMenuSendsRepository.sendFunction, 'chef/menus/send');
  });

  test('los cuerpos llevan exactamente las claves que acepta la función', () {
    final ts = _chefApi();
    expect(
      const MenuPreviewRequest(
        sessionId: 's',
        menuVersion: 1,
      ).toBody().keys.toSet(),
      _tsKeys(ts, 'MENU_PREVIEW_KEYS'),
    );
    expect(
      const MenuSendRequest(
        sendId: 's',
        email: true,
        whatsapp: true,
      ).toBody().keys.toSet(),
      _tsKeys(ts, 'MENU_SEND_KEYS'),
    );
  });

  test('los códigos de error que la app traduce existen en ChefErrorCode', () {
    final ts = _chefApi();
    final union = RegExp(r'export type ChefErrorCode =([\s\S]*?);')
        .firstMatch(ts)!
        .group(1)!;
    final codes = {
      for (final m in RegExp('"([A-Za-z]+)"').allMatches(union)) m.group(1)!,
    };
    const read = {
      'untranslatable',
      'notConfigured',
      'rateLimited',
      'unavailable',
      'menuChanged',
      'menuEmpty',
      'menuNotFound',
      'sessionNotFound',
      'sessionNotEditable',
      'sessionWithoutRequest',
      'sendNotFound',
      'alreadySent',
      'noEmail',
      'noPhone',
      'emailFailed',
      'emailUnavailable',
      'unauthorized',
      'forbidden',
      'server',
    };
    expect(
      codes.containsAll(read),
      isTrue,
      reason: '${read.difference(codes)}',
    );
    // emailSent: el email ya salió y el envío no quedó marcado.
    expect(ts, contains('emailSent?: boolean'));
  });

  test('el último envío de una semana es el de la base: por sent_at y, con el mismo, por id', () {
    expect(_migration(), contains('order by ms.sent_at desc, ms.id desc'));
  });
}
