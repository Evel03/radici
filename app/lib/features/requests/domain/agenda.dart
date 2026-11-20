// Cálculos de la agenda: cuadrícula del mes, días de la semana y pedidos por
// fecha preferida (los que todavía no son una reserva: las reservas se ven
// por sus sesiones, features/sessions). Dart puro. Las semanas empiezan el
// lunes (Italia).
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

/// Semanas (lunes a domingo) que cubren el mes de [month]. Incluye los días
/// del mes anterior y del siguiente que completan la primera y la última
/// semana; entre 4 y 6 semanas.
List<List<CalendarDate>> monthGrid(CalendarDate month) {
  final first = month.firstOfMonth;
  final last = first.addMonths(1).addDays(-1);
  final weeks = <List<CalendarDate>>[];
  for (
    var monday = first.startOfWeek;
    !monday.isAfter(last);
    monday = monday.addDays(7)
  ) {
    weeks.add(weekDays(monday));
  }
  return weeks;
}

/// Los 7 días (lunes a domingo) de la semana de [day].
List<CalendarDate> weekDays(CalendarDate day) {
  final monday = day.startOfWeek;
  return [for (var i = 0; i < 7; i++) monday.addDays(i)];
}

/// Orden dentro de un día: mañana, tarde, sin preferencia.
int _slotRank(PreferredSlot? slot) => switch (slot) {
  PreferredSlot.morning => 0,
  PreferredSlot.afternoon => 1,
  null => 2,
};

int _bySlotThenCreated(ChefRequest a, ChefRequest b) {
  final bySlot = _slotRank(a.preferredSlot).compareTo(_slotRank(b.preferredSlot));
  if (bySlot != 0) return bySlot;
  final byCreated = a.createdAt.compareTo(b.createdAt);
  return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
}

/// Pedidos activos con fecha preferida, agrupados por fecha y ordenados por
/// franja (mañana, tarde, indistinto) y llegada. Las reservas no: la agenda
/// muestra sus sesiones.
Map<CalendarDate, List<ChefRequest>> requestsByPreferredDate(
  Iterable<ChefRequest> requests,
) {
  final byDate = <CalendarDate, List<ChefRequest>>{};
  for (final request in requests) {
    final date = request.preferredDate;
    if (date == null || !request.isActive) continue;
    (byDate[date] ??= []).add(request);
  }
  for (final list in byDate.values) {
    list.sort(_bySlotThenCreated);
  }
  return byDate;
}

/// Pedidos activos sin fecha preferida ("senza data"), del más viejo al más
/// nuevo: los que esperan hace más tiempo, primero.
List<ChefRequest> requestsWithoutDate(Iterable<ChefRequest> requests) =>
    requests.where((r) => r.isActive && r.preferredDate == null).toList()
      ..sort((a, b) {
        final byCreated = a.createdAt.compareTo(b.createdAt);
        return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
      });
