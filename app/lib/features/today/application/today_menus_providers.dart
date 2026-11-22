// «Menús para mandar» en Hoy (pending_menus.dart): las semanas de los
// próximos 7 días que esperan algo de Evelyn con su menú.
//
// Las semanas salen de lo que ya lee la agenda (las sesiones) y de «hoy» en
// Roma. Lo demás se lee para todas juntas, nunca una por semana: los menús
// (session_menus), el último envío de cada una (menu_sends) y las semanas
// vivas de sus reservas (para «Semana k de N»): tres consultas a la vez. Se
// vuelve a leer si cambian las semanas que entran, si se mueve o se cancela
// una sesión, y con cada cambio de un menú o de su envío desde este teléfono
// o con «Ricarica» (weekMenusRevisionProvider), y mientras tanto queda lo de
// antes; la primera lectura, cuando llega la agenda, carga sin nada (sin la
// agenda no hay semanas, y eso no quiere decir que no falte ningún menú). La
// hora («ahora», al minuto) solo descarta las que ya empezaron y resalta los
// límites: no vuelve a leer nada. Nada se loguea.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/requests/application/agenda_controller.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';
import 'package:radici/features/today/application/today_providers.dart';
import 'package:radici/features/today/domain/pending_menus.dart';
import 'package:radici/features/week_menu/application/week_menu_summaries.dart';
import 'package:radici/features/week_menu/data/menu_sends_repository.dart';
import 'package:radici/features/week_menu/data/session_menus_repository.dart';
import 'package:radici/features/week_menu/domain/menu_send.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

/// Las semanas que pueden esperar su menú (pendingMenuCandidates), de las
/// sesiones de la agenda. Vacía mientras cargan.
final todayMenuCandidatesProvider = Provider<List<CookingSession>>(
  (ref) => pendingMenuCandidates(
    ref.watch(sessionsControllerProvider).value ?? const [],
    today: ref.watch(romeTodayProvider),
  ),
);

/// Lo que se lee de las semanas de [todayMenuCandidatesProvider]: su menú, su
/// último envío que salió y su lugar en la reserva.
typedef TodayMenusData = ({
  Map<String, WeekMenuSummary> summaries,
  Map<String, MenuSendRecord> sends,
  Map<String, BookingWeekPosition> positions,
});

const TodayMenusData _noMenusData = (
  summaries: <String, WeekMenuSummary>{},
  sends: <String, MenuSendRecord>{},
  positions: <String, BookingWeekPosition>{},
);

/// El menú, el último envío y «Semana k de N» de las semanas que pueden
/// esperar su menú, en tres lecturas juntas. Error ([MenuFailure],
/// [MenuSendFailure] o [SessionFailure]) si alguna falla, sin reintentar
/// solo: la sección ofrece «Reintentar».
final todayMenusDataProvider = FutureProvider.autoDispose<TodayMenusData>((
  ref,
) async {
  // Dos cambios vuelven a leer con ref.watch (un reload: el whenData de
  // todayPendingMenusProvider descarta lo de antes y la sección espera a la
  // lectura): otra cocinera, para no mostrar lo de la anterior, y la agenda
  // leída por primera vez, porque lo de antes era de una agenda sin leer (sin
  // semanas, nada que leer) y no quiere decir «nada que mandar»: Hoy diría
  // «Nada pendiente» mientras lee.
  final chefId = ref.watch(currentChefProvider.select((chef) => chef?.chefId));
  ref.watch(sessionsControllerProvider.select((sessions) => sessions.hasValue));
  // Lo demás vuelve a leer con invalidateSelf (un refresh): mientras lee
  // queda lo de antes, sin que la sección desaparezca.
  // Las semanas que entran: si solo cambia otra cosa de ellas, no se vuelve a
  // leer (una que se mueve avisa por sessionChangesProvider).
  ref.listen(
    todayMenuCandidatesProvider.select(
      (sessions) =>
          [for (final session in sessions) '${session.id}/${session.requestId}']
              .join(','),
    ),
    (_, _) => ref.invalidateSelf(),
  );
  ref.listen(weekMenusRevisionProvider, (_, _) => ref.invalidateSelf());
  ref.listen(sessionChangesProvider, (_, change) {
    if (change != null) ref.invalidateSelf();
  });
  final candidates = ref.read(todayMenuCandidatesProvider);
  if (chefId == null || candidates.isEmpty) return _noMenusData;
  final ids = [for (final session in candidates) session.id];
  final requestIds = {for (final session in candidates) ?session.requestId}
      .toList();
  final results = await Future.wait<Object>([
    ref
        .watch(sessionMenusRepositoryProvider)
        .fetchSummaries(chefId: chefId, sessionIds: ids),
    ref
        .watch(menuSendsRepositoryProvider)
        .fetchLatestSends(chefId: chefId, sessionIds: ids),
    ref
        .watch(sessionsRepositoryProvider)
        .fetchLiveBookingWeeks(chefId: chefId, requestIds: requestIds),
  ]);
  return (
    summaries: results[0] as Map<String, WeekMenuSummary>,
    sends: results[1] as Map<String, MenuSendRecord>,
    positions: bookingWeekPositions(results[2] as List<BookingWeekRef>),
  );
}, retry: (_, _) => null);

/// Ya se leyeron los menús de todas las semanas que entran (cada una tiene su
/// fila de menús). Sin eso Hoy no dice «Nada pendiente»: al volver a entrar
/// sin reiniciar la app, la agenda trae las semanas antes de que lleguen sus
/// menús, y lo leído hasta entonces era de una agenda sin semanas.
final todayMenusSettledProvider = Provider.autoDispose<bool>((ref) {
  final candidates = ref.watch(todayMenuCandidatesProvider);
  final data = ref.watch(todayMenusDataProvider).value;
  if (data == null) return false;
  return candidates.every((session) => data.summaries.containsKey(session.id));
});

/// Las semanas de los próximos 7 días que esperan algo de Evelyn con su menú
/// (pendingMenus), por fecha. Cargando hasta la primera lectura con la agenda
/// leída; mientras se vuelve a leer (un refresh: whenData conserva lo de
/// antes), lo de antes: una semana que acaba de entrar y todavía no se leyó
/// (no tiene fila de menús) espera a la lectura, en lugar de aparecer un
/// momento como «sin menú».
final todayPendingMenusProvider =
    Provider.autoDispose<AsyncValue<List<PendingMenu>>>((ref) {
      final candidates = ref.watch(todayMenuCandidatesProvider);
      final now = ref.watch(todayNowProvider);
      return ref
          .watch(todayMenusDataProvider)
          .whenData(
            (data) => pendingMenus(
              [
                for (final session in candidates)
                  if (data.summaries.containsKey(session.id)) session,
              ],
              summaries: data.summaries,
              sends: data.sends,
              positions: data.positions,
              now: now,
            ),
          );
    });
