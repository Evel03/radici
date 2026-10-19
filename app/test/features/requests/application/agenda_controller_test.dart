import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mestolo/core/clock.dart';
import 'package:mestolo/core/rome_time.dart';
import 'package:mestolo/features/requests/application/agenda_controller.dart';
import 'package:mestolo/features/requests/application/chef_inbox_controller.dart';
import 'package:mestolo/features/requests/domain/chef_request.dart';

import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';

void main() {
  late ProviderContainer container;

  AgendaState state() => container.read(agendaControllerProvider);
  AgendaController controller() => container.read(agendaControllerProvider.notifier);

  setUp(() {
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        // 23:30 UTC del 31/10 ya es 1/11 en Roma (hora de invierno, UTC+1).
        clockProvider.overrideWithValue(() => DateTime.utc(2026, 10, 31, 23, 30)),
      ],
    );
  });

  test('arranca en el mes de hoy (hora de Roma) con hoy elegido', () {
    expect(state().view, AgendaView.month);
    expect(state().selectedDay, CalendarDate(2026, 11, 1));
    expect(container.read(romeTodayProvider), CalendarDate(2026, 11, 1));
  });

  test('mes anterior y siguiente', () {
    controller().next();
    expect(state().selectedDay, CalendarDate(2026, 12, 1));
    controller()
      ..previous()
      ..previous();
    expect(state().selectedDay, CalendarDate(2026, 10, 1));
  });

  test('semana anterior y siguiente; volver a hoy', () {
    controller()
      ..setView(AgendaView.week)
      ..next();
    expect(state().selectedDay, CalendarDate(2026, 11, 8));
    controller().previous();
    controller().previous();
    expect(state().selectedDay, CalendarDate(2026, 10, 25));
    controller().today();
    expect(state().selectedDay, CalendarDate(2026, 11, 1));
  });

  test('elegir un día', () {
    controller().select(CalendarDate(2026, 11, 20));
    expect(state().selectedDay, CalendarDate(2026, 11, 20));
  });

  test('pedidos por fecha y sin fecha salen de la lista de la cocinera', () {
    final day = CalendarDate(2026, 11, 3);
    final container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        chefInboxProvider.overrideWithBuild(
          (ref, notifier) async => [
            buildRequest(id: 'a', preferredDate: day),
            buildRequest(id: 'b', noDate: true),
            buildRequest(id: 'c', preferredDate: day, status: RequestStatus.rejected),
          ],
        ),
      ],
    );
    container.listen(chefInboxProvider, (_, _) {});
    return Future<void>.delayed(Duration.zero, () {
      expect(container.read(agendaByDateProvider)[day]!.map((r) => r.id), ['a']);
      expect(container.read(agendaWithoutDateProvider).map((r) => r.id), ['b']);
    });
  });
}
