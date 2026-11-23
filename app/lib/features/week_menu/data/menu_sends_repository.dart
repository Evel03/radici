// El envío del menú de cada semana (contrato docs/contracts/chef-api.md §13,
// migración 20261121100000_menu_sends.sql): la vista previa y el envío con la
// Edge Function `chef`, y lo que salió y lo que contestó la clienta, leído de
// `menu_sends` con la RLS de la cocina (la cocinera y sus colaboradores lo
// leen; nadie lo escribe desde la app). El filtro explícito por chef_id es,
// como en las otras lecturas, para que una cocinera que además fuera clienta
// con cuenta no lea como suyos los envíos de otra cocina.
//
// Como la traducción de los platos (translation_repository.dart): el SDK manda
// la sesión de quien entró (Evelyn o un colaborador suyo) en `Authorization`
// y la clave publicable en `apikey`; la región va en la URL
// (`?forceFunctionRegion=eu-central-1`), nunca en la cabecera `x-region`, que
// el preflight de CORS no permite. Ante un 401 renueva la sesión una vez y
// reintenta una vez: un 401 corta antes de leer el cuerpo, así que reintentar
// un envío nunca lo manda dos veces.
//
// Nada se loguea: ni el contacto, ni el mensaje, ni lo que escribió la
// clienta. Los errores se traducen a [MenuSendFailure] (el tipo, el estado de
// la sesión y si el email ya había salido) y el resto se descarta.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/supabase_client.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart'
    show SessionStatus;
import 'package:radici/features/week_menu/domain/menu_send.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Cuántos envíos lee como mucho una consulta: unos pocos por semana, de las
/// semanas de una reserva (8 como mucho).
const int menuSendsPageSize = 1000;

abstract interface class MenuSendsRepository {
  /// El último envío que salió de cada una de [sessionIds] (las que nunca
  /// mandaron nada no están), en una sola consulta. Lanza [MenuSendFailure]
  /// ([MenuSendFailureKind.unavailable]).
  Future<Map<String, MenuSendRecord>> fetchLatestSends({
    required String chefId,
    required List<String> sessionIds,
  });

  /// El último envío que salió con cada presupuesto de [quoteIds] (por
  /// `quote_id`, desde cualquier semana), en una sola consulta: para saber
  /// si el último envío de una semana salió con una versión anterior
  /// (sentWithEarlierQuote). Lanza [MenuSendFailure]
  /// ([MenuSendFailureKind.unavailable]).
  Future<Map<String, MenuSendRecord>> fetchLatestQuoteSends({
    required String chefId,
    required List<String> quoteIds,
  });

  /// El envío [sendId] si ya salió; null si no existe (para esta cocina) o
  /// todavía no salió. Lanza [MenuSendFailure].
  Future<MenuSendRecord?> fetchSend({
    required String chefId,
    required String sendId,
  });

  /// El presupuesto que lleva la vista previa [sendId] (la semana 1 de un
  /// presupuesto abierto: `menu_sends.snapshot.quote`) y su pedido; null si
  /// el envío no existe para esta cocina. [PreviewSendQuote.quote] es null si
  /// el envío no lleva presupuesto (o si no se puede leer: el mensaje lo
  /// muestra igual). Lanza [MenuSendFailure]
  /// ([MenuSendFailureKind.unavailable]).
  Future<PreviewSendQuote?> fetchPreviewQuote({
    required String chefId,
    required String sendId,
  });

  /// POST chef/menus/preview. Lanza [MenuSendFailure].
  Future<MenuPreview> preview(MenuPreviewRequest request);

  /// POST chef/menus/send. Lanza [MenuSendFailure].
  Future<MenuSendResult> send(MenuSendRequest request);
}

final menuSendsRepositoryProvider = Provider<MenuSendsRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null
      ? const _NoBackendMenuSendsRepository()
      : SupabaseMenuSendsRepository(client);
});

enum MenuSendFailureKind {
  /// Sin conexión: el pedido no salió o la respuesta no llegó (un envío pudo
  /// haber salido). Se puede reintentar.
  offline,

  /// No respondió a tiempo (un envío pudo haber salido). Se puede reintentar.
  timeout,

  /// 503 (la base, Claude o algo pasajero), un 5xx de la plataforma o la
  /// función sin desplegar; también una lectura de `menu_sends` que falló.
  /// Se puede reintentar.
  unavailable,

  /// 422: la lista no se pudo traducir con este texto. Reintentar igual no
  /// sirve: se puede mandar sin traducir.
  untranslatable,

  /// 501: la traducción está apagada. Sin traducir sale igual.
  notConfigured,

  /// 429: la cocina pasó su límite de traducciones. La app nunca reintenta
  /// sola (el intento rechazado también cuenta).
  rateLimited,

  /// 409: el menú se guardó otra vez o, desde la vista previa, cambió el
  /// menú, el día o la hora, las semanas de la reserva o un plato del
  /// catálogo: hace falta otra vista previa.
  menuChanged,

  /// 409: el menú no tiene platos.
  menuEmpty,

  /// 409: la semana es de un presupuesto que ya no está abierto (aceptado,
  /// rechazado, retirado o vencido): su menú ya no sale con él.
  quoteClosed,

  /// 409: la semana es de un presupuesto sin aceptar y no es la primera:
  /// antes de que lo acepte solo sale la semana 1.
  quoteWeekNotFirst,

  /// 409: cambiaron los términos del presupuesto (otro precio, una semana
  /// movida o cancelada) desde la vista previa o mientras se armaba: hace
  /// falta otra vista previa.
  quoteChanged,

  /// 404: la semana no tiene menú guardado.
  menuNotFound,

  /// 404: la sesión no existe (para esta cocina).
  sessionNotFound,

  /// 409: la sesión ya no se manda (cancelada, cocinada o cobrada;
  /// [MenuSendFailure.status]).
  sessionNotEditable,

  /// 409: la sesión no tiene pedido: no hay reserva que mostrar en el link.
  sessionWithoutRequest,

  /// 404: el envío no existe (para esta cocina).
  sendNotFound,

  /// 409: ese envío ya salió (un reintento cuya primera respuesta se perdió).
  alreadySent,

  /// 409: el contacto de ahora no tiene un email que sirva. No salió nada.
  noEmail,

  /// 409: el contacto de ahora no tiene un teléfono que sirva. No salió nada.
  noPhone,

  /// 502: el email no salió; el envío quedó sin marcar.
  emailFailed,

  /// 503: el email no está configurado en el servidor (por WhatsApp sale).
  emailUnavailable,

  /// 401 también después de renovar la sesión: hay que volver a entrar.
  unauthorized,

  /// 403: el usuario no es la cocinera ni un colaborador suyo.
  forbidden,

  /// Otro 409.
  conflict,

  /// 400 y los otros 4xx: un cuerpo que la app no debería mandar.
  invalid,

  /// 500, un 200 con otra forma o un error de la app: reintentar no lo
  /// arregla.
  server;

  /// Probar de nuevo puede andar: la falla es de la red o del momento.
  bool get canRetry =>
      this == offline || this == timeout || this == unavailable;
}

class MenuSendFailure implements Exception {
  const MenuSendFailure(this.kind, {this.status, this.emailSent = false});

  final MenuSendFailureKind kind;

  /// En [MenuSendFailureKind.sessionNotEditable], el estado de la sesión (si
  /// la función lo dijo).
  final SessionStatus? status;

  /// En POST chef/menus/send: el email ya le llegó a la clienta, pero el
  /// envío no quedó marcado (reintentar manda otro email).
  final bool emailSent;

  /// Solo el tipo.
  @override
  String toString() =>
      'MenuSendFailure(${kind.name}${emailSent ? ', emailSent' : ''})';
}

class SupabaseMenuSendsRepository implements MenuSendsRepository {
  SupabaseMenuSendsRepository(this._client, {this.timeout = menuSendTimeout});

  final SupabaseClient _client;

  /// Cuánto se espera la respuesta de la función antes de darla por perdida.
  final Duration timeout;

  static const String previewFunction = 'chef/menus/preview';
  static const String sendFunction = 'chef/menus/send';

  /// Frankfurt, como public-request (contrato public-request §2).
  static const String functionRegion = 'eu-central-1';

  /// La traducción de la lista corta a los 40 s y el email (Resend) a unos
  /// 25 s con su reintento (contrato §12 y §13); el resto es el margen para
  /// la sesión, el arranque de la función y la red.
  static const Duration menuSendTimeout = Duration(seconds: 60);

  static const String _table = 'menu_sends';

  @override
  Future<Map<String, MenuSendRecord>> fetchLatestSends({
    required String chefId,
    required List<String> sessionIds,
  }) => _read(() async {
    if (sessionIds.isEmpty) return const {};
    final rows = await _client
        .from(_table)
        .select(menuSendColumns)
        .eq('chef_id', chefId)
        .inFilter('session_id', sessionIds)
        .not('sent_at', 'is', null)
        .order('sent_at', ascending: false)
        .order('id', ascending: false)
        .limit(menuSendsPageSize);
    return latestSendsBySession(rows.map(MenuSendRecord.fromRow));
  });

  @override
  Future<Map<String, MenuSendRecord>> fetchLatestQuoteSends({
    required String chefId,
    required List<String> quoteIds,
  }) => _read(() async {
    if (quoteIds.isEmpty) return const {};
    final rows = await _client
        .from(_table)
        .select(menuSendColumns)
        .eq('chef_id', chefId)
        .inFilter('quote_id', quoteIds)
        .not('sent_at', 'is', null)
        .order('sent_at', ascending: false)
        .order('id', ascending: false)
        .limit(menuSendsPageSize);
    return latestSendsByQuote(rows.map(MenuSendRecord.fromRow));
  });

  @override
  Future<MenuSendRecord?> fetchSend({
    required String chefId,
    required String sendId,
  }) => _read(() async {
    final row = await _client
        .from(_table)
        .select(menuSendColumns)
        .eq('chef_id', chefId)
        .eq('id', sendId)
        .not('sent_at', 'is', null)
        .maybeSingle();
    return row == null ? null : MenuSendRecord.fromRow(row);
  });

  @override
  Future<PreviewSendQuote?> fetchPreviewQuote({
    required String chefId,
    required String sendId,
  }) => _read(() async {
    final row = await _client
        .from(_table)
        .select(previewQuoteColumns)
        .eq('chef_id', chefId)
        .eq('id', sendId)
        .maybeSingle();
    return row == null ? null : previewSendQuoteFromRow(row);
  });

  @override
  Future<MenuPreview> preview(MenuPreviewRequest request) =>
      _invoke(previewFunction, request.toBody(), MenuPreview.fromResponse);

  @override
  Future<MenuSendResult> send(MenuSendRequest request) =>
      _invoke(sendFunction, request.toBody(), MenuSendResult.fromResponse);

  /// Llama a la función y lee su respuesta con [read]. Un 401 renueva la
  /// sesión una vez y reintenta una vez.
  Future<T> _invoke<T>(
    String function,
    Map<String, Object> body,
    T Function(Object? json) read,
  ) async {
    try {
      return await _invokeOnce(function, body, read);
    } on MenuSendFailure catch (failure) {
      if (failure.kind != MenuSendFailureKind.unauthorized) rethrow;
    }
    // 401: el token venció o la sesión se renovó en otro lado. Una sola
    // renovación y un solo reintento; si no alcanza, hay que volver a entrar.
    try {
      await _client.auth.refreshSession();
    } on Object {
      throw const MenuSendFailure(MenuSendFailureKind.unauthorized);
    }
    return _invokeOnce(function, body, read);
  }

  Future<T> _invokeOnce<T>(
    String function,
    Map<String, Object> body,
    T Function(Object? json) read,
  ) async {
    final FunctionResponse response;
    try {
      response = await _client.functions
          .invoke(
            function,
            body: body,
            // Solo el parámetro: `region:` también mandaría x-region.
            queryParameters: const {'forceFunctionRegion': functionRegion},
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const MenuSendFailure(MenuSendFailureKind.timeout);
    } on FunctionsFetchException catch (error) {
      // La red falló (al mandar o al leer la respuesta). Un Error (de
      // programación, no de la red) que el SDK envolvió no se esconde como
      // falla de red.
      throw MenuSendFailure(
        error.details is Error
            ? MenuSendFailureKind.server
            : MenuSendFailureKind.offline,
      );
    } on FunctionsHttpException catch (error) {
      throw menuSendFailureFromResponse(error.status, error.details);
    } on FunctionsRelayException catch (error) {
      // El relay de la plataforma no llegó a la función: su estado dice si es
      // pasajero (502, 503, 504) o no (500).
      throw menuSendFailureFromResponse(error.status, null);
    } on Object {
      // Otra cosa (un error de la app, el SDK de Auth): no es la red, y
      // reintentar no la arregla.
      throw const MenuSendFailure(MenuSendFailureKind.server);
    }
    try {
      return read(response.data);
    } on Object {
      // Un 200 con otra forma: la función no cumple el contrato.
      throw const MenuSendFailure(MenuSendFailureKind.server);
    }
  }

  /// Traduce cualquier error de red, de PostgREST o de una fila rota a
  /// [MenuSendFailureKind.unavailable]. No se loguea el detalle: puede traer
  /// el mensaje de la clienta.
  Future<T> _read<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on Object {
      throw const MenuSendFailure(MenuSendFailureKind.unavailable);
    }
  }
}

/// Traduce una respuesta de error de la función (contrato §3 y §13) a
/// [MenuSendFailure]. Del cuerpo solo se usan el código, el estado de la
/// sesión (si es uno de `session_status`) y `emailSent`: nada más pasa.
MenuSendFailure menuSendFailureFromResponse(int status, Object? body) {
  final map = body is Map ? body : const <Object?, Object?>{};
  final error = map['error'];
  final emailSent = map['emailSent'] == true;
  MenuSendFailure failure(MenuSendFailureKind kind, {SessionStatus? state}) =>
      MenuSendFailure(kind, status: state, emailSent: emailSent);
  switch (status) {
    case 400:
      return failure(MenuSendFailureKind.invalid);
    case 401:
      return failure(MenuSendFailureKind.unauthorized);
    case 403:
      return failure(MenuSendFailureKind.forbidden);
    case 404:
      // Sin uno de estos códigos, el 404 es de la plataforma (la función no
      // está desplegada) o de una función de antes de /menus: se puede
      // reintentar más tarde.
      return switch (error) {
        'sessionNotFound' => failure(MenuSendFailureKind.sessionNotFound),
        'menuNotFound' => failure(MenuSendFailureKind.menuNotFound),
        'sendNotFound' => failure(MenuSendFailureKind.sendNotFound),
        _ => failure(MenuSendFailureKind.unavailable),
      };
    case 409:
      return switch (error) {
        'menuChanged' => failure(MenuSendFailureKind.menuChanged),
        'menuEmpty' => failure(MenuSendFailureKind.menuEmpty),
        'sessionNotEditable' => failure(
          MenuSendFailureKind.sessionNotEditable,
          state: SessionStatus.fromDb(map['status']),
        ),
        'sessionWithoutRequest' => failure(
          MenuSendFailureKind.sessionWithoutRequest,
        ),
        'alreadySent' => failure(MenuSendFailureKind.alreadySent),
        'noEmail' => failure(MenuSendFailureKind.noEmail),
        'noPhone' => failure(MenuSendFailureKind.noPhone),
        'quoteClosed' => failure(MenuSendFailureKind.quoteClosed),
        'quoteWeekNotFirst' => failure(MenuSendFailureKind.quoteWeekNotFirst),
        'quoteChanged' => failure(MenuSendFailureKind.quoteChanged),
        _ => failure(MenuSendFailureKind.conflict),
      };
    case 422 when error == 'untranslatable':
      return failure(MenuSendFailureKind.untranslatable);
    // Sin el código de la función, el 429 es de la plataforma: pasajero.
    case 429:
      return failure(
        error == 'rateLimited'
            ? MenuSendFailureKind.rateLimited
            : MenuSendFailureKind.unavailable,
      );
    case 501:
      return failure(
        error == 'notConfigured'
            ? MenuSendFailureKind.notConfigured
            : MenuSendFailureKind.server,
      );
    case 502 when error == 'emailFailed':
      return failure(MenuSendFailureKind.emailFailed);
    case 503 when error == 'emailUnavailable':
      return failure(MenuSendFailureKind.emailUnavailable);
    case 500:
      return failure(MenuSendFailureKind.server);
    case >= 400 && < 500:
      // 405, 413, 415, un 422 sin su código: un cuerpo que la app no debería
      // mandar.
      return failure(MenuSendFailureKind.invalid);
    default:
      // 503 y los 5xx de la plataforma (502, 504…): pasajeros.
      return failure(MenuSendFailureKind.unavailable);
  }
}

class _NoBackendMenuSendsRepository implements MenuSendsRepository {
  const _NoBackendMenuSendsRepository();

  static const _failure = MenuSendFailure(MenuSendFailureKind.unavailable);

  @override
  Future<Map<String, MenuSendRecord>> fetchLatestSends({
    required String chefId,
    required List<String> sessionIds,
  }) => Future.error(_failure);

  @override
  Future<Map<String, MenuSendRecord>> fetchLatestQuoteSends({
    required String chefId,
    required List<String> quoteIds,
  }) => Future.error(_failure);

  @override
  Future<MenuSendRecord?> fetchSend({
    required String chefId,
    required String sendId,
  }) => Future.error(_failure);

  @override
  Future<PreviewSendQuote?> fetchPreviewQuote({
    required String chefId,
    required String sendId,
  }) => Future.error(_failure);

  @override
  Future<MenuPreview> preview(MenuPreviewRequest request) =>
      Future.error(_failure);

  @override
  Future<MenuSendResult> send(MenuSendRequest request) =>
      Future.error(_failure);
}
