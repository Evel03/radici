// Servidor de Supabase Realtime simulado (protocolo Phoenix 2.0.0) para el
// cliente real de supabase_flutter: responde joins y heartbeats, manda
// cambios de Postgres y puede cortar la conexión para probar la reconexión.
import 'dart:async';
import 'dart:convert';

import 'package:web_socket/testing.dart';
import 'package:web_socket/web_socket.dart';
import 'package:web_socket_channel/adapter_web_socket_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class FakeRealtimeServer {
  final List<WebSocket> _sockets = [];

  /// Ids que el servidor asignó a los bindings de cada tópico.
  final Map<String, List<int>> _bindingIds = {};
  int _nextBindingId = 100;

  /// Cuántas conexiones abrió el cliente.
  int get connections => _sockets.length;

  /// Joins recibidos (tópico y config de postgres_changes).
  final List<({String topic, List<Map<String, dynamic>> postgresChanges})>
  joins = [];

  final StreamController<String> _joined = StreamController.broadcast();

  /// Emite el tópico cada vez que un canal se une (también al reconectar).
  Stream<String> get onJoin => _joined.stream;

  /// Transporte para `RealtimeClientOptions(transport: ...)`.
  WebSocketChannel connect(String url, Map<String, String> headers) {
    final (client, server) = fakes();
    _sockets.add(server);
    server.events.listen((event) {
      if (event is TextDataReceived) _onMessage(server, event.text);
    });
    return AdapterWebSocketChannel(client);
  }

  void _onMessage(WebSocket socket, String text) {
    final frame = jsonDecode(text) as List<dynamic>;
    final joinRef = frame[0];
    final ref = frame[1];
    final topic = frame[2] as String;
    final event = frame[3] as String;
    final payload = frame[4];

    Map<String, dynamic> response = const {};
    if (event == 'phx_join') {
      final config = (payload as Map<String, dynamic>)['config'] as Map;
      final changes = (config['postgres_changes'] as List)
          .cast<Map<String, dynamic>>();
      final ids = [for (final _ in changes) _nextBindingId++];
      _bindingIds[topic] = ids;
      joins.add((topic: topic, postgresChanges: changes));
      response = {
        'postgres_changes': [
          for (var i = 0; i < changes.length; i++) {...changes[i], 'id': ids[i]},
        ],
      };
    }
    if (ref != null) {
      socket.sendText(
        jsonEncode([
          joinRef,
          ref,
          topic,
          'phx_reply',
          {'status': 'ok', 'response': response},
        ]),
      );
    }
    if (event == 'phx_join') _joined.add(topic);
  }

  /// Manda un INSERT en `public.requests` al canal [topic].
  void pushInsert(String topic, Map<String, dynamic> record) {
    _sockets.last.sendText(
      jsonEncode([
        null,
        null,
        topic,
        'postgres_changes',
        {
          'ids': _bindingIds[topic],
          'data': {
            'schema': 'public',
            'table': 'requests',
            'commit_timestamp': '2026-10-19T12:00:00Z',
            'type': 'INSERT',
            'columns': [
              for (final column in record.keys) {'name': column, 'type': 'text'},
            ],
            'record': record,
            'errors': null,
          },
        },
      ]),
    );
  }

  /// Corta la conexión actual desde el servidor (como una caída de red).
  Future<void> dropConnection() => _sockets.last.close();

  Future<void> dispose() async {
    await _joined.close();
  }
}
