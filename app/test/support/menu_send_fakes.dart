// El envío del menú "en el servidor", en memoria, como la función chef y
// `menu_sends` (contrato chef-api §13): la vista previa guarda un envío sin
// salir (con [FakeSessionMenusRepository], como la base: otra versión da
// menuChanged, un menú sin platos menuEmpty, una semana que ya no se arma
// sessionNotEditable); mandarlo lo marca enviado (uno que ya salió da
// alreadySent; sin email o sin teléfono que sirvan, noEmail o noPhone), y la
// lectura devuelve el último que salió de cada sesión. Cada pedido se aplica
// en cuanto llega: los `pending…` demoran solo la respuesta, como una red
// lenta, y [loseSendResponse] aplica el envío y pierde la respuesta.
import 'dart:async';

import 'package:radici/features/requests/domain/chef_request.dart'
    show ClientLocale;
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/week_menu/data/menu_sends_repository.dart';
import 'package:radici/features/week_menu/domain/menu_send.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

import 'menu_fakes.dart';

/// El contacto de la clienta de los tests (datos inventados).
const MenuSendContact testMenuContact = MenuSendContact(
  name: 'Giulia Rossi',
  email: 'giulia@example.test',
  phone: '+39 333 123 4567',
);

/// "Ahora" de los envíos: domingo 22/11/2026 a las 14:32 en Roma.
final DateTime testSentAt = DateTime.utc(2026, 11, 22, 13, 32);

/// El texto de reemplazo del link en la vista previa, en italiano (como la
/// función).
const String testLinkPlaceholder = '[link personale per confermare]';

/// Un envío que salió, de la sesión [sessionId].
MenuSendRecord sentMenu({
  String id = 'send-0',
  required String sessionId,
  int menuVersion = 1,
  DateTime? sentAt,
  List<MenuSendChannel> via = const [MenuSendChannel.email],
  DateTime? confirmedAt,
  DateTime? changesRequestedAt,
  String? changesText,
}) => MenuSendRecord(
  id: id,
  sessionId: sessionId,
  menuVersion: menuVersion,
  sentAt: sentAt ?? testSentAt,
  via: via,
  confirmedAt: confirmedAt,
  changesRequestedAt: changesRequestedAt,
  changesText: changesText,
);

class FakeMenuSendsRepository implements MenuSendsRepository {
  FakeMenuSendsRepository({
    this.menus,
    Iterable<MenuSendRecord> sent = const [],
    this.contact = testMenuContact,
    this.locale = ClientLocale.it,
    DateTime Function()? now,
  }) : sent = [...sent],
       now = now ?? (() => testSentAt);

  /// Los menús guardados y el estado de cada sesión (sin esto, toda vista
  /// previa sale).
  final FakeSessionMenusRepository? menus;

  /// Los envíos que salieron: los de antes y los que se mandan acá.
  final List<MenuSendRecord> sent;

  /// El contacto de la clienta de ahora (el que usa el envío).
  MenuSendContact contact;

  /// El idioma de la clienta.
  ClientLocale locale;

  final DateTime Function() now;

  /// Fallas de la vista previa y del envío, una por pedido, en orden (la
  /// primera se usa y se saca). Un envío que falla no sale.
  final List<MenuSendFailure> previewFailures = [];
  final List<MenuSendFailure> sendFailures = [];

  /// Si no es null, las lecturas de `menu_sends` fallan con esto.
  MenuSendFailure? readFailure;

  /// El envío se aplica pero la respuesta no llega: falla con esto (por
  /// ejemplo, timeout). Se usa una vez.
  MenuSendFailure? loseSendResponse;

  /// Si no son null, la respuesta espera a que se completen.
  Completer<void>? pendingPreview;
  Completer<void>? pendingSend;

  /// Cada pedido recibido, en orden (también los que fallaron).
  final List<MenuPreviewRequest> previews = [];
  final List<MenuSendRequest> sends = [];
  final List<List<String>> latestCalls = [];
  final List<String> sendFetches = [];

  /// Los envíos preparados por la vista previa, por id.
  final Map<String, ({String sessionId, int menuVersion})> prepared = {};

  int _nextId = 1;

  @override
  Future<Map<String, MenuSendRecord>> fetchLatestSends({
    required String chefId,
    required List<String> sessionIds,
  }) async {
    latestCalls.add(List.of(sessionIds));
    final failure = readFailure;
    if (failure != null) throw failure;
    final ids = sessionIds.toSet();
    return latestSendsBySession(
      sent.where((record) => ids.contains(record.sessionId)),
    );
  }

  @override
  Future<MenuSendRecord?> fetchSend({
    required String chefId,
    required String sendId,
  }) async {
    sendFetches.add(sendId);
    final failure = readFailure;
    if (failure != null) throw failure;
    return sent.where((record) => record.id == sendId).firstOrNull;
  }

  @override
  Future<MenuPreview> preview(MenuPreviewRequest request) async {
    previews.add(request);
    MenuSendFailure? refused = previewFailures.isEmpty
        ? null
        : previewFailures.removeAt(0);
    refused ??= _refusal(request.sessionId, request.menuVersion);
    String? sendId;
    if (refused == null) {
      sendId = 'send-${_nextId++}';
      prepared[sendId] = (
        sessionId: request.sessionId,
        menuVersion: request.menuVersion,
      );
    }
    final pending = pendingPreview;
    if (pending != null) await pending.future;
    if (refused != null) throw refused;
    final translated = request.translate && locale != ClientLocale.es;
    return MenuPreview(
      sendId: sendId!,
      locale: locale,
      translated: translated,
      contact: contact,
      subject: 'Radici: il menù della settimana',
      emailText:
          'Ciao Giulia!\n\nEvelyn ha preparato il menù.\n\n'
          '${translated ? 'Zucchine' : 'zapallitos'}\n\n$testLinkPlaceholder',
      whatsappText:
          'Ciao Giulia!\n*Il menù*\n'
          '${translated ? 'Zucchine' : 'zapallitos'}\n$testLinkPlaceholder',
    );
  }

  @override
  Future<MenuSendResult> send(MenuSendRequest request) async {
    sends.add(request);
    MenuSendFailure? refused = sendFailures.isEmpty
        ? null
        : sendFailures.removeAt(0);
    final draft = prepared[request.sendId];
    if (refused == null && sent.any((record) => record.id == request.sendId)) {
      refused = const MenuSendFailure(MenuSendFailureKind.alreadySent);
    }
    if (refused == null && draft == null) {
      refused = const MenuSendFailure(MenuSendFailureKind.sendNotFound);
    }
    if (refused == null && draft != null) {
      refused = _refusal(draft.sessionId, draft.menuVersion);
    }
    if (refused == null && request.email && contact.usableEmail == null) {
      refused = const MenuSendFailure(MenuSendFailureKind.noEmail);
    }
    if (refused == null && request.whatsapp && contact.phoneE164 == null) {
      refused = const MenuSendFailure(MenuSendFailureKind.noPhone);
    }
    final via = menuSendChannels(
      email: request.email,
      whatsapp: request.whatsapp,
    );
    final sentAt = now();
    if (refused == null && draft != null) {
      sent.add(
        MenuSendRecord(
          id: request.sendId,
          sessionId: draft.sessionId,
          menuVersion: draft.menuVersion,
          sentAt: sentAt,
          via: via,
        ),
      );
    }
    final pending = pendingSend;
    if (pending != null) await pending.future;
    if (refused != null) throw refused;
    final lost = loseSendResponse;
    if (lost != null) {
      loseSendResponse = null;
      throw lost;
    }
    return MenuSendResult(
      sentAt: sentAt,
      via: via,
      whatsappText: request.whatsapp
          ? 'Ciao Giulia!\n*Il menù*\n'
                'https://radicicucina.app/prenotazione/#t=${request.sendId}'
          : null,
      whatsappPhone: request.whatsapp ? contact.phoneE164 : null,
    );
  }

  /// Lo que la base rechaza de la semana [sessionId] con la versión
  /// [menuVersion] (null si nada).
  MenuSendFailure? _refusal(String sessionId, int menuVersion) {
    final menus = this.menus;
    if (menus == null) return null;
    if (menus.missing.contains(sessionId)) {
      return const MenuSendFailure(MenuSendFailureKind.sessionNotFound);
    }
    final status = menus.statuses[sessionId] ?? SessionStatus.confirmed;
    if (!isMenuEditable(status)) {
      return MenuSendFailure(
        MenuSendFailureKind.sessionNotEditable,
        status: status,
      );
    }
    final saved = menus.menus[sessionId];
    if (saved == null || saved.version == null) {
      return const MenuSendFailure(MenuSendFailureKind.menuNotFound);
    }
    if (saved.version != menuVersion) {
      return const MenuSendFailure(MenuSendFailureKind.menuChanged);
    }
    if (saved.dishes.isEmpty) {
      return const MenuSendFailure(MenuSendFailureKind.menuEmpty);
    }
    return null;
  }
}
