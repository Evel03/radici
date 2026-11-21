// Repositorios falsos en memoria para tests de providers y widgets.
// Para verificar llamadas puntuales se usan mocks de mocktail en cada test.
import 'dart:async';

import 'package:mocktail/mocktail.dart';
import 'package:radici/core/app_language.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/availability/data/availability_repository.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/bookings/data/bookings_repository.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/clients/data/clients_repository.dart';
import 'package:radici/features/clients/domain/chef_client.dart';
import 'package:radici/features/recipes/data/recipes_repository.dart';
import 'package:radici/features/recipes/data/translation_repository.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_translation.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/domain/chosen_menu.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_api.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';

import 'request_fixtures.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

class MockAccountRepository extends Mock implements AccountRepository {}

class MockChefRequestsRepository extends Mock
    implements ChefRequestsRepository {}

/// Sesión controlable: [emit] simula los eventos de Supabase Auth.
class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({this.user});

  AppUser? user;
  final _changes = StreamController<AppUser?>.broadcast();

  /// Códigos que acepta [verifyEmailCode].
  String validCode = '123456';

  /// Si no es null, [sendEmailCode] falla con este error.
  AuthFailureKind? sendFailure;

  final List<String> sentTo = [];

  /// Idioma recibido en cada pedido de código.
  final List<String?> sentLocales = [];

  void emit(AppUser? next) {
    user = next;
    _changes.add(next);
  }

  @override
  AppUser? get currentUser => user;

  @override
  Stream<AppUser?> userChanges() => _changes.stream;

  @override
  Future<void> sendEmailCode(String email, {String? locale}) async {
    final failure = sendFailure;
    if (failure != null) throw AuthFailure(failure);
    sentTo.add(email);
    sentLocales.add(locale);
  }

  @override
  Future<void> verifyEmailCode({
    required String email,
    required String code,
  }) async {
    if (code != validCode) {
      throw const AuthFailure(AuthFailureKind.invalidCode);
    }
    emit(AppUser(id: 'user-$email', email: email));
  }

  @override
  Future<void> signOut() async => emit(null);
}

/// Cuenta fija (o error) para cualquier usuario. El idioma que se guarda
/// queda en la cuenta, como en el perfil del servidor.
class FakeAccountRepository implements AccountRepository {
  FakeAccountRepository(this.account);

  Account? account;
  AccountFailureKind? failure;
  int calls = 0;

  /// Si no es null, [fetchAccount] espera a que se complete (cuenta lenta).
  Completer<void>? pendingFetch;

  /// Si no es null, [updateLanguage] falla con este error.
  AccountFailureKind? updateFailure;

  /// Si no es null, [updateLanguage] espera a que se complete.
  Completer<void>? pendingUpdate;

  /// Idiomas guardados con [updateLanguage], en orden.
  final List<({String userId, AppLanguage language})> savedLanguages = [];

  @override
  Future<Account> fetchAccount(String userId) async {
    calls++;
    final pending = pendingFetch;
    if (pending != null) await pending.future;
    final failure = this.failure;
    if (failure != null) throw AccountFailure(failure);
    return account!;
  }

  @override
  Future<void> updateLanguage({
    required String userId,
    required AppLanguage language,
  }) async {
    final pending = pendingUpdate;
    if (pending != null) await pending.future;
    final failure = updateFailure;
    if (failure != null) throw AccountFailure(failure);
    savedLanguages.add((userId: userId, language: language));
    account = account?.copyWith(language: language);
  }
}

/// Pedidos en memoria, con canal de tiempo real controlable.
class FakeChefRequestsRepository implements ChefRequestsRepository {
  FakeChefRequestsRepository(Iterable<ChefRequest> requests)
    : requests = {for (final r in requests) r.id: r};

  /// Pedidos "en el servidor", por id.
  final Map<String, ChefRequest> requests;

  /// Instante que devuelve [markSeen].
  DateTime seenAt = DateTime.utc(2026, 10, 19, 12);

  bool failFetch = false;
  bool failMarkSeen = false;
  bool failReject = false;
  bool failUndoReject = false;
  bool failMarkClient = false;

  /// Si no es null, la lectura de la lista espera a que se complete (y
  /// después falla si [failFetch]).
  Completer<void>? pendingFetch;
  int fetchCalls = 0;
  final List<String> markedSeen = [];
  final List<String> rejected = [];
  final List<String> undoneRejects = [];

  /// Fichas (client_id) marcadas como clientes.
  final List<String> markedClients = [];

  /// Nombres de los platos (recipes) "en el servidor", por id: los que lee
  /// [fetchMenuDishes]. Un id que no está es un plato borrado.
  final Map<String, MenuDish> dishes = {};
  bool failDishes = false;

  /// Si no es null, [fetchMenuDishes] espera a que se complete.
  Completer<void>? pendingDishes;

  /// Los ids de cada [fetchMenuDishes], en orden.
  final List<List<String>> dishCalls = [];

  /// Como Supabase: cada lectura ([fetchRequests], [fetchRequest]) devuelve
  /// pedidos nuevos, con listas nuevas (iguales en contenido, no las mismas).
  bool freshCopies = false;

  ChefRequest _read(ChefRequest request) => freshCopies
      ? request.copyWith(wishes: List.of(request.wishes))
      : request;

  final _realtime = StreamController<RequestsRealtimeEvent>.broadcast();
  int realtimeListeners = 0;

  /// Simula un INSERT en la base y su aviso por Realtime.
  void insertFromRealtime(ChefRequest request) {
    requests[request.id] = request;
    _realtime.add(RequestInserted(request.id));
  }

  /// Agrega un pedido en la base sin aviso (se perdió mientras no había red).
  void insertSilently(ChefRequest request) => requests[request.id] = request;

  void emitRealtime(RequestsRealtimeEvent event) => _realtime.add(event);

  @override
  Future<List<ChefRequest>> fetchRequests({required String chefId}) async {
    fetchCalls++;
    final pending = pendingFetch;
    if (pending != null) await pending.future;
    if (failFetch) throw const RequestsFailure(RequestsFailureKind.unavailable);
    final list = [
      for (final r in requests.values)
        if (r.chefId == chefId) _read(r),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  @override
  Future<ChefRequest?> fetchRequest(String id) async {
    if (failFetch) throw const RequestsFailure(RequestsFailureKind.unavailable);
    final request = requests[id];
    return request == null ? null : _read(request);
  }

  @override
  Future<DateTime> markSeen(String id) async {
    if (failMarkSeen) {
      throw const RequestsFailure(RequestsFailureKind.unavailable);
    }
    markedSeen.add(id);
    final request = requests[id]!;
    final value = request.seenAt ?? seenAt;
    requests[id] = request.copyWith(seenAt: value);
    return value;
  }

  @override
  Future<void> reject(String id) async {
    if (failReject) throw const RequestsFailure(RequestsFailureKind.unavailable);
    final request = requests[id]!;
    if (request.status != RequestStatus.newRequest) {
      throw const RequestsFailure(RequestsFailureKind.conflict);
    }
    rejected.add(id);
    requests[id] = request.copyWith(status: RequestStatus.rejected);
  }

  @override
  Future<void> undoReject(String id) async {
    if (failUndoReject) {
      throw const RequestsFailure(RequestsFailureKind.unavailable);
    }
    final request = requests[id]!;
    if (request.status != RequestStatus.rejected) {
      throw const RequestsFailure(RequestsFailureKind.conflict);
    }
    undoneRejects.add(id);
    requests[id] = request.copyWith(status: RequestStatus.newRequest);
  }

  @override
  Future<void> markClientAsCustomer(String clientId) async {
    if (failMarkClient) {
      throw const RequestsFailure(RequestsFailureKind.unavailable);
    }
    final ofClient = requests.values.where((r) => r.clientId == clientId);
    if (ofClient.isEmpty ||
        ofClient.any((r) => r.client.status != ClientStatus.prospect)) {
      throw const RequestsFailure(RequestsFailureKind.conflict);
    }
    markedClients.add(clientId);
    for (final request in ofClient.toList()) {
      requests[request.id] = request.copyWith(
        client: request.client.copyWith(status: ClientStatus.trial),
      );
    }
  }

  @override
  Future<List<MenuDish>> fetchMenuDishes(List<String> ids) async {
    dishCalls.add(List.of(ids));
    final fail = failDishes;
    final found = [for (final id in ids) ?dishes[id]];
    final pending = pendingDishes;
    if (pending != null) await pending.future;
    if (fail) throw const RequestsFailure(RequestsFailureKind.unavailable);
    return found;
  }

  @override
  Stream<RequestsRealtimeEvent> watchNewRequests({required String chefId}) {
    late final StreamSubscription<RequestsRealtimeEvent> source;
    late final StreamController<RequestsRealtimeEvent> controller;
    controller = StreamController<RequestsRealtimeEvent>(
      onListen: () {
        realtimeListeners++;
        source = _realtime.stream.listen(controller.add);
      },
      onCancel: () async {
        realtimeListeners--;
        await source.cancel();
        await controller.close();
      },
    );
    return controller.stream;
  }
}

/// Fichas de la cocinera "en el servidor", en memoria (el directorio de
/// «Nuova prenotazione»). La lectura toma su foto en cuanto llega:
/// [pendingFetch] demora solo la respuesta.
class FakeClientsRepository implements ClientsRepository {
  FakeClientsRepository([Iterable<ChefClient> clients = const []])
    : clients = [...clients];

  final List<ChefClient> clients;

  /// Si no es null, la lectura falla con esto.
  ClientsFailure? fetchFailure;

  /// Si no es null, la respuesta espera a que se complete.
  Completer<void>? pendingFetch;

  int fetchCalls = 0;

  @override
  Future<List<ChefClient>> fetchClients({required String chefId}) async {
    fetchCalls++;
    final snapshot = List.of(clients);
    final pending = pendingFetch;
    if (pending != null) await pending.future;
    final failure = fetchFailure;
    if (failure != null) throw failure;
    return snapshot;
  }
}

/// Lunes a viernes de 9 a 15: el horario de Evelyn (decisión del 15/11/2026).
List<AvailabilityRule> weekdayRules() => [
  for (var weekday = 1; weekday <= 5; weekday++)
    AvailabilityRule(
      weekday: weekday,
      start: const Duration(hours: 9),
      end: const Duration(hours: 15),
    ),
];

/// Horario y días bloqueados "en el servidor", en memoria. Como la base,
/// bloquear un día que ya está bloqueado no lo toca ni lo devuelve, y cada
/// pedido se aplica (o la lectura toma su foto) en cuanto llega: los
/// `pending…` demoran solo la respuesta, como una red lenta.
class FakeAvailabilityRepository implements AvailabilityRepository {
  FakeAvailabilityRepository({
    List<AvailabilityRule>? rules,
    Iterable<BlockedDay> blocked = const [],
  }) : rules = rules ?? weekdayRules(),
       blocked = {for (final day in blocked) day.date: day};

  List<AvailabilityRule> rules;

  /// Bloqueos guardados, por fecha (siempre con id).
  final Map<CalendarDate, BlockedDay> blocked;

  bool failFetch = false;
  bool failBlock = false;
  bool failUnblock = false;
  bool failNote = false;

  /// Si no es null, la respuesta de [fetch], [block] o [unblock] espera a que
  /// se complete (para ver el estado mientras carga o mientras se guarda, o
  /// una respuesta que llega después de otra).
  Completer<void>? pendingFetch;
  Completer<void>? pendingBlock;
  Completer<void>? pendingUnblock;

  int fetchCalls = 0;
  final List<CalendarDate> fetchedFrom = [];
  final List<List<DayToBlock>> blockCalls = [];
  final List<List<String>> unblockCalls = [];
  final List<({String id, String? note})> noteCalls = [];
  int _nextId = 1;

  static const _unavailable = AvailabilityFailure(
    AvailabilityFailureKind.unavailable,
  );

  @override
  Future<AvailabilitySnapshot> fetch({
    required String chefId,
    required CalendarDate from,
  }) async {
    fetchCalls++;
    fetchedFrom.add(from);
    final fail = failFetch;
    final snapshot = AvailabilitySnapshot(
      rules: List.of(rules),
      blocked: {
        for (final entry in blocked.entries)
          if (!entry.key.isBefore(from)) entry.key: entry.value,
      },
    );
    final pending = pendingFetch;
    if (pending != null) await pending.future;
    if (fail) throw _unavailable;
    return snapshot;
  }

  @override
  Future<List<BlockedDay>> block({
    required String chefId,
    required List<DayToBlock> days,
  }) async {
    blockCalls.add(List.of(days));
    final fail = failBlock;
    final created = <BlockedDay>[];
    if (!fail) {
      for (final day in days) {
        if (blocked.containsKey(day.date)) continue;
        final row = BlockedDay(
          id: 'block-${_nextId++}',
          date: day.date,
          note: day.note,
        );
        blocked[day.date] = row;
        created.add(row);
      }
    }
    final pending = pendingBlock;
    if (pending != null) await pending.future;
    if (fail) throw _unavailable;
    return created;
  }

  @override
  Future<void> unblock({
    required String chefId,
    required List<String> ids,
  }) async {
    unblockCalls.add(List.of(ids));
    final fail = failUnblock;
    if (!fail) blocked.removeWhere((_, day) => ids.contains(day.id));
    final pending = pendingUnblock;
    if (pending != null) await pending.future;
    if (fail) throw _unavailable;
  }

  @override
  Future<void> updateNote({
    required String chefId,
    required String id,
    String? note,
  }) async {
    noteCalls.add((id: id, note: note));
    if (failNote) throw _unavailable;
    final entry = blocked.entries.where((e) => e.value.id == id).firstOrNull;
    if (entry == null) {
      throw const AvailabilityFailure(AvailabilityFailureKind.notFound);
    }
    blocked[entry.key] = entry.value.copyWith(note: note);
  }
}

/// La Edge Function `chef` en memoria (POST chef/bookings). El dryRun devuelve
/// el estado de cada fecha ([statuses]; ok por defecto, closed en
/// [closedDays]) con la llegada sugerida [suggestedStart] (ninguna en un día
/// sin horario), evaluada con la hora pedida o, sin hora, con la sugerida. La
/// confirmación devuelve las sesiones creadas y, si tiene [requests], pasa el
/// pedido a `accepted` como la base. Como la base, con un pedido que ya no está
/// `new` en [requests] el dryRun y la confirmación dan requestNotNew, salvo el
/// reintento de una reserva guardada aquí con las mismas fechas y hora, que
/// devuelve lo guardado con `duplicate` (contrato chef-api §4). A mano
/// (clientId o newClient), la confirmación crea el pedido `manual-request-<n>`
/// (y, con newClient, la ficha `new-client-1`) y la guarda por su requestKey:
/// la misma clave devuelve lo guardado con `duplicate`. Con [requests] agrega
/// el pedido `accepted`, de la app y visto, con los datos de la ficha (de
/// [clients] o de newClient), y una ficha prospecto pasa a trial. Con
/// [sessions], una confirmación a mano agrega sus sesiones `confirmed` (con
/// la ficha de otra sesión suya, si hay). Las fallas y las respuestas lentas
/// se controlan por campo.
class FakeBookingsRepository implements BookingsRepository {
  FakeBookingsRepository({this.requests, this.clients, this.sessions});

  /// Los pedidos "en el servidor" que actualiza una confirmación.
  final FakeChefRequestsRepository? requests;

  /// Las fichas "en el servidor" de una reserva a mano.
  final FakeClientsRepository? clients;

  /// Las sesiones "en el servidor" que crea una reserva a mano.
  final FakeSessionsRepository? sessions;

  /// Reservas guardadas, por pedido.
  final Map<String, BookingResult> saved = {};

  /// Reservas a mano guardadas, por requestKey.
  final Map<String, BookingResult> savedByKey = {};

  /// El id de la ficha que crea una reserva con newClient.
  static const String newClientId = 'new-client-1';

  int _manualRequests = 0;

  /// La próxima confirmación se guarda pero su respuesta se pierde
  /// (unavailable): la base la tiene y la app no lo sabe.
  bool loseNextConfirmResponse = false;

  /// Con true, cada dryRun espera su propio Completer de [heldChecks], para
  /// completar las respuestas en otro orden que los pedidos.
  bool holdEachCheck = false;
  final List<Completer<void>> heldChecks = [];

  final List<BookingRequest> calls = [];

  List<BookingRequest> get dryRuns => [
    for (final call in calls)
      if (call.dryRun) call,
  ];

  List<BookingRequest> get confirmations => [
    for (final call in calls)
      if (!call.dryRun) call,
  ];

  final Map<CalendarDate, BookingDayStatus> statuses = {};
  final Set<CalendarDate> closedDays = {};
  ClockTime suggestedStart = const ClockTime.hm(10, 0);

  /// Si no son null, el dryRun o la confirmación fallan con esto.
  BookingFailure? checksFailure;
  BookingFailure? confirmFailure;

  /// Si no son null, la respuesta espera a que se completen.
  Completer<void>? pendingChecks;
  Completer<void>? pendingConfirm;

  /// La confirmación responde como un reintento de una ya guardada.
  bool duplicate = false;

  @override
  Future<BookingResult> createBooking(BookingRequest request) async {
    calls.add(request);
    if (request.dryRun && holdEachCheck) {
      final gate = Completer<void>();
      heldChecks.add(gate);
      await gate.future;
    }
    final pending = request.dryRun ? pendingChecks : pendingConfirm;
    if (pending != null) await pending.future;
    final failure = request.dryRun ? checksFailure : confirmFailure;
    if (failure != null) throw failure;
    if (request.requestId == null) return _manual(request);
    final current = requests?.requests[request.requestId];
    if (current != null && current.status != RequestStatus.newRequest) {
      final booked = saved[request.requestId];
      if (!request.dryRun &&
          booked != null &&
          _sameDatesAndStart(booked, request)) {
        return booked.copyWith(duplicate: true);
      }
      // Los demás estados se escriben igual que en la base.
      throw BookingFailure(
        BookingFailureKind.requestNotNew,
        requestStatus: current.status.name,
      );
    }
    final result = BookingResult(
      dryRun: request.dryRun,
      duplicate: !request.dryRun && duplicate,
      requestId: request.requestId,
      clientId: testClientId,
      weeks: [
        for (final (i, date) in request.dates.indexed)
          _week(request, i, date),
      ],
    );
    if (!request.dryRun) {
      _accept(request);
      if (request.requestId case final requestId?) {
        saved[requestId] = result.copyWith(duplicate: false);
      }
      if (loseNextConfirmResponse) {
        loseNextConfirmResponse = false;
        throw const BookingFailure(BookingFailureKind.unavailable);
      }
    }
    return result;
  }

  /// Una reserva a mano: el dryRun sin pedido (y, con newClient, sin ficha);
  /// la confirmación crea el pedido y se guarda por su clave.
  BookingResult _manual(BookingRequest request) {
    final key = request.requestKey;
    if (!request.dryRun && key != null) {
      final booked = savedByKey[key];
      if (booked != null) return booked.copyWith(duplicate: true);
    }
    final result = BookingResult(
      dryRun: request.dryRun,
      duplicate: !request.dryRun && duplicate,
      requestId: request.dryRun ? null : 'manual-request-${++_manualRequests}',
      clientId: request.clientId ?? (request.dryRun ? null : newClientId),
      weeks: [
        for (final (i, date) in request.dates.indexed)
          _week(request, i, date),
      ],
    );
    if (request.dryRun) return result;
    if (key != null) savedByKey[key] = result.copyWith(duplicate: false);
    _createManual(request, result);
    _createSessions(request, result);
    if (loseNextConfirmResponse) {
      loseNextConfirmResponse = false;
      throw const BookingFailure(BookingFailureKind.unavailable);
    }
    return result;
  }

  void _createManual(BookingRequest request, BookingResult result) {
    final clientId = result.clientId!;
    final directory = clients;
    final existing = directory?.clients
        .where((client) => client.id == clientId)
        .firstOrNull;
    final newClient = request.newClient;
    if (directory != null && existing != null && existing.isProspect) {
      directory.clients[directory.clients.indexOf(existing)] = existing
          .copyWith(status: ClientStatus.trial);
    }
    if (directory != null && newClient != null) {
      directory.clients.add(
        ChefClient(
          id: clientId,
          displayName: newClient.name,
          contactPhone: newClient.phone,
          zone: newClient.zone,
          adults: request.household!.adults,
          kids: request.household!.kids,
          status: ClientStatus.trial,
        ),
      );
    }
    final server = requests;
    if (server == null) return;
    for (final other in server.requests.values.toList()) {
      if (other.clientId == clientId &&
          other.client.status == ClientStatus.prospect) {
        server.requests[other.id] = other.copyWith(
          client: other.client.copyWith(status: ClientStatus.trial),
        );
      }
    }
    final household = request.household!;
    server.requests[result.requestId!] = ChefRequest(
      id: result.requestId!,
      chefId: testChefId,
      clientId: clientId,
      type: RequestType.week,
      status: RequestStatus.accepted,
      adults: household.adults,
      kids: household.kids,
      days: household.days,
      meals: household.canonicalMeals,
      weeks: request.dates.length,
      locale: request.locale!,
      source: RequestSource.app,
      seenAt: DateTime.utc(2026, 10, 19, 12),
      createdAt: DateTime.utc(2026, 10, 19, 12, 0, 1),
      client: RequestClient(
        displayName: newClient?.name ?? existing?.displayName ?? '',
        contactPhone: newClient?.phone ?? existing?.contactPhone,
        zone: newClient?.zone ?? existing?.zone,
        // Como la base: una ficha nueva nace trial y un prospecto pasa a
        // trial; las demás no cambian.
        status: newClient != null || existing == null || existing.isProspect
            ? ClientStatus.trial
            : existing.status,
      ),
    );
  }

  /// Con [sessions], las sesiones `confirmed` de una reserva a mano, una por
  /// semana, con el pedido creado y la ficha de otra sesión de la misma
  /// clienta (si no hay, una con su nombre).
  void _createSessions(BookingRequest request, BookingResult result) {
    final repository = sessions;
    if (repository == null) return;
    final requestId = result.requestId!;
    final clientId = result.clientId!;
    final household = request.household!;
    final created =
        requests?.requests[requestId] ??
        ChefRequest(
          id: requestId,
          chefId: testChefId,
          clientId: clientId,
          type: RequestType.week,
          status: RequestStatus.accepted,
          adults: household.adults,
          kids: household.kids,
          days: household.days,
          meals: household.canonicalMeals,
          weeks: request.dates.length,
          locale: request.locale!,
          source: RequestSource.app,
          seenAt: DateTime.utc(2026, 10, 19, 12),
          createdAt: DateTime.utc(2026, 10, 19, 12, 0, 1),
        );
    final client =
        repository.sessions.values
            .where((s) => s.clientId == clientId)
            .firstOrNull
            ?.client ??
        SessionClient(
          displayName: request.newClient?.name ?? created.client.displayName,
          contactPhone: request.newClient?.phone,
          zone: request.newClient?.zone,
          status: ClientStatus.trial,
        );
    for (final (i, week) in result.weeks.indexed) {
      final id = '$requestId-${i + 1}';
      repository.sessions[id] = CookingSession(
        id: id,
        chefId: testChefId,
        clientId: clientId,
        requestId: requestId,
        date: week.date,
        start: week.start ?? request.start ?? const ClockTime.hm(9, 0),
        cookMinutes: request.cookMinutes,
        // Sin compra: shop_minutes es 0 desde el 19/11/2026.
        shopMinutes: 0,
        gapMinutes: 30,
        portions: request.portions ?? 0,
        status: SessionStatus.confirmed,
        serviceCents: week.serviceCents,
        client: client,
        request: created,
      );
    }
  }

  static bool _sameDatesAndStart(BookingResult booked, BookingRequest request) =>
      booked.weeks.length == request.dates.length &&
      [
        for (final (i, week) in booked.weeks.indexed)
          week.date == request.dates[i] && week.start == request.start,
      ].every((same) => same);

  BookingWeek _week(BookingRequest request, int index, CalendarDate date) {
    final closed = closedDays.contains(date);
    final total = request.serviceTotalCents ?? 0;
    final weeks = request.dates.length;
    return BookingWeek(
      date: date,
      start: request.start ?? (closed ? null : suggestedStart),
      cookMinutes: request.cookMinutes,
      status:
          statuses[date] ??
          (closed ? BookingDayStatus.closed : BookingDayStatus.ok),
      suggestedStart: closed ? null : suggestedStart,
      // Como split_cents: los centavos que sobran, a las primeras.
      serviceCents: total ~/ weeks + (index < total % weeks ? 1 : 0),
      sessionId: request.dryRun ? null : 'session-${index + 1}',
    );
  }

  void _accept(BookingRequest request) {
    final server = requests;
    final requestId = request.requestId;
    final current = server?.requests[requestId];
    if (server == null || requestId == null || current == null) return;
    server.requests[requestId] = current.copyWith(
      status: RequestStatus.accepted,
      weeks: request.dates.length,
      seenAt: current.seenAt ?? DateTime.utc(2026, 10, 19, 12),
      client: current.client.status == ClientStatus.prospect
          ? current.client.copyWith(status: ClientStatus.trial)
          : current.client,
    );
  }
}

/// Las sesiones "en el servidor", en memoria: la lectura (con la RLS, solo
/// las de la cocinera) y la Edge Function chef para mover y cancelar, con las
/// mismas reglas que la base (contrato chef-api §5 y §6): solo se mueve una
/// held o confirmed; una semana con otra sesión viva de la misma reserva da
/// weekTaken; una fecha marcada busy en [statuses] da slotTaken; cancelar es
/// todo o nada (cooked o paid dan invalidTransition; las de [paid], sin
/// permiso, hasPayments). La dirección de la ficha se guarda en todas sus
/// sesiones (una ficha que no es de la cocinera da notFound, como la RLS).
/// Las fallas y las respuestas lentas se controlan por campo; los `pending…`
/// demoran solo la respuesta.
class FakeSessionsRepository implements SessionsRepository {
  FakeSessionsRepository([Iterable<CookingSession> sessions = const []])
    : sessions = {for (final session in sessions) session.id: session};

  /// Sesiones guardadas, por id.
  final Map<String, CookingSession> sessions;

  /// Estado de cada fecha en el chequeo (ok por defecto).
  final Map<CalendarDate, BookingDayStatus> statuses = {};

  /// La primera llegada de cualquier día (null: día sin horario).
  ClockTime? suggestedStart = const ClockTime.hm(10, 0);

  /// Sesiones con un cobro.
  final Set<String> paid = {};

  /// Si no son null, la operación falla con esto.
  SessionFailure? fetchFailure;
  SessionFailure? checkFailure;
  SessionFailure? moveFailure;
  SessionFailure? cancelFailure;
  SessionFailure? addressFailure;

  /// Si no son null, la respuesta espera a que se completen.
  Completer<void>? pendingFetch;
  Completer<void>? pendingCheck;
  Completer<void>? pendingMove;
  Completer<void>? pendingCancel;
  Completer<void>? pendingAddress;

  /// Solo la lectura de la agenda (fetchSessions) espera a que se complete:
  /// la ficha de una sesión se lee igual.
  Completer<void>? pendingAgendaFetch;

  int fetchCalls = 0;
  final List<CalendarDate> fetchedFrom = [];
  final List<String> bookingFetches = [];
  final List<String> sessionFetches = [];
  final List<MoveSessionRequest> moveCalls = [];
  final List<CancelSessionsRequest> cancelCalls = [];

  List<MoveSessionRequest> get checks => [
    for (final call in moveCalls)
      if (call.dryRun) call,
  ];

  List<MoveSessionRequest> get moves => [
    for (final call in moveCalls)
      if (!call.dryRun) call,
  ];

  List<CookingSession> _sorted(Iterable<CookingSession> list) =>
      list.toList()..sort(compareSessions);

  Future<void> _read() async {
    final pending = pendingFetch;
    if (pending != null) await pending.future;
    final failure = fetchFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<List<CookingSession>> fetchSessions({
    required String chefId,
    required CalendarDate from,
  }) async {
    fetchCalls++;
    fetchedFrom.add(from);
    final agenda = pendingAgendaFetch;
    if (agenda != null) await agenda.future;
    final found = _sorted(
      sessions.values.where(
        (s) => s.chefId == chefId && !s.date.isBefore(from),
      ),
    );
    await _read();
    return found;
  }

  @override
  Future<CookingSession?> fetchSession({
    required String chefId,
    required String id,
  }) async {
    sessionFetches.add(id);
    final found = sessions[id];
    await _read();
    return found?.chefId == chefId ? found : null;
  }

  @override
  Future<List<CookingSession>> fetchBookingSessions({
    required String chefId,
    required String requestId,
  }) async {
    bookingFetches.add(requestId);
    final found = _sorted(
      sessions.values.where(
        (s) => s.chefId == chefId && s.requestId == requestId,
      ),
    );
    await _read();
    return found;
  }

  @override
  Future<MoveSessionResult> moveSession(MoveSessionRequest request) async {
    moveCalls.add(request);
    final pending = request.dryRun ? pendingCheck : pendingMove;
    final failure = request.dryRun ? checkFailure : moveFailure;
    final session = sessions[request.sessionId];
    MoveSessionResult? result;
    SessionFailure? refused;
    if (failure != null) {
      refused = failure;
    } else if (session == null) {
      refused = const SessionFailure(SessionFailureKind.notFound);
    } else if (!session.canMove) {
      refused = SessionFailure(
        SessionFailureKind.notMovable,
        status: session.status,
      );
    } else {
      final weekTaken =
          session.requestId != null &&
          sessions.values.any(
            (other) =>
                other.id != session.id &&
                other.requestId == session.requestId &&
                other.isLive &&
                other.weekStart == request.date.startOfWeek,
          );
      final status = statuses[request.date] ?? BookingDayStatus.ok;
      result = MoveSessionResult(
        dryRun: request.dryRun,
        sessionId: session.id,
        requestId: session.requestId,
        date: request.date,
        start: request.start ?? session.start,
        cookMinutes: request.cookMinutes ?? session.cookMinutes,
        status: status,
        suggestedStart: suggestedStart,
        weekTaken: weekTaken,
      );
      if (!request.dryRun) {
        if (status == BookingDayStatus.busy) {
          refused = SessionFailure(
            SessionFailureKind.slotTaken,
            date: request.date,
          );
        } else if (weekTaken) {
          refused = SessionFailure(
            SessionFailureKind.weekTaken,
            date: request.date,
          );
        } else {
          sessions[session.id] = session.copyWith(
            date: result.date,
            start: result.start,
            cookMinutes: result.cookMinutes,
          );
        }
      }
    }
    if (pending != null) await pending.future;
    if (refused != null) throw refused;
    return result!;
  }

  @override
  Future<CancelSessionsResult> cancelSessions(
    CancelSessionsRequest request,
  ) async {
    cancelCalls.add(request);
    final ids = {...request.sessionIds};
    final found = [for (final id in ids) ?sessions[id]];
    SessionFailure? refused = cancelFailure;
    CancelSessionsResult? result;
    if (refused == null && found.length != ids.length) {
      refused = const SessionFailure(SessionFailureKind.notFound);
    }
    final blocked = found.where(
      (s) => s.status == SessionStatus.cooked || s.status == SessionStatus.paid,
    );
    if (refused == null && blocked.isNotEmpty) {
      refused = SessionFailure(
        SessionFailureKind.invalidTransition,
        sessionIds: [blocked.first.id],
      );
    }
    final withPayments = [
      for (final s in found)
        if (paid.contains(s.id) && s.canCancel) s.id,
    ];
    if (refused == null &&
        withPayments.isNotEmpty &&
        !request.allowWithPayments) {
      refused = SessionFailure(
        SessionFailureKind.hasPayments,
        sessionIds: withPayments,
      );
    }
    if (refused == null) {
      final already = [
        for (final s in found)
          if (!s.isLive) s.id,
      ];
      final cancelled = [
        for (final s in found)
          if (s.canCancel) s.id,
      ];
      for (final id in cancelled) {
        sessions[id] = sessions[id]!.copyWith(
          status: SessionStatus.cancelled,
          cancelReason: request.reason.code,
          cancelledAt: DateTime.utc(2026, 10, 19, 12),
        );
      }
      result = CancelSessionsResult(
        cancelled: cancelled,
        alreadyCancelled: already,
        withPayments: [
          for (final s in found)
            if (paid.contains(s.id)) s.id,
        ],
        hadPayments: withPayments.isNotEmpty,
      );
    }
    final pending = pendingCancel;
    if (pending != null) await pending.future;
    if (refused != null) throw refused;
    return result!;
  }

  /// Direcciones guardadas, en orden: (ficha, dirección).
  final List<(String, String)> addressUpdates = [];

  @override
  Future<void> updateClientAddress({
    required String chefId,
    required String clientId,
    required String address,
  }) async {
    addressUpdates.add((clientId, address));
    final pending = pendingAddress;
    if (pending != null) await pending.future;
    final failure = addressFailure;
    if (failure != null) throw failure;
    final mine = [
      for (final session in sessions.values)
        if (session.clientId == clientId && session.chefId == chefId) session,
    ];
    // Como la RLS: una ficha que no es suya no cambia ninguna fila.
    if (mine.isEmpty) {
      throw const SessionFailure(SessionFailureKind.notFound);
    }
    for (final session in mine) {
      sessions[session.id] = session.copyWith(
        client: session.client.copyWith(address: address),
      );
    }
  }
}

/// Catálogo "en el servidor", en memoria. Como save_recipe, guardar crea o
/// reemplaza el plato entero y nunca cambia si está activo. Cada pedido se
/// aplica (o la lectura toma su foto) en cuanto llega: los `pending…` demoran
/// solo la respuesta, como una red lenta.
class FakeRecipesRepository implements RecipesRepository {
  FakeRecipesRepository([Iterable<Recipe> recipes = const []])
    : recipes = {for (final recipe in recipes) recipe.id: recipe};

  /// Platos guardados, por id.
  final Map<String, Recipe> recipes;

  bool failFetch = false;

  /// Si no es null, [save] falla con este error (y no guarda nada).
  RecipesFailureKind? saveFailure;
  bool failSetActive = false;

  Completer<void>? pendingFetch;
  Completer<void>? pendingSave;
  Completer<void>? pendingSetActive;

  int fetchCalls = 0;

  /// Cada plato recibido por [save], en orden (también los que fallaron).
  final List<Recipe> saveCalls = [];
  final List<({String id, bool active})> setActiveCalls = [];

  @override
  Future<List<Recipe>> fetchCatalog({required String chefId}) async {
    fetchCalls++;
    final fail = failFetch;
    final snapshot = recipes.values.toList();
    final pending = pendingFetch;
    if (pending != null) await pending.future;
    if (fail) throw const RecipesFailure(RecipesFailureKind.unavailable);
    return snapshot;
  }

  @override
  Future<void> save(Recipe recipe) async {
    saveCalls.add(recipe);
    final failure = saveFailure;
    if (failure == null) {
      final current = recipes[recipe.id];
      recipes[recipe.id] = recipe.copyWith(active: current?.active ?? true);
    }
    final pending = pendingSave;
    if (pending != null) await pending.future;
    if (failure != null) throw RecipesFailure(failure);
  }

  @override
  Future<void> setActive({
    required String chefId,
    required String id,
    required bool active,
  }) async {
    setActiveCalls.add((id: id, active: active));
    final fail = failSetActive;
    final current = recipes[id];
    if (!fail && current != null) recipes[id] = current.copyWith(active: active);
    final pending = pendingSetActive;
    if (pending != null) await pending.future;
    if (fail) throw const RecipesFailure(RecipesFailureKind.unavailable);
    if (current == null) throw const RecipesFailure(RecipesFailureKind.notFound);
  }
}

/// Guarda los links abiertos en lugar de abrirlos.
class FakeLinkLauncher implements LinkLauncher {
  final List<Uri> launched = [];

  /// Resultado de [launch] (false simula que no hay app para abrirlo).
  bool result = true;

  @override
  Future<bool> launch(Uri uri) async {
    launched.add(uri);
    return result;
  }
}

/// Lo que devuelve [FakeTranslationRepository] (como TRANSLATE_TRANSPORT=fake
/// en la función): «[it] …» y «[en] …», cortados a los largos de la base
/// (por caracteres), la descripción solo si se mandó.
RecipeTranslation fakeTranslation(SpanishText spanish) {
  String cut(String text, int max) => String.fromCharCodes(text.runes.take(max));
  String? description(String language) => spanish.description == null
      ? null
      : cut('[$language] ${spanish.description}', maxRecipeDescriptionLength);
  return (
    it: (name: cut('[it] ${spanish.name}', maxRecipeNameLength), description: description('it')),
    en: (name: cut('[en] ${spanish.name}', maxRecipeNameLength), description: description('en')),
  );
}

/// Traductor "en el servidor", en memoria ([fakeTranslation]). El pedido se
/// registra en cuanto llega: [pending] demora solo la respuesta.
class FakeTranslationRepository implements TranslationRepository {
  /// Si no es null, [translate] falla con este error.
  TranslationFailureKind? failure;

  /// Si no es null, [translate] espera a que se complete.
  Completer<void>? pending;

  /// Cada español recibido, en orden (también los que fallaron).
  final List<SpanishText> calls = [];

  @override
  Future<RecipeTranslation> translate(SpanishText spanish) async {
    calls.add(spanish);
    final fail = failure;
    final wait = pending;
    if (wait != null) await wait.future;
    if (fail != null) throw TranslationFailure(fail);
    return fakeTranslation(spanish);
  }
}
