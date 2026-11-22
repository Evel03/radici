// «Mandar el menú» de una semana a la clienta (SPEC 5.8, «Envío del menú»;
// contrato chef-api §13), en dos pasos:
//
// 1. La vista previa (POST chef/menus/preview) con la versión guardada del
//    menú: el mensaje en el idioma de la clienta, sin el link, y su contacto.
//    Por defecto traduce los nombres de la lista; si la traducción falla,
//    Evelyn puede volver a probar (solo si la falla es pasajera) o seguir sin
//    traducir. Nunca se reintenta sola: cada intento gasta el cupo de
//    traducciones de la cocina.
// 2. El envío (POST chef/menus/send) con el `sendId` de esa vista previa y los
//    canales que eligió (solo los que el contacto permite). Si pidió WhatsApp,
//    la app lo abre desde el teléfono de quien manda con el texto y el link
//    que devuelve la función (en la web, con un toque: el navegador bloquea
//    una ventana que no sale de un gesto).
//
// Un toque doble o una respuesta perdida nunca mandan dos veces: mientras
// manda no acepta otro envío, y reintentar usa el mismo `sendId`; si ya había
// salido, la función dice alreadySent y la app lo confirma leyendo
// `menu_sends` (lo que salió, sin el texto del WhatsApp: el link solo viaja en
// la respuesta). Si el email salió pero el envío no quedó registrado
// (`emailSent`), lo dice y vuelve a leer el estado. Después de mandar, la
// ficha, el editor y la reserva vuelven a leer el último envío.
//
// La semana 1 de un presupuesto sin aceptar lo lleva (SPEC 5.8): después de
// la vista previa se lee de `menu_sends` (con la RLS de la cocina) el
// presupuesto de su foto, lo que va a ver la clienta, para mostrarlo arriba
// del mensaje (la respuesta de la vista previa no lo trae). Al mandarlo, el
// pedido y su presupuesto se vuelven a leer. Si el presupuesto se cerró,
// cambió o la semana no es la primera, lo dice (quoteClosed, quoteChanged,
// quoteWeekNotFirst).
//
// Nada se loguea: ni el contacto, ni el mensaje.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/platform.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/quotes/application/quote_providers.dart';
import 'package:radici/features/quotes/domain/preview_quote.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/week_menu/application/week_menu_summaries.dart';
import 'package:radici/features/week_menu/data/menu_sends_repository.dart';
import 'package:radici/features/week_menu/data/session_menus_repository.dart';
import 'package:radici/features/week_menu/domain/menu_send.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

part 'menu_send_controller.freezed.dart';

/// En qué paso está el envío.
enum MenuSendStep {
  /// Todavía no pidió la vista previa.
  idle,

  /// Armando la vista previa (con la traducción de la lista, si hace falta).
  previewing,

  /// La vista previa está a la vista: se elige por dónde y se manda.
  ready,

  /// No se pudo armar la vista previa ([MenuSendState.failure]).
  previewFailed,

  /// Mandando.
  sending,

  /// No salió, o no se sabe si salió ([MenuSendState.failure]). La vista
  /// previa sigue a la vista.
  sendFailed,

  /// Salió ([MenuSendState.result]).
  sent,
}

@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class MenuSendState with _$MenuSendState {
  const factory MenuSendState({
    required String sessionId,

    /// La versión guardada del menú que se manda (null hasta empezar).
    int? menuVersion,
    @Default(MenuSendStep.idle) MenuSendStep step,

    /// Traducir los nombres de la lista (false después de «Seguir sin
    /// traducir»: las vistas previas siguientes tampoco traducen).
    @Default(true) bool translate,

    /// La última vista previa (null mientras no hay).
    MenuPreview? preview,

    /// El presupuesto que lleva la vista previa (la semana 1 de uno sin
    /// aceptar), como lo va a ver la clienta; null si no lleva (o si no se
    /// pudo leer: el mensaje lo muestra igual).
    PreviewQuote? quote,

    /// El pedido de la semana (de la vista previa), para volver a leerlo al
    /// mandar el presupuesto.
    String? requestId,

    /// Por dónde se manda: lo que eligió, solo si el contacto lo permite.
    @Default(false) bool email,
    @Default(false) bool whatsapp,

    /// Por qué falló la vista previa o el envío.
    MenuSendFailure? failure,

    /// Lo que salió.
    MenuSendResult? result,

    /// Se supo que salió leyendo `menu_sends` (la respuesta se perdió): sin el
    /// texto del WhatsApp.
    @Default(false) bool recovered,

    /// Se pidió WhatsApp en el envío que salió.
    @Default(false) bool sentWithWhatsapp,

    /// WhatsApp se abrió solo después de mandar (null: no se intentó, como en
    /// la web).
    bool? whatsAppOpened,
  }) = _MenuSendState;

  const MenuSendState._();

  /// Pidiendo la vista previa o mandando: nada más se puede hacer.
  bool get busy =>
      step == MenuSendStep.previewing || step == MenuSendStep.sending;

  /// El contacto tiene un email que sirve.
  bool get emailAvailable => preview?.contact.usableEmail != null;

  /// El contacto tiene un teléfono que sirve para WhatsApp.
  bool get whatsappAvailable => preview?.contact.phoneE164 != null;

  /// Con el envío de esta vista previa se puede volver a probar. No después
  /// de que cambió algo (otra vista previa), la sesión ya no se manda, o una
  /// falla que reintentar no arregla.
  bool get canResend {
    final failure = this.failure;
    if (failure == null) return true;
    if (failure.emailSent) {
      return failure.kind != MenuSendFailureKind.menuChanged &&
          failure.kind != MenuSendFailureKind.sessionNotEditable &&
          failure.kind != MenuSendFailureKind.quoteChanged &&
          failure.kind != MenuSendFailureKind.quoteClosed;
    }
    return failure.kind.canRetry ||
        failure.kind == MenuSendFailureKind.emailFailed ||
        failure.kind == MenuSendFailureKind.emailUnavailable ||
        failure.kind == MenuSendFailureKind.noEmail ||
        failure.kind == MenuSendFailureKind.noPhone;
  }

  /// Se puede tocar «Mandar»: hay vista previa, no está mandando y eligió al
  /// menos un canal que el contacto permite.
  bool get canSend =>
      preview != null &&
      (step == MenuSendStep.ready ||
          (step == MenuSendStep.sendFailed && canResend)) &&
      (email || whatsapp) &&
      (!email || emailAvailable) &&
      (!whatsapp || whatsappAvailable);

  /// Los canales elegidos, en el orden de la base.
  List<MenuSendChannel> get channels =>
      menuSendChannels(email: email, whatsapp: whatsapp);

  /// El link de WhatsApp de lo que salió (null si no se pidió o se perdió).
  Uri? get whatsAppLink => result?.whatsAppLink;

  /// Se pidió WhatsApp pero el texto con el link se perdió con la respuesta:
  /// para mandarlo por WhatsApp hace falta otra vista previa.
  bool get whatsAppLost =>
      step == MenuSendStep.sent && sentWithWhatsapp && whatsAppLink == null;

  @override
  String toString() => 'MenuSendState($sessionId, ${step.name})';
}

/// El envío del menú de la sesión [sessionId], mientras la pantalla está
/// abierta (y, mientras manda, hasta que llega la respuesta).
final menuSendProvider = NotifierProvider.autoDispose
    .family<MenuSendController, MenuSendState, String>(MenuSendController.new);

class MenuSendController extends Notifier<MenuSendState> {
  MenuSendController(this.sessionId);

  final String sessionId;

  MenuSendsRepository get _repository => ref.read(menuSendsRepositoryProvider);

  @override
  MenuSendState build() => MenuSendState(sessionId: sessionId);

  void _set(MenuSendState next) {
    if (ref.mounted) state = next;
  }

  /// Empieza con la versión guardada [menuVersion]: la vista previa,
  /// traducida. Mientras pide la vista previa o manda, no hace nada.
  Future<void> start(int menuVersion) async {
    if (state.busy) return;
    _set(MenuSendState(sessionId: sessionId, menuVersion: menuVersion));
    await _preview(translate: true);
  }

  /// Vuelve a pedir la vista previa igual (después de una falla pasajera).
  Future<void> retryPreview() => _preview(translate: state.translate);

  /// «Seguir sin traducir»: la vista previa con la lista como la escribió
  /// Evelyn.
  Future<void> previewWithoutTranslation() => _preview(translate: false);

  /// Otra vista previa (otro envío) con la misma versión: después de que
  /// cambió algo desde la anterior, o el contacto. Si salió pero se perdió
  /// el texto del WhatsApp, la nueva queda elegida solo por WhatsApp (si iba
  /// también por email, ese ya le llegó).
  Future<void> newPreview() =>
      _preview(translate: state.translate, onlyWhatsapp: state.whatsAppLost);

  /// La vista previa del menú guardado de ahora: vuelve a leer su versión
  /// (otro teléfono lo guardó después de que se cargó).
  Future<void> previewSaved() =>
      _preview(translate: state.translate, latestVersion: true);

  Future<void> _preview({
    required bool translate,
    bool latestVersion = false,
    bool onlyWhatsapp = false,
  }) async {
    final current = state;
    if (current.busy) return;
    _set(
      current.copyWith(
        step: MenuSendStep.previewing,
        translate: translate,
        preview: null,
        quote: null,
        failure: null,
        result: null,
        recovered: false,
        sentWithWhatsapp: false,
        whatsAppOpened: null,
      ),
    );
    var version = current.menuVersion;
    try {
      if (latestVersion) version = await _savedVersion();
      if (version == null) {
        throw const MenuSendFailure(MenuSendFailureKind.menuNotFound);
      }
      final preview = await _repository.preview(
        MenuPreviewRequest(
          sessionId: sessionId,
          menuVersion: version,
          translate: translate,
        ),
      );
      // El presupuesto de la foto, si lo lleva (la semana 1 de uno sin
      // aceptar). Si no se puede leer, el mensaje lo muestra igual.
      final quote = await _previewQuote(preview.sendId);
      final contact = preview.contact;
      final whatsapp = contact.phoneE164 != null;
      _set(
        state.copyWith(
          step: MenuSendStep.ready,
          menuVersion: version,
          preview: preview,
          quote: quote?.quote,
          requestId: quote?.requestId ?? state.requestId,
          email: contact.usableEmail != null && !(onlyWhatsapp && whatsapp),
          whatsapp: whatsapp,
        ),
      );
    } on MenuSendFailure catch (failure) {
      if (!ref.mounted) return;
      _afterFailure(failure);
      _set(
        state.copyWith(
          step: MenuSendStep.previewFailed,
          menuVersion: version,
          failure: failure,
        ),
      );
    }
  }

  /// El presupuesto que lleva la vista previa [sendId] y su pedido; null si
  /// no se puede leer (no es un error: el mensaje ya lo trae).
  Future<PreviewSendQuote?> _previewQuote(String sendId) async {
    final chefId = ref.read(currentChefProvider)?.chefId;
    if (chefId == null) return null;
    try {
      return await _repository.fetchPreviewQuote(
        chefId: chefId,
        sendId: sendId,
      );
    } on MenuSendFailure {
      return null;
    }
  }

  /// La versión del menú guardado de ahora. Lanza [MenuSendFailure].
  Future<int> _savedVersion() async {
    final chefId = ref.read(currentChefProvider)?.chefId;
    if (chefId == null) {
      throw const MenuSendFailure(MenuSendFailureKind.forbidden);
    }
    final Map<String, WeekMenuSummary> summaries;
    try {
      summaries = await ref
          .read(sessionMenusRepositoryProvider)
          .fetchSummaries(chefId: chefId, sessionIds: [sessionId]);
    } on MenuFailure {
      throw const MenuSendFailure(MenuSendFailureKind.unavailable);
    }
    final summary = summaries[sessionId];
    if (summary == null) {
      throw const MenuSendFailure(MenuSendFailureKind.sessionNotFound);
    }
    // El menú que se va a mandar: la ficha y la reserva lo vuelven a contar.
    _refreshMenus();
    final version = summary.version;
    if (version == null) {
      throw const MenuSendFailure(MenuSendFailureKind.menuNotFound);
    }
    return version;
  }

  /// Elige mandarlo por email (si el contacto tiene un email que sirve).
  void setEmail(bool value) {
    if (state.busy || (value && !state.emailAvailable)) return;
    _set(state.copyWith(email: value));
  }

  /// Elige mandarlo por WhatsApp (si el contacto tiene un teléfono que
  /// sirve).
  void setWhatsapp(bool value) {
    if (state.busy || (value && !state.whatsappAvailable)) return;
    _set(state.copyWith(whatsapp: value));
  }

  /// «Mandar solo por WhatsApp» o «solo por email»: elige ese canal solo y
  /// manda.
  Future<void> sendOnly(MenuSendChannel channel) async {
    final current = state;
    if (current.busy) return;
    _set(
      current.copyWith(
        email: channel == MenuSendChannel.email,
        whatsapp: channel == MenuSendChannel.whatsapp,
      ),
    );
    await send();
  }

  /// Manda el envío de la vista previa por los canales elegidos. Un segundo
  /// toque mientras manda no hace nada; reintentar después de una falla usa
  /// el mismo envío (si ya había salido, no se manda otra vez).
  Future<void> send() async {
    final current = state;
    final preview = current.preview;
    if (!current.canSend || preview == null) return;
    final request = MenuSendRequest(
      sendId: preview.sendId,
      email: current.email,
      whatsapp: current.whatsapp,
    );
    // Aunque se cierre la pantalla, la respuesta se espera: la ficha y la
    // reserva tienen que saber que salió.
    final keepAlive = ref.keepAlive();
    _set(current.copyWith(step: MenuSendStep.sending, failure: null));
    try {
      final result = await _repository.send(request);
      await _sent(result, recovered: false, whatsapp: request.whatsapp);
    } on MenuSendFailure catch (failure) {
      if (failure.kind == MenuSendFailureKind.alreadySent) {
        await _recover(preview.sendId, whatsapp: request.whatsapp);
      } else {
        _sendFailed(failure);
      }
    } finally {
      keepAlive.close();
    }
  }

  /// alreadySent: ese envío ya había salido (la respuesta de un intento
  /// anterior se perdió). Se confirma leyendo `menu_sends`.
  Future<void> _recover(String sendId, {required bool whatsapp}) async {
    final chefId = ref.read(currentChefProvider)?.chefId;
    if (chefId == null) {
      _sendFailed(const MenuSendFailure(MenuSendFailureKind.forbidden));
      return;
    }
    final MenuSendRecord? record;
    try {
      record = await _repository.fetchSend(chefId: chefId, sendId: sendId);
    } on MenuSendFailure catch (failure) {
      // No se pudo confirmar: reintentar vuelve a decir alreadySent.
      _sendFailed(failure);
      return;
    }
    if (record == null) {
      _sendFailed(const MenuSendFailure(MenuSendFailureKind.conflict));
      return;
    }
    await _sent(
      MenuSendResult(sentAt: record.sentAt, via: record.via),
      recovered: true,
      whatsapp: whatsapp,
    );
  }

  Future<void> _sent(
    MenuSendResult result, {
    required bool recovered,
    required bool whatsapp,
  }) async {
    if (!ref.mounted) return;
    _refreshSendStatus();
    _refreshQuote(quoteSent: state.quote != null);
    _set(
      state.copyWith(
        step: MenuSendStep.sent,
        result: result,
        failure: null,
        recovered: recovered,
        sentWithWhatsapp: whatsapp,
        whatsAppOpened: null,
      ),
    );
    final link = result.whatsAppLink;
    // En la web, abrir WhatsApp después de esperar la respuesta lo bloquea el
    // navegador: lo abre el botón, con un toque.
    if (link == null || ref.read(isWebProvider)) return;
    final opened = await ref.read(linkLauncherProvider).launch(link);
    _set(state.copyWith(whatsAppOpened: opened));
  }

  void _sendFailed(MenuSendFailure failure) {
    if (!ref.mounted) return;
    _afterFailure(failure);
    // El email salió aunque el envío no quedó registrado: lo que se muestra
    // vuelve a leerse.
    if (failure.emailSent) _refreshSendStatus();
    _set(state.copyWith(step: MenuSendStep.sendFailed, failure: failure));
  }

  /// Si la falla dice que la sesión o el menú cambiaron, la ficha, el editor
  /// y la reserva vuelven a leerlos.
  void _afterFailure(MenuSendFailure failure) {
    switch (failure.kind) {
      case MenuSendFailureKind.sessionNotEditable ||
          MenuSendFailureKind.sessionNotFound ||
          MenuSendFailureKind.sessionWithoutRequest:
        _refreshMenus();
        final detail = sessionDetailProvider(sessionId);
        if (ref.exists(detail)) {
          unawaited(ref.read(detail.notifier).reloadQuietly());
        }
      case MenuSendFailureKind.menuChanged ||
          MenuSendFailureKind.menuEmpty ||
          MenuSendFailureKind.menuNotFound:
        _refreshMenus();
      case MenuSendFailureKind.quoteClosed ||
          MenuSendFailureKind.quoteChanged ||
          MenuSendFailureKind.quoteWeekNotFirst:
        // El presupuesto cambió o se cerró (y con él, quizás, sus semanas):
        // el pedido y la ficha muestran lo de ahora.
        _refreshQuote(quoteSent: false);
        final detail = sessionDetailProvider(sessionId);
        if (ref.exists(detail)) {
          unawaited(ref.read(detail.notifier).reloadQuietly());
        }
      default:
        break;
    }
  }

  /// El presupuesto de los pedidos abiertos se vuelve a leer; si salió con
  /// este envío ([quoteSent]), también el pedido, que pasa a «Presupuesto
  /// enviado».
  void _refreshQuote({required bool quoteSent}) {
    ref.invalidate(requestQuoteProvider);
    final requestId = state.requestId;
    if (quoteSent && requestId != null) {
      unawaited(ref.read(chefInboxProvider.notifier).reload(requestId));
    }
  }

  void _refreshMenus() {
    ref
      ..invalidate(weekMenuSummaryProvider(sessionId))
      ..invalidate(bookingWeekMenusProvider);
    ref.read(weekMenusRevisionProvider.notifier).bump();
  }

  void _refreshSendStatus() {
    ref
      ..invalidate(latestMenuSendProvider(sessionId))
      ..invalidate(bookingWeekMenusProvider);
    ref.read(weekMenusRevisionProvider.notifier).bump();
  }

  /// Abre WhatsApp con el mensaje y el link de lo que salió. Directo desde el
  /// toque (sin esperar nada antes: en la web, el navegador bloquearía la
  /// ventana). false si no hay link o no se pudo abrir.
  Future<bool> openWhatsApp() {
    final link = state.whatsAppLink;
    if (link == null) return Future.value(false);
    return ref.read(linkLauncherProvider).launch(link);
  }
}
