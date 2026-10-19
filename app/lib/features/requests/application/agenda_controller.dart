// Estado de la agenda (vista mensual o semanal, período y día elegido) y los
// pedidos agrupados por fecha preferida.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:mestolo/core/clock.dart';
import 'package:mestolo/core/rome_time.dart';
import 'package:mestolo/features/requests/application/chef_inbox_controller.dart';
import 'package:mestolo/features/requests/domain/agenda.dart';
import 'package:mestolo/features/requests/domain/chef_request.dart';

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

/// Hoy en Europe/Rome según el reloj de la app.
final romeTodayProvider = Provider<CalendarDate>(
  (ref) => romeToday(ref.watch(clockProvider)()),
);

final agendaControllerProvider =
    NotifierProvider<AgendaController, AgendaState>(AgendaController.new);

class AgendaController extends Notifier<AgendaState> {
  @override
  AgendaState build() => AgendaState(
    view: AgendaView.month,
    selectedDay: ref.read(romeTodayProvider),
  );

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

/// Pedidos activos por fecha preferida.
final agendaByDateProvider = Provider<Map<CalendarDate, List<ChefRequest>>>(
  (ref) => requestsByPreferredDate(ref.watch(chefInboxProvider).value ?? const []),
);

/// Pedidos activos sin fecha preferida.
final agendaWithoutDateProvider = Provider<List<ChefRequest>>(
  (ref) => requestsWithoutDate(ref.watch(chefInboxProvider).value ?? const []),
);
