// Cuántos platos y renglones tiene el menú de cada semana y qué pasó con su
// envío a la clienta (el último que salió: cuándo y por dónde, y si lo
// confirmó o pidió cambios): para el bloque «Menú de la semana» de la ficha de
// una sesión, el editor y las semanas de una reserva en el detalle de su
// pedido. El editor los vuelve a leer después de guardar
// (week_menu_editor_controller.dart) y el envío, después de mandar
// (menu_send_controller.dart).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';
import 'package:radici/features/week_menu/data/menu_sends_repository.dart';
import 'package:radici/features/week_menu/data/session_menus_repository.dart';
import 'package:radici/features/week_menu/domain/menu_send.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

/// Sube con cada cambio de un menú o de su envío hecho desde este teléfono
/// (guardar, mandar, cargar lo guardado después de un conflicto) y con
/// «Ricarica»: lo que muestra el estado de varias semanas a la vez (los
/// «Menús para mandar» de Hoy) lo mira para volver a leerse.
final weekMenusRevisionProvider = NotifierProvider<WeekMenusRevision, int>(
  WeekMenusRevision.new,
);

class WeekMenusRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// El menú de la sesión [sessionId]: sin menú, [WeekMenuSummary] vacío. Error
/// ([MenuFailure]) si no se puede leer, enseguida y sin reintentar solo: el
/// bloque lo dice con «Reintentar».
final weekMenuSummaryProvider = FutureProvider.autoDispose
    .family<WeekMenuSummary, String>((ref, sessionId) async {
      final chefId = ref.watch(
        currentChefProvider.select((chef) => chef?.chefId),
      );
      if (chefId == null) return const WeekMenuSummary();
      final summaries = await ref
          .watch(sessionMenusRepositoryProvider)
          .fetchSummaries(chefId: chefId, sessionIds: [sessionId]);
      return summaries[sessionId] ?? const WeekMenuSummary();
    }, retry: (_, _) => null);

/// El último envío que salió del menú de la sesión [sessionId] (null si
/// nunca salió). Error ([MenuSendFailure]) si no se puede leer, sin
/// reintentar solo: quien lo muestra ofrece «Reintentar».
final latestMenuSendProvider = FutureProvider.autoDispose
    .family<MenuSendRecord?, String>((ref, sessionId) async {
      final chefId = ref.watch(
        currentChefProvider.select((chef) => chef?.chefId),
      );
      if (chefId == null) return null;
      final sends = await ref
          .watch(menuSendsRepositoryProvider)
          .fetchLatestSends(chefId: chefId, sessionIds: [sessionId]);
      return sends[sessionId];
    }, retry: (_, _) => null);

/// Una semana viva de una reserva con su menú: la [week] de [weeks], y el
/// último envío de su menú que salió ([send], null si nunca salió).
typedef BookingWeekMenu = ({
  CookingSession session,
  int week,
  int weeks,
  WeekMenuSummary summary,
  MenuSendRecord? send,
});

/// El estado del envío del menú de una semana de la reserva.
WeekMenuSendStatus bookingWeekSendStatus(BookingWeekMenu week) =>
    WeekMenuSendStatus(send: week.send, savedVersion: week.summary.version);

/// Las semanas vivas de la reserva [requestId] (las canceladas no cuentan),
/// por fecha, con cuántos platos y renglones tiene el menú de cada una y su
/// último envío: una consulta para las sesiones y, juntas, una para los
/// menús y otra para los envíos de todas. Se vuelve a leer si una sesión se
/// mueve o se cancela. Error si no se puede leer ([SessionFailure],
/// [MenuFailure] o [MenuSendFailure]), sin reintentar solo.
final bookingWeekMenusProvider = FutureProvider.autoDispose
    .family<List<BookingWeekMenu>, String>((ref, requestId) async {
      final chefId = ref.watch(
        currentChefProvider.select((chef) => chef?.chefId),
      );
      if (chefId == null) return const [];
      ref.listen(sessionChangesProvider, (_, change) {
        if (change != null) ref.invalidateSelf();
      });
      final sessions = await ref
          .watch(sessionsRepositoryProvider)
          .fetchBookingSessions(chefId: chefId, requestId: requestId);
      final live = [
        for (final session in sessions)
          if (session.isLive) session,
      ]..sort(compareSessions);
      if (live.isEmpty) return const [];
      final ids = [for (final session in live) session.id];
      // Las dos juntas. Si fallan, el error es el de la primera que falló.
      final results = await Future.wait<Object>([
        ref
            .watch(sessionMenusRepositoryProvider)
            .fetchSummaries(chefId: chefId, sessionIds: ids),
        ref
            .watch(menuSendsRepositoryProvider)
            .fetchLatestSends(chefId: chefId, sessionIds: ids),
      ]);
      final summaries = results[0] as Map<String, WeekMenuSummary>;
      final sends = results[1] as Map<String, MenuSendRecord>;
      return [
        for (final (index, session) in live.indexed)
          (
            session: session,
            week: index + 1,
            weeks: live.length,
            summary: summaries[session.id] ?? const WeekMenuSummary(),
            send: sends[session.id],
          ),
      ];
    }, retry: (_, _) => null);
