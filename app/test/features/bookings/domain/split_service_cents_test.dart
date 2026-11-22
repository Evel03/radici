// El reparto del precio del servicio entre las semanas, como
// private.split_cents de la base (migración 20261116150100_bookings.sql): la
// hoja del presupuesto muestra exactamente lo que va a guardar la base.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';

import '../../../support/repo_files.dart';

void main() {
  test('los centavos que sobran van a las primeras semanas', () {
    expect(splitServiceCents(50000, 3), [16667, 16667, 16666]);
    expect(splitServiceCents(42001, 4), [10501, 10500, 10500, 10500]);
    expect(splitServiceCents(56000, 4), [14000, 14000, 14000, 14000]);
    expect(splitServiceCents(7, 8), [1, 1, 1, 1, 1, 1, 1, 0]);
  });

  test('una semana se lleva todo; 0 vale (sin cargo)', () {
    expect(splitServiceCents(14050, 1), [14050]);
    expect(splitServiceCents(0, 3), [0, 0, 0]);
  });

  test('la suma es siempre el total y las partes difieren como mucho en un centavo', () {
    for (final total in [0, 1, 99, 100, 12345, 99999, 10000000]) {
      for (var weeks = 1; weeks <= 8; weeks++) {
        final split = splitServiceCents(total, weeks);
        expect(split, hasLength(weeks));
        expect(split.fold<int>(0, (sum, part) => sum + part), total);
        expect(
          split.reduce((a, b) => a > b ? a : b) -
              split.reduce((a, b) => a < b ? a : b),
          lessThanOrEqualTo(1),
        );
        // No crece: las que llevan un centavo más son las primeras.
        for (var i = 1; i < split.length; i++) {
          expect(split[i], lessThanOrEqualTo(split[i - 1]));
        }
      }
    }
  });

  test(
    'como la base, rechaza un total negativo o semanas fuera de 1 a 100',
    () {
      expect(() => splitServiceCents(-1, 2), throwsRangeError);
      expect(() => splitServiceCents(100, 0), throwsRangeError);
      expect(() => splitServiceCents(100, 101), throwsRangeError);
    },
  );

  test('es la misma cuenta que split_cents: el resto, a las primeras (i <= total % partes)', () {
    final sql = findRepoFile('supabase/migrations/20261116150100_bookings.sql')
        .readAsStringSync();
    expect(
      sql,
      contains(
        'select p_total / p_parts + case when i <= p_total % p_parts then 1 else 0 end',
      ),
    );
    // chef_create_quote y chef_update_quote reparten con la misma función.
    final quotes = findRepoFile('supabase/migrations/20261121120000_quotes.sql')
        .readAsStringSync();
    expect(quotes, contains('private.split_cents(p_service_total_cents, v_n)'));
    expect(
      quotes,
      contains(
        'private.split_cents(p_service_total_cents, cardinality(v_ids))',
      ),
    );
  });
}
