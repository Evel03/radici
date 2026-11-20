// Repositorios falsos en memoria para tests de providers y widgets.
// Para verificar llamadas puntuales se usan mocks de mocktail en cada test.
import 'dart:async';

import 'package:mocktail/mocktail.dart';
import 'package:radici/core/app_language.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/availability/data/availability_repository.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/recipes/data/recipes_repository.dart';
import 'package:radici/features/recipes/data/translation_repository.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_translation.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/domain/chosen_menu.dart';

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
