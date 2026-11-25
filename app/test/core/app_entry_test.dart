// Las dos entradas de la app (/gestione/ y /app/): cuál es cada una y que no
// se pisan la sesión, el verificador PKCE ni el idioma, aunque comparten el
// origen (localStorage). Y que /gestione/ conserva las claves de siempre: así
// la sesión de Evelyn sobrevive a la actualización.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/app_entry.dart';
import 'package:radici/core/app_language.dart';
import 'package:radici/core/auth_options.dart';
import 'package:radici/features/settings/data/language_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/browser_fakes.dart';
import '../support/repo_files.dart';

const _url = 'https://abcdefgh.supabase.co';

/// Almacenamiento del verificador en memoria (el real es SharedPreferences).
class _MemoryStorage extends GotrueAsyncStorage {
  final Map<String, String> items = {};

  @override
  Future<String?> getItem({required String key}) async => items[key];

  @override
  Future<void> setItem({required String key, required String value}) async =>
      items[key] = value;

  @override
  Future<void> removeItem({required String key}) async => items.remove(key);
}

void main() {
  group('qué entrada es', () {
    test(
      'nativo (iOS y Android): siempre la clienta, diga lo que diga la marca',
      () {
        for (final meta in [null, 'gestione', 'app', 'otra']) {
          expect(
            resolveAppEntry(isWeb: false, metaContent: meta),
            AppEntry.client,
            reason: '$meta',
          );
        }
      },
    );

    test(
      'web: la marca del index.html; sin marca o desconocida, la cocina',
      () {
        expect(
          resolveAppEntry(isWeb: true, metaContent: 'app'),
          AppEntry.client,
        );
        expect(
          resolveAppEntry(isWeb: true, metaContent: ' app '),
          AppEntry.client,
        );
        expect(
          resolveAppEntry(isWeb: true, metaContent: 'gestione'),
          AppEntry.kitchen,
        );
        expect(resolveAppEntry(isWeb: true), AppEntry.kitchen);
        expect(resolveAppEntry(isWeb: true, metaContent: ''), AppEntry.kitchen);
        expect(
          resolveAppEntry(isWeb: true, metaContent: 'App2'),
          AppEntry.kitchen,
        );
      },
    );

    test('la marca se lee de la página por su nombre', () {
      final browser = FakeBrowser()..metas[entryMetaName] = 'app';
      expect(entryMetaName, 'radici-entry');
      expect(
        resolveAppEntry(
          isWeb: true,
          metaContent: browser.readMeta(entryMetaName),
        ),
        AppEntry.client,
      );
      expect(FakeBrowser().readMeta(entryMetaName), isNull);
    });

    test('el index.html actual (/gestione/) declara la cocina', () {
      final html = findRepoFile('app/web/index.html').readAsStringSync();
      expect(html, contains('<meta name="radici-entry" content="gestione">'));
      expect(AppEntry.kitchen.metaValue, 'gestione');
      expect(AppEntry.client.metaValue, 'app');
    });
  });

  group('claves de cada entrada', () {
    test(
      '/gestione/ conserva las de siempre (Evelyn no sale de su sesión)',
      () {
        // La de supabase_flutter 2.18.3 por defecto: "sb-<ref>-auth-token".
        final defaultKey =
            'sb-${Uri.parse(_url).host.split(".").first}-auth-token';
        expect(AppEntry.kitchen.persistSessionKey(_url), defaultKey);
        expect(
          AppEntry.kitchen.persistSessionKey(_url),
          'sb-abcdefgh-auth-token',
        );
        // El idioma, la clave que ya usaba SharedPreferencesLanguageCache.
        expect(AppEntry.kitchen.languageKey, 'radici.ui_language');
        expect(SharedPreferencesLanguageCache.key, 'radici.ui_language');
        // El verificador PKCE: sin prefijo (la clave fija de gotrue).
        expect(AppEntry.kitchen.pkceKeyPrefix, '');
      },
    );

    test('/app/ tiene las suyas, distintas de las de la cocina', () {
      expect(
        AppEntry.client.persistSessionKey(_url),
        'sb-abcdefgh-app-auth-token',
      );
      expect(AppEntry.client.languageKey, 'radici.app.ui_language');
      expect(AppEntry.client.pkceKeyPrefix, 'radici.app.');
      expect(
        AppEntry.client.persistSessionKey(_url),
        isNot(AppEntry.kitchen.persistSessionKey(_url)),
      );
      expect(AppEntry.client.languageKey, isNot(AppEntry.kitchen.languageKey));
    });
  });

  group('opciones de Auth', () {
    test('cocina: claves de siempre, PKCE y sin detectar sesión en la URL', () {
      final options = buildAuthOptions(AppEntry.kitchen, _url);
      expect(options.authFlowType, AuthFlowType.pkce);
      expect(options.detectSessionInUri, isFalse);
      expect(options.detectSessionInUriPredicate, isNull);
      expect(
        (options.localStorage! as SharedPreferencesLocalStorage)
            .persistSessionKey,
        'sb-abcdefgh-auth-token',
      );
      // Sin almacenamiento propio del verificador: queda el de
      // supabase_flutter, con la clave fija de siempre.
      expect(options.pkceAsyncStorage, isNull);
    });

    test('clienta: claves propias, PKCE y el predicado de su ruta', () {
      final options = buildAuthOptions(
        AppEntry.client,
        _url,
        pkceStorage: _MemoryStorage(),
      );
      expect(options.authFlowType, AuthFlowType.pkce);
      expect(options.detectSessionInUri, isTrue);
      expect(options.detectSessionInUriPredicate, isNotNull);
      expect(
        options.detectSessionInUriPredicate!(
          Uri.parse('https://radicicucina.app/app/?code=abc'),
        ),
        isTrue,
      );
      expect(
        options.detectSessionInUriPredicate!(
          Uri.parse('https://radicicucina.app/gestione/?code=abc'),
        ),
        isFalse,
      );
      expect(
        (options.localStorage! as SharedPreferencesLocalStorage)
            .persistSessionKey,
        'sb-abcdefgh-app-auth-token',
      );
      expect(options.pkceAsyncStorage, isA<PrefixedGotrueAsyncStorage>());
    });
  });

  group('las dos entradas no se pisan (mismo origen, mismo localStorage)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('la sesión guardada', () async {
      final kitchen = buildAuthOptions(AppEntry.kitchen, _url).localStorage!;
      final client = buildAuthOptions(AppEntry.client, _url).localStorage!;
      await kitchen.initialize();
      await client.initialize();

      await kitchen.persistSession('sesion-cocina');
      expect(await client.hasAccessToken(), isFalse);

      await client.persistSession('sesion-clienta');
      expect(await kitchen.accessToken(), 'sesion-cocina');
      expect(await client.accessToken(), 'sesion-clienta');

      // Salir de una no cierra la otra.
      await client.removePersistedSession();
      expect(await kitchen.accessToken(), 'sesion-cocina');
      expect(await client.hasAccessToken(), isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {'sb-abcdefgh-auth-token'});
    });

    test(
      'el verificador PKCE de gotrue (clave fija) va con prefijo en /app/',
      () async {
        final shared = _MemoryStorage();
        final kitchen = buildAuthOptions(
          AppEntry.kitchen,
          _url,
          pkceStorage: shared,
        ).pkceAsyncStorage!;
        final client = buildAuthOptions(
          AppEntry.client,
          _url,
          pkceStorage: shared,
        ).pkceAsyncStorage!;

        // Lo que hace gotrue 2.27.3 al empezar un flujo PKCE: guardar el
        // verificador con una clave fija (`supabase.auth.token-code-verifier`).
        final cocina = GoTrueClient(
          url: '$_url/auth/v1',
          asyncStorage: kitchen,
        );
        await cocina.getOAuthSignInUrl(provider: OAuthProvider.google);
        expect(shared.items.keys, ['supabase.auth.token-code-verifier']);
        final verificadorCocina =
            shared.items['supabase.auth.token-code-verifier'];

        final clienta = GoTrueClient(
          url: '$_url/auth/v1',
          asyncStorage: client,
        );
        await clienta.getOAuthSignInUrl(provider: OAuthProvider.google);
        // El de la cocina sigue intacto; el de la clienta, aparte.
        expect(shared.items, hasLength(2));
        expect(
          shared.items['supabase.auth.token-code-verifier'],
          verificadorCocina,
        );
        expect(
          shared.items['radici.app.supabase.auth.token-code-verifier'],
          isNotNull,
        );
        expect(
          shared.items['radici.app.supabase.auth.token-code-verifier'],
          isNot(verificadorCocina),
        );

        // Salir de la clienta borra solo su verificador.
        await clienta.signOut();
        expect(shared.items.keys, ['supabase.auth.token-code-verifier']);
      },
    );

    test('el prefijo cubre getItem, setItem y removeItem', () async {
      final inner = _MemoryStorage();
      final prefixed = PrefixedGotrueAsyncStorage('p.', inner);
      await prefixed.setItem(key: 'k', value: 'v');
      expect(inner.items, {'p.k': 'v'});
      expect(await prefixed.getItem(key: 'k'), 'v');
      expect(await inner.getItem(key: 'k'), isNull);
      await prefixed.removeItem(key: 'k');
      expect(inner.items, isEmpty);
    });

    test('el idioma', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final kitchen = await SharedPreferencesLanguageCache.load(
        key: AppEntry.kitchen.languageKey,
      );
      final client = await SharedPreferencesLanguageCache.load(
        key: AppEntry.client.languageKey,
      );
      await kitchen.write((userId: 'chef', language: AppLanguage.es));
      expect(client.read(), isNull);

      await client.write((userId: 'cliente', language: AppLanguage.en));
      expect(kitchen.read(), (userId: 'chef', language: AppLanguage.es));
      expect(client.read(), (userId: 'cliente', language: AppLanguage.en));

      await client.clear();
      expect(kitchen.read(), (userId: 'chef', language: AppLanguage.es));
      expect(client.read(), isNull);

      // Lo que ya tenía Evelyn guardado con la clave de siempre se sigue
      // leyendo sin pasar la clave.
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
            'radici.ui_language': 'es:chef-1',
          });
      expect((await SharedPreferencesLanguageCache.load()).read(), (
        userId: 'chef-1',
        language: AppLanguage.es,
      ));
    });
  });

  group('links de Auth', () {
    bool client(String url) =>
        isAuthCallbackUri(AppEntry.client, Uri.parse(url));
    bool kitchen(String url) =>
        isAuthCallbackUri(AppEntry.kitchen, Uri.parse(url));

    test(
      'la clienta acepta solo su ruta (/app/) y PKCE (`code`) o un error',
      () {
        expect(client('https://radicicucina.app/app/?code=abc'), isTrue);
        expect(client('https://radicicucina.app/app?code=abc'), isTrue);
        expect(client('https://radicicucina.app/app/accesso?code=abc'), isTrue);
        expect(
          client(
            'https://radicicucina.app/app/#error=access_denied&error_code=otp_expired&error_description=x',
          ),
          isTrue,
        );
        expect(
          client('https://radicicucina.app/app/?error_code=otp_expired'),
          isTrue,
        );
      },
    );

    test('otra ruta no abre sesión', () {
      expect(client('https://radicicucina.app/gestione/?code=abc'), isFalse);
      expect(client('https://radicicucina.app/?code=abc'), isFalse);
      expect(client('https://radicicucina.app/application/?code=abc'), isFalse);
      expect(client('https://radicicucina.app/captcha/?code=abc'), isFalse);
    });

    test('una URL o un deep link con access_token no abre sesión', () {
      for (final url in [
        'https://radicicucina.app/app/#access_token=x&refresh_token=y&expires_in=3600&token_type=bearer',
        'https://radicicucina.app/app/?access_token=x&refresh_token=y',
        'https://radicicucina.app/app/#access_token=x',
        'https://radicicucina.app/app/?code=abc#access_token=x',
        'https://radicicucina.app/app/?refresh_token=y',
        'app.radicicucina:///app/#access_token=x&refresh_token=y',
      ]) {
        expect(client(url), isFalse, reason: url);
      }
    });

    test('sin parámetros de Auth no hay nada que abrir', () {
      expect(client('https://radicicucina.app/app/'), isFalse);
      expect(client('https://radicicucina.app/app/#/area'), isFalse);
      expect(client('https://radicicucina.app/app/?utm=x'), isFalse);
    });

    test('la cocina (login con código) nunca abre sesión con una URL', () {
      for (final url in [
        'https://radicicucina.app/gestione/?code=abc',
        'https://radicicucina.app/app/?code=abc',
        'https://radicicucina.app/gestione/#access_token=x&refresh_token=y',
        'https://radicicucina.app/gestione/#error=access_denied',
      ]) {
        expect(kitchen(url), isFalse, reason: url);
      }
    });
  });
}
