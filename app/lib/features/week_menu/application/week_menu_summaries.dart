// Cuántos platos y renglones tiene el menú de cada semana: para el bloque
// «Menú de la semana» de la ficha de una sesión y para las semanas de una
// reserva en el detalle de su pedido. El editor los vuelve a leer después de
// guardar (week_menu_editor_controller.dart).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';
import 'package:radici/features/week_menu/data/session_menus_repository.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

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

/// Una semana viva de una reserva con su menú: la [week] de [weeks].
typedef BookingWeekMenu = ({
  CookingSession session,
  int week,
  int weeks,
  WeekMenuSummary summary,
});

/// Las semanas vivas de la reserva [requestId] (las canceladas no cuentan),
/// por fecha, con cuántos platos y renglones tiene el menú de cada una. Se
/// vuelve a leer si una sesión se mueve o se cancela. Error si no se puede
/// leer ([SessionFailure] o [MenuFailure]), sin reintentar solo.
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
      final summaries = await ref
          .watch(sessionMenusRepositoryProvider)
          .fetchSummaries(
            chefId: chefId,
            sessionIds: [for (final session in live) session.id],
          );
      return [
        for (final (index, session) in live.indexed)
          (
            session: session,
            week: index + 1,
            weeks: live.length,
            summary: summaries[session.id] ?? const WeekMenuSummary(),
          ),
      ];
    }, retry: (_, _) => null);
