// El cartel de cada día del mes de la agenda (agendaDaySummary), con lo que
// la agenda ya leyó: sus sesiones vivas, los pedidos que lo preferían y,
// para «Semana k de N», todas las sesiones de la agenda. Sin lecturas
// propias.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/application/agenda_controller.dart';
import 'package:radici/features/requests/domain/agenda_day_summary.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';

/// El cartel de [day]: vacío si no tiene sesiones ni pedidos (también
/// mientras cargan).
final agendaDaySummaryProvider = Provider.autoDispose
    .family<AgendaDaySummary, CalendarDate>((ref, day) {
      final sessions = ref.watch(
        agendaSessionsByDateProvider.select((byDate) => byDate[day]),
      );
      final requests = ref.watch(
        agendaByDateProvider.select((byDate) => byDate[day]),
      );
      if ((sessions?.isEmpty ?? true) && (requests?.isEmpty ?? true)) {
        return AgendaDaySummary.empty;
      }
      return agendaDaySummary(
        sessions: sessions ?? const [],
        requests: requests ?? const [],
        loaded: ref.watch(sessionsControllerProvider).value ?? const [],
      );
    });
