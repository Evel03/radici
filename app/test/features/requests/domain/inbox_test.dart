import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/domain/inbox.dart';

import '../../../support/request_fixtures.dart';

void main() {
  final fresh = buildRequest(id: 'a', createdAt: DateTime.utc(2026, 10, 19, 10));
  final seen = buildRequest(
    id: 'b',
    seenAt: testNow,
    createdAt: DateTime.utc(2026, 10, 19, 11),
  );
  final rejected = buildRequest(
    id: 'c',
    status: RequestStatus.rejected,
    seenAt: testNow,
    createdAt: DateTime.utc(2026, 10, 18),
  );
  final quoted = buildRequest(
    id: 'd',
    status: RequestStatus.quoted,
    seenAt: testNow,
    createdAt: DateTime.utc(2026, 10, 17),
  );
  final all = [fresh, seen, rejected, quoted];

  test('cada pedido va a una pestaña', () {
    expect(inboxTabOf(fresh), InboxTab.fresh);
    expect(inboxTabOf(seen), InboxTab.seen);
    expect(inboxTabOf(rejected), InboxTab.rejected);
    expect(inboxTabOf(quoted), InboxTab.seen);
    // Rechazado sin abrir (otro dispositivo): igual va a rechazadas.
    expect(inboxTabOf(buildRequest(status: RequestStatus.rejected)), InboxTab.rejected);
  });

  test('las pestañas ordenan del más reciente al más viejo', () {
    expect(requestsInTab(all, InboxTab.fresh).map((r) => r.id), ['a']);
    expect(requestsInTab(all, InboxTab.seen).map((r) => r.id), ['b', 'd']);
    expect(requestsInTab(all, InboxTab.rejected).map((r) => r.id), ['c']);
  });

  test('el contador cuenta solo los nuevos', () {
    expect(countNew(all), 1);
    expect(countNew([fresh, buildRequest(id: 'e')]), 2);
    expect(countNew(const []), 0);
  });

  test('upsert reemplaza por id y mantiene el orden', () {
    final updated = upsertRequest(all, seen.copyWith(seenAt: null));
    expect(updated.map((r) => r.id), ['b', 'a', 'c', 'd']);
    expect(updated.first.seenAt, isNull);
    final added = upsertRequest(
      all,
      buildRequest(id: 'z', createdAt: DateTime.utc(2026, 10, 20)),
    );
    expect(added.first.id, 'z');
    expect(added, hasLength(5));
  });

  test('a igual fecha, el orden es estable por id', () {
    final same = DateTime.utc(2026, 10, 19);
    final sorted = sortNewestFirst([
      buildRequest(id: 'y', createdAt: same),
      buildRequest(id: 'x', createdAt: same),
    ]);
    expect(sorted.map((r) => r.id), ['x', 'y']);
  });
}
