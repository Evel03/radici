// Estado de la agenda (vista mensual o semanal, período y día elegido) y los
// pedidos agrupados por fecha preferida. "Hoy" (Europe/Rome) cambia solo a la
// medianoche, aunque la app quede abierta.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/domain/agenda.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

part 'agenda_controller.freezed.dart';

enum AgendaView { month, week }

@freezed
abstract class AgendaState with _$AgendaState {
  const factory AgendaState({
    required AgendaView view,

    /// Día elegido: define el mes o la semana que se ve y el detalle del día.
    required CalendarDate selectedDay,
  }) = _AgendaState;
}

/// Hoy en Europe/Rome según el reloj de la app. Cambia a la medianoche de
/// Roma sin reabrir la app.
final romeTodayProvider = NotifierProvider<RomeTodayController, CalendarDate>(
  RomeTodayController.new,
);

/// Cada cuánto se vuelve a mirar la fecha como mucho. Un único Timer hasta la
/// medianoche no alcanza: si el teléfono se suspende, su reloj se detiene y
/// el Timer llegaría tarde; también puede cambiar la hora del sistema.
const Duration romeTodayRecheck = Duration(minutes: 1);

class RomeTodayController extends Notifier<CalendarDate> {
  Timer? _timer;

  @override
  CalendarDate build() {
    final now = ref.watch(clockProvider);
    ref.onDispose(() => _timer?.cancel());
    final today = romeToday(now());
    _schedule(now, today);
    return today;
  }

  /// Programa la próxima revisión: a la medianoche de Roma, o antes si falta
  /// más que [romeTodayRecheck]. Nunca antes de un segundo: si el reloj del
  /// sistema retrocede justo antes de la medianoche, no se revisa en bucle.
  void _schedule(DateTime Function() now, CalendarDate today) {
    _timer?.cancel();
    final untilMidnight = romeStartOfDay(today.addDays(1)).difference(now());
    var wait = untilMidnight < romeTodayRecheck
        ? untilMidnight
        : romeTodayRecheck;
    if (wait < const Duration(seconds: 1)) wait = const Duration(seconds: 1);
    _timer = Timer(wait, () {
      final current = romeToday(now());
      if (current != state) state = current;
      _schedule(now, current);
    });
  }
}

final agendaControllerProvider =
    NotifierProvider<AgendaController, AgendaState>(AgendaController.new);

class AgendaController extends Notifier<AgendaState> {
  @override
  AgendaState build() {
    // Con "hoy" elegido, a la medianoche se pasa al día nuevo; si la cocinera
    // eligió otro día, se respeta.
    ref.listen(romeTodayProvider, (previous, today) {
      if (previous != null && state.selectedDay == previous) select(today);
    });
    return AgendaState(
      view: AgendaView.month,
      selectedDay: ref.read(romeTodayProvider),
    );
  }

  void setView(AgendaView view) => state = state.copyWith(view: view);

  void select(CalendarDate day) => state = state.copyWith(selectedDay: day);

  void today() => select(ref.read(romeTodayProvider));

  /// Mes o semana anterior.
  void previous() => _shift(-1);

  /// Mes o semana siguiente.
  void next() => _shift(1);

  void _shift(int step) => select(switch (state.view) {
    AgendaView.month => state.selectedDay.addMonths(step),
    AgendaView.week => state.selectedDay.addDays(7 * step),
  });
}

/// Pedido de traer a la vista el día elegido de la Agenda cuando se elige
/// desde afuera (un día de la tira de Hoy): en un teléfono, debajo del mes
/// queda fuera de la pantalla o detrás del botón flotante. Al tocarlo en la
/// propia Agenda ya se trae. true hasta que la Agenda lo atiende: primero
/// vuelve su lista arriba (conserva el desplazamiento) y después lo trae.
final agendaRevealProvider = NotifierProvider<AgendaReveal, bool>(
  AgendaReveal.new,
);

class AgendaReveal extends Notifier<bool> {
  @override
  bool build() => false;

  /// La próxima vez que se vea, la Agenda trae a la vista el día elegido.
  void request() => state = true;

  /// La Agenda ya lo trajo.
  void done() => state = false;
}

/// Pedidos activos por fecha preferida.
final agendaByDateProvider = Provider<Map<CalendarDate, List<ChefRequest>>>(
  (ref) => requestsByPreferredDate(ref.watch(chefInboxProvider).value ?? const []),
);

/// Pedidos activos sin fecha preferida.
final agendaWithoutDateProvider = Provider<List<ChefRequest>>(
  (ref) => requestsWithoutDate(ref.watch(chefInboxProvider).value ?? const []),
);
