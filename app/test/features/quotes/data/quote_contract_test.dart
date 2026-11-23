// El contrato entre la app y el presupuesto, leído del repo (como
// menu_send_contract_test.dart): las columnas que la app lee de quotes,
// sessions y menu_sends existen y la cocina las lee con la RLS (también por
// las FK con que se embeben); las rutas, las claves de los cuerpos y los
// estados de las semanas son los de chef_api.ts; los códigos de error que la
// app traduce existen en la función; y el presupuesto que la vista previa
// muestra es el bloque `quote` de la foto, con las claves de
// quote_snapshot.ts. Sin este test, un cambio de un solo lado dejaría todas
// las suites en verde y fallaría recién con Evelyn.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/quotes/data/quotes_repository.dart';
import 'package:radici/features/quotes/domain/quote_api.dart';
import 'package:radici/features/quotes/domain/request_quote.dart';
import 'package:radici/features/week_menu/domain/menu_send.dart';

import '../../../support/repo_files.dart';

String _read(String path) => findRepoFile(path).readAsStringSync();

String _quotesMigration() =>
    _read('supabase/migrations/20261121120000_quotes.sql');

String _tables() =>
    _read('supabase/migrations/20261019100000_enums_and_tables.sql');

String _chefApi() => _read('supabase/functions/_shared/chef_api.ts');

/// Las columnas de `create table public.<table> (…)` en [sql].
Set<String> _columnsOf(String sql, String table) {
  final match = RegExp('create table public\\.$table \\(([\\s\\S]*?)\\n\\);')
      .firstMatch(sql);
  if (match == null) throw StateError('No está $table');
  return {
    for (final line in match.group(1)!.split('\n'))
      if (RegExp(r'^\s+([a-z_]+)\s').firstMatch(line) case final m?)
        m.group(1)!,
  };
}

/// Los nombres de una lista de columnas («a, b, alias:tabla(…)»), sin lo
/// embebido.
Set<String> _plain(String columns) => {
  for (final part in columns.split(','))
    if (!part.contains(':') && !part.contains('(') && !part.contains(')'))
      part.trim(),
};

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
  test('las columnas de quotes que lee la app existen (las de antes y las del presupuesto)', () {
    final columns = {
      ..._columnsOf(_tables(), 'quotes'),
      for (final m in RegExp(
        r'add column ([a-z_]+)\s',
      ).allMatches(_quotesMigration()))
        m.group(1)!,
    };
    final top = requestQuoteColumns.split('weeks:').first;
    final read = _plain(top)..remove('');
    expect(
      columns.containsAll(read),
      isTrue,
      reason: '${read.difference(columns)}',
    );
  });

  test('las semanas y los envíos embebidos: sus columnas y sus FK existen', () {
    final sessions = _columnsOf(_tables(), 'sessions');
    final read = _plain(quoteSessionColumns);
    expect(
      sessions.containsAll(read),
      isTrue,
      reason: '${read.difference(sessions)}',
    );
    expect(sessions, contains('quote_id'));
    // La FK sin nombre de sessions a quotes (Postgres la llama
    // sessions_quote_id_chef_id_fkey) y la de menu_sends, con nombre.
    expect(
      _tables(),
      contains(
        'alter table public.sessions\n'
        '  add foreign key (quote_id, chef_id) references public.quotes (id, chef_id)',
      ),
    );
    expect(
      _quotesMigration(),
      contains(
        'add constraint menu_sends_quote_fk foreign key (quote_id, chef_id)',
      ),
    );
    final sends = {
      ..._columnsOf(
        _read('supabase/migrations/20261121100000_menu_sends.sql'),
        'menu_sends',
      ),
      'quote_id',
      'quote_terms',
    };
    final embedded = RegExp(r'sends:menu_sends!menu_sends_quote_fk\(([^)]*)\)')
        .firstMatch(requestQuoteColumns)!
        .group(1)!;
    final readSends = _plain(embedded);
    expect(
      sends.containsAll(readSends),
      isTrue,
      reason: '${readSends.difference(sends)}',
    );
    expect(_quotesMigration(), contains('add column quote_id    uuid'));
    expect(_quotesMigration(), contains('add column quote_terms jsonb'));
  });

  test('la cocina lee quotes, sessions y menu_sends con la RLS', () {
    final rls = _read('supabase/migrations/20261019100200_rls.sql');
    expect(rls, contains('create policy "quotes: la cocinera lee los suyos"'));
    expect(
      rls,
      contains('create policy "sessions: la cocinera lee las suyas"'),
    );
    final grants = _read('supabase/migrations/20261019130000_api_grants.sql');
    expect(grants, contains('public.quotes,'));
    final sends = _read('supabase/migrations/20261121100000_menu_sends.sql');
    expect(
      sends,
      contains('grant select on table public.menu_sends to authenticated;'),
    );
  });

  test('las rutas son las de CHEF_ROUTES', () {
    final ts = _chefApi();
    expect(ts, contains('quotes: "/quotes"'));
    expect(ts, contains('quotePrice: "/quotes/price"'));
    expect(ts, contains('quoteWithdraw: "/quotes/withdraw"'));
    expect(SupabaseQuotesRepository.createFunction, 'chef/quotes');
    expect(SupabaseQuotesRepository.priceFunction, 'chef/quotes/price');
    expect(SupabaseQuotesRepository.withdrawFunction, 'chef/quotes/withdraw');
  });

  test('los cuerpos llevan solo claves que acepta la función (una de más es un 400)', () {
    final ts = _chefApi();
    final full = const CreateQuoteRequest(
      requestId: 'r',
      dates: [],
      cookMinutes: 1,
      portions: 0,
      serviceTotalCents: 0,
    ).toBody().keys.toSet();
    expect(_tsKeys(ts, 'QUOTE_KEYS').containsAll(full), isTrue);
    expect(full, containsAll(['requestId', 'dates', 'cookMinutes', 'dryRun']));
    expect(
      quotePriceBody(quoteId: 'q', serviceTotalCents: 1).keys.toSet(),
      _tsKeys(ts, 'QUOTE_PRICE_KEYS'),
    );
    expect(
      quoteWithdrawBody('q').keys.toSet(),
      _tsKeys(ts, 'QUOTE_WITHDRAW_KEYS'),
    );
  });

  test(
    'los estados de cada fecha son los de la función (y «free» al crearlo)',
    () {
      final ts = _chefApi();
      final day = RegExp(r'export const DAY_STATUSES = \[([^\]]*)\]')
          .firstMatch(ts)!
          .group(1)!;
      expect(
        {for (final m in RegExp('"([a-z]+)"').allMatches(day)) m.group(1)!},
        {for (final status in BookingDayStatus.values) status.name},
      );
      expect(
        ts,
        contains(
          'export const QUOTE_WEEK_STATUSES = [...DAY_STATUSES, "free"]',
        ),
      );
    },
  );

  test('los códigos de error que la app traduce existen en ChefErrorCode', () {
    final ts = _chefApi();
    final union = RegExp(r'export type ChefErrorCode =([\s\S]*?);')
        .firstMatch(ts)!
        .group(1)!;
    final codes = {
      for (final m in RegExp('"([A-Za-z]+)"').allMatches(union)) m.group(1)!,
    };
    const read = {
      'quoteNotFound',
      'quoteExists',
      'quoteClosed',
      'quoteEmpty',
      'quoteChanged',
      'quoteWeekNotFirst',
      'requestNotQuotable',
      'requestNotFound',
      'requestNotNew',
      'slotTaken',
      'weekTaken',
      'conflict',
      'unauthorized',
      'forbidden',
      'unavailable',
      'server',
    };
    expect(
      codes.containsAll(read),
      isTrue,
      reason: '${read.difference(codes)}',
    );
  });

  test('el presupuesto de la vista previa es el bloque quote de la foto, con las claves de quote_snapshot.ts', () {
    expect(previewQuoteColumns, contains('quote:snapshot->quote'));
    expect(previewQuoteColumns, contains('quote_id'));
    expect(previewQuoteColumns, contains('request_id'));
    final send = _read('supabase/functions/chef/menu_send.ts');
    expect(send, contains('if (quote) snapshot.quote = quote;'));
    final snapshot = _read('supabase/functions/_shared/quote_snapshot.ts');
    for (final key in [
      'version: number',
      'totalCents: number',
      'weeks: SnapshotQuoteWeek[]',
      'holdHours: number',
      'firstStart: string',
      'serviceCents: number',
    ]) {
      expect(snapshot, contains(key));
    }
    // Los mismos topes que la app usa al leer.
    expect(snapshot, contains('QUOTE_MAX_WEEKS = $maxQuoteWeeks'));
    expect(snapshot, contains('QUOTE_MAX_CENTS = 10_000_000'));
    expect(maxQuoteCents, 10000000);
    expect(snapshot, contains('QUOTE_MAX_VERSION = 32_767'));
    expect(maxQuoteVersion, 32767);
    expect(snapshot, contains('QUOTE_MAX_HOLD_HOURS = 24 * 366'));
    expect(maxQuoteHoldHours, 24 * 366);
  });

  test('el estado se calcula como la base: cerrado, vencido por el plazo y cambiado contra el último envío', () {
    final sql = _quotesMigration();
    expect(
      sql,
      contains(
        "when q.expired_at is not null or q.hold_until <= now() then 'expired'",
      ),
    );
    expect(
      sql,
      contains("order by ms.sent_at desc, ms.id desc limit 1) then 'changed'"),
    );
    expect(
      sql,
      contains("order by s.\"date\", s.start_time, s.id), '[]'::jsonb))"),
    );
  });
}
