// Traducción automática de un plato en la Edge Function `chef` (contrato
// docs/contracts/chef-api.md §12): POST chef/translate con el nombre y la
// descripción en español devuelve el italiano y el inglés, enteros o nada.
//
// Como pide el contrato §2: el SDK manda la sesión de quien entró (Evelyn o
// un colaborador suyo) en `Authorization: Bearer <token>` y la clave
// publicable en `apikey`; la región va en la URL
// (`?forceFunctionRegion=eu-central-1`, Frankfurt), nunca en la cabecera
// `x-region`, que el preflight de CORS no permite. Ante un 401 renueva la
// sesión una vez y reintenta una vez (el SDK lee el token en cada pedido).
//
// A Anthropic solo va el nombre y la descripción del plato (SPEC §6). Nada se
// loguea: ni el texto del plato ni el detalle de un error, que se traduce a
// [TranslationFailure] (solo el tipo).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/supabase_client.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_translation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract interface class TranslationRepository {
  /// Traduce [spanish] al italiano y al inglés. La descripción vuelve si y
  /// solo si se mandó. Lanza [TranslationFailure].
  Future<RecipeTranslation> translate(SpanishText spanish);
}

final translationRepositoryProvider = Provider<TranslationRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null
      ? const _NoBackendTranslationRepository()
      : SupabaseTranslationRepository(client);
});

enum TranslationFailureKind {
  /// 503 (Claude no respondió a tiempo, un error pasajero o la base que no
  /// respondió), un 5xx pasajero de la plataforma (502, 504) o la función
  /// sin desplegar. Se puede reintentar.
  unavailable,

  /// Sin conexión: el pedido no salió. Se puede reintentar.
  offline,

  /// No respondió en [SupabaseTranslationRepository.timeout]. Se puede
  /// reintentar.
  timeout,

  /// 422: Claude no lo tradujo (se negó, la salida no valió o se cortó).
  /// Reintentar lo mismo no sirve: se escribe a mano.
  untranslatable,

  /// 501: la traducción está apagada (sin `ANTHROPIC_API_KEY`). Se escribe a
  /// mano.
  notConfigured,

  /// 429: la cocina pasó su límite de traducciones. La app nunca reintenta
  /// sola (el intento rechazado también cuenta).
  rateLimited,

  /// 401 también después de renovar la sesión (o la sesión no se pudo
  /// renovar): hay que volver a entrar.
  unauthorized,

  /// 403: el usuario no es la cocinera ni un colaborador suyo.
  forbidden,

  /// 500: algo roto o mal configurado del lado del servidor (una clave de
  /// Anthropic inválida, el SDK que no carga); también un 200 con otra forma
  /// o un error inesperado de la app. Reintentar no lo arregla.
  server,

  /// 400 y los otros 4xx: un cuerpo que la app no debería mandar.
  invalid;

  /// Probar de nuevo puede andar: la falla es de la red o del momento.
  bool get canRetry =>
      this == unavailable || this == offline || this == timeout;
}

class TranslationFailure implements Exception {
  const TranslationFailure(this.kind);

  final TranslationFailureKind kind;

  /// Solo el tipo: nunca el texto del plato.
  @override
  String toString() => 'TranslationFailure(${kind.name})';
}

class SupabaseTranslationRepository implements TranslationRepository {
  SupabaseTranslationRepository(
    this._client, {
    this.timeout = translateTimeout,
  });

  final SupabaseClient _client;

  /// Cuánto se espera la respuesta antes de darla por perdida.
  final Duration timeout;

  /// La función y su ruta (functions.invoke arma
  /// `<url>/functions/v1/chef/translate`).
  static const String translateFunction = 'chef/translate';

  /// Frankfurt, como public-request (contrato public-request §2).
  static const String functionRegion = 'eu-central-1';

  /// La función corta a los 40 s (contrato §12); el resto es el margen para
  /// la sesión, el arranque de la función y la red.
  static const Duration translateTimeout = Duration(seconds: 60);

  @override
  Future<RecipeTranslation> translate(SpanishText spanish) async {
    try {
      return await _translateOnce(spanish);
    } on TranslationFailure catch (failure) {
      if (failure.kind != TranslationFailureKind.unauthorized) rethrow;
    }
    // 401: el token venció o la sesión se renovó en otro lado. Una sola
    // renovación y un solo reintento; si no alcanza, hay que volver a entrar.
    try {
      await _client.auth.refreshSession();
    } on Object {
      throw const TranslationFailure(TranslationFailureKind.unauthorized);
    }
    return _translateOnce(spanish);
  }

  Future<RecipeTranslation> _translateOnce(SpanishText spanish) async {
    final FunctionResponse response;
    try {
      response = await _client.functions
          .invoke(
            translateFunction,
            body: {'name': spanish.name, 'description': spanish.description},
            // Solo el parámetro: `region:` también mandaría x-region.
            queryParameters: const {'forceFunctionRegion': functionRegion},
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const TranslationFailure(TranslationFailureKind.timeout);
    } on FunctionsFetchException catch (error) {
      // El pedido no salió. Un Error (de programación, no de la red) que el
      // SDK envolvió no se esconde como falla de red.
      throw TranslationFailure(
        error.details is Error
            ? TranslationFailureKind.server
            : TranslationFailureKind.offline,
      );
    } on FunctionsHttpException catch (error) {
      throw translationFailureFromResponse(error.status, error.details);
    } on FunctionsRelayException catch (error) {
      // El relay de la plataforma no llegó a la función: su estado dice si es
      // pasajero (502, 503, 504) o no (500).
      throw translationFailureFromResponse(error.status, null);
    } on Object {
      // Otra cosa (un error de la app, el SDK de Auth): no es la red, y
      // reintentar no la arregla.
      throw const TranslationFailure(TranslationFailureKind.server);
    }
    try {
      return translationFromResponse(
        response.data,
        withDescription: spanish.description != null,
      );
    } on Object {
      // Un 200 con otra forma (FormatException) o un dato que rompe la
      // lectura: la función no cumple el contrato, no es pasajero.
      throw const TranslationFailure(TranslationFailureKind.server);
    }
  }
}

/// Traduce una respuesta de error de la función (contrato §3 y §12) a
/// [TranslationFailure]. Del cuerpo solo se mira el código.
TranslationFailure translationFailureFromResponse(int status, Object? body) {
  final error = body is Map ? body['error'] : null;
  final kind = switch (status) {
    401 => TranslationFailureKind.unauthorized,
    403 => TranslationFailureKind.forbidden,
    // Sin el código de la función, el 429 es de la plataforma: se puede
    // reintentar.
    429 when error == 'rateLimited' => TranslationFailureKind.rateLimited,
    422 when error == 'untranslatable' => TranslationFailureKind.untranslatable,
    501 when error == 'notConfigured' => TranslationFailureKind.notConfigured,
    // La función sin desplegar (404 de la plataforma) o desplegada antes de
    // /translate (notFound): se puede reintentar más tarde.
    404 || 429 => TranslationFailureKind.unavailable,
    >= 400 && < 500 => TranslationFailureKind.invalid,
    // 500 `server` (o un 501 sin su código): roto, no pasajero.
    500 || 501 => TranslationFailureKind.server,
    // 503 y los 5xx de la plataforma (502, 504…): pasajeros.
    _ => TranslationFailureKind.unavailable,
  };
  return TranslationFailure(kind);
}

/// La respuesta 200: `it` y `en`, cada uno con `name` y `description` (null si
/// y solo si no se mandó, [withDescription]). Todo o nada: con otra forma, un
/// texto vacío o pasado de largo, [FormatException]. Los textos quedan como
/// los guarda la base ([normalizeRecipeText]).
RecipeTranslation translationFromResponse(
  Object? data, {
  required bool withDescription,
}) {
  TranslatedText language(Object? value) {
    if (value is! Map) throw const FormatException('Idioma inválido');
    final name = value['name'];
    final description = value['description'];
    if (name is! String) throw const FormatException('Nombre inválido');
    final cleanName = normalizeRecipeText(name);
    if (cleanName.isEmpty || textLength(cleanName) > maxRecipeNameLength) {
      throw const FormatException('Nombre inválido');
    }
    if (!withDescription) {
      if (description != null) {
        throw const FormatException('Descripción que no se pidió');
      }
      return (name: cleanName, description: null);
    }
    if (description is! String) {
      throw const FormatException('Descripción inválida');
    }
    final cleanDescription = normalizeRecipeText(description);
    if (cleanDescription.isEmpty ||
        textLength(cleanDescription) > maxRecipeDescriptionLength) {
      throw const FormatException('Descripción inválida');
    }
    return (name: cleanName, description: cleanDescription);
  }

  if (data is! Map) throw const FormatException('Respuesta inválida');
  return (it: language(data['it']), en: language(data['en']));
}

class _NoBackendTranslationRepository implements TranslationRepository {
  const _NoBackendTranslationRepository();

  @override
  Future<RecipeTranslation> translate(SpanishText spanish) => Future.error(
    const TranslationFailure(TranslationFailureKind.unavailable),
  );
}
