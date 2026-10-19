// Agenda: vista, navegación, "hoy" en Roma (también al pasar la medianoche) y
// pedidos por fecha.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/application/agenda_controller.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

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

  group('medianoche (reloj falso que avanza con el tiempo del test)', () {
    // 23:59:30 del lunes 19/10/2026 en Roma (hora de verano, UTC+2).
    final beforeMidnight = DateTime.utc(2026, 10, 19, 21, 59, 30);
    late DateTime now;
    late ProviderContainer agenda;

    Future<void> elapse(WidgetTester tester, Duration duration) async {
      now = now.add(duration);
      await tester.pump(duration);
    }

    CalendarDate today() => agenda.read(romeTodayProvider);
    CalendarDate selected() => agenda.read(agendaControllerProvider).selectedDay;

    void open() {
      // Sin ProviderContainer.test: los Timer se cancelan antes de que el
      // test termine (testWidgets falla si queda alguno pendiente).
      agenda = ProviderContainer(
        retry: noRetry,
        overrides: [clockProvider.overrideWithValue(() => now)],
      )..listen(agendaControllerProvider, (_, _) {});
    }

    testWidgets('"hoy" cambia a la medianoche sin reabrir y la agenda lo sigue', (
      tester,
    ) async {
      now = beforeMidnight;
      open();
      expect(today(), CalendarDate(2026, 10, 19));
      expect(selected(), CalendarDate(2026, 10, 19));

      await elapse(tester, const Duration(seconds: 29));
      expect(today(), CalendarDate(2026, 10, 19));

      await elapse(tester, const Duration(seconds: 1));
      expect(today(), CalendarDate(2026, 10, 20));
      expect(selected(), CalendarDate(2026, 10, 20), reason: 'tenía hoy elegido');
      agenda.dispose();
    });

    testWidgets('si la cocinera eligió otro día, se respeta', (tester) async {
      now = beforeMidnight;
      open();
      agenda.read(agendaControllerProvider.notifier).select(CalendarDate(2026, 10, 25));

      await elapse(tester, const Duration(seconds: 31));
      expect(today(), CalendarDate(2026, 10, 20));
      expect(selected(), CalendarDate(2026, 10, 25));

      agenda.read(agendaControllerProvider.notifier).today();
      expect(selected(), CalendarDate(2026, 10, 20));
      agenda.dispose();
    });

    testWidgets('el día del cambio de hora (25 horas) también', (tester) async {
      // 23:59:30 del domingo 25/10 en Roma: ya es hora de invierno (UTC+1).
      now = DateTime.utc(2026, 10, 25, 22, 59, 30);
      open();
      expect(today(), CalendarDate(2026, 10, 25));
      await elapse(tester, const Duration(seconds: 30));
      expect(today(), CalendarDate(2026, 10, 26));
      agenda.dispose();
    });

    testWidgets('si el teléfono estuvo suspendido, lo nota en menos de un minuto', (
      tester,
    ) async {
      // Mediodía: la medianoche está lejos, se vuelve a mirar cada minuto.
      now = DateTime.utc(2026, 10, 19, 10);
      open();
      expect(today(), CalendarDate(2026, 10, 19));

      // Durante la suspensión el reloj del sistema avanza pero los Timer no.
      now = DateTime.utc(2026, 10, 20, 6);
      await tester.pump(romeTodayRecheck);
      expect(today(), CalendarDate(2026, 10, 20));
      agenda.dispose();
    });
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
