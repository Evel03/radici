// Repositorios falsos en memoria para tests de providers y widgets.
// Para verificar llamadas puntuales se usan mocks de mocktail en cada test.
import 'dart:async';

import 'package:mocktail/mocktail.dart';
import 'package:radici/core/app_language.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

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
    final list = requests.values.where((r) => r.chefId == chefId).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  @override
  Future<ChefRequest?> fetchRequest(String id) async {
    if (failFetch) throw const RequestsFailure(RequestsFailureKind.unavailable);
    return requests[id];
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
