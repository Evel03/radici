// SupabaseClient de verdad conectado a un servidor HTTP simulado (MockClient
// de package:http): prueba los repositorios con las consultas reales que arma
// el SDK, sin red ni Supabase local.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_realtime_server.dart';

const String fakeSupabaseUrl = 'https://example.supabase.co';

/// Respuesta JSON con las cabeceras que espera el SDK.
http.Response jsonResponse(Object? body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// Guarda los pedidos HTTP y responde con [handler].
class FakeSupabaseHttp {
  FakeSupabaseHttp(this.handler, {FakeRealtimeServer? realtime})
    : realtime = realtime ?? FakeRealtimeServer();

  Future<http.Response> Function(http.Request request) handler;
  final List<http.Request> requests = [];

  /// Realtime simulado: el cliente nunca abre un WebSocket de verdad.
  final FakeRealtimeServer realtime;

  late final SupabaseClient client = SupabaseClient(
    fakeSupabaseUrl,
    'sb_publishable_test',
    httpClient: MockClient((request) async {
      requests.add(request);
      final response = await handler(request);
      // El SDK lee response.request: MockClient solo lo pasa si viene puesto.
      return http.Response.bytes(
        response.bodyBytes,
        response.statusCode,
        headers: response.headers,
        reasonPhrase: response.reasonPhrase,
        request: request,
      );
    }),
    authOptions: AuthClientOptions(
      autoRefreshToken: false,
      pkceAsyncStorage: InMemoryAsyncStorage(),
    ),
    realtimeClientOptions: RealtimeClientOptions(transport: realtime.connect),
  );

  http.Request get last => requests.last;

  Future<void> dispose() async {
    await client.dispose();
    await realtime.dispose();
  }
}

/// Almacenamiento en memoria para el verificador PKCE de Supabase Auth.
class InMemoryAsyncStorage extends GotrueAsyncStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> getItem({required String key}) async => _values[key];

  @override
  Future<void> removeItem({required String key}) async => _values.remove(key);

  @override
  Future<void> setItem({required String key, required String value}) async =>
      _values[key] = value;
}

/// Cuerpo JSON de un pedido HTTP.
Map<String, dynamic> jsonBodyOf(http.Request request) =>
    jsonDecode(request.body) as Map<String, dynamic>;

/// JWT con la forma de los de Supabase (firma falsa, vence en 2100).
String fakeJwt(String userId) {
  String part(Map<String, Object> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final header = part({'alg': 'HS256', 'typ': 'JWT'});
  final payload = part({
    'sub': userId,
    'role': 'authenticated',
    'aud': 'authenticated',
    'exp': 4102444800,
  });
  return '$header.$payload.firma';
}

/// Usuario de GoTrue (como lo devuelven /auth/v1/verify y /auth/v1/user).
Map<String, Object?> fakeUserJson(String userId, String email) => {
  'id': userId,
  'aud': 'authenticated',
  'role': 'authenticated',
  'email': email,
  'app_metadata': <String, Object>{},
  'user_metadata': <String, Object>{},
  'created_at': '2026-10-19T10:00:00Z',
};

/// Sesión de GoTrue (respuesta de /auth/v1/verify).
Map<String, Object?> fakeSessionJson(String userId, String email) => {
  'access_token': fakeJwt(userId),
  'token_type': 'bearer',
  'expires_in': 3600,
  'refresh_token': 'refresh',
  'user': fakeUserJson(userId, email),
};

/// Abre una sesión en el cliente de [server] verificando un código simulado
/// y olvida esos pedidos (los tests ven solo los suyos).
Future<void> signInFake(
  FakeSupabaseHttp server, {
  String userId = 'user-1',
  String email = 'evelyn@example.test',
}) async {
  final handler = server.handler;
  server.handler = (_) async => jsonResponse(fakeSessionJson(userId, email));
  await server.client.auth.verifyOTP(
    email: email,
    token: '123456',
    type: OtpType.email,
  );
  server
    ..handler = handler
    ..requests.clear();
}
