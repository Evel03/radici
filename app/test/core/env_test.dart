import 'package:flutter_test/flutter_test.dart';
import 'package:mestolo/core/env.dart';

void main() {
  test('sin defines: dev sin backend y con aviso', () {
    // flutter test no recibe --dart-define: vale lo por defecto.
    final env = AppEnv.fromDefines();
    expect(env.environment, AppEnvironment.dev);
    expect(env.hasSupabase, isFalse);
    expect(env.showBackendNotice, isTrue);
  });

  test('con URL y clave hay backend y no hay aviso', () {
    final env = AppEnv.parse(
      appEnv: 'dev',
      supabaseUrl: ' https://example.supabase.co ',
      supabasePublishableKey: 'sb_publishable_x',
    );
    expect(env.hasSupabase, isTrue);
    expect(env.supabaseUrl, 'https://example.supabase.co');
    expect(env.showBackendNotice, isFalse);
  });

  test('falta la clave: no hay backend', () {
    final env = AppEnv.parse(
      appEnv: 'dev',
      supabaseUrl: 'https://example.supabase.co',
      supabasePublishableKey: '',
    );
    expect(env.hasSupabase, isFalse);
  });

  test('en prod nunca se muestra el aviso', () {
    final env = AppEnv.parse(
      appEnv: 'prod',
      supabaseUrl: '',
      supabasePublishableKey: '',
    );
    expect(env.environment, AppEnvironment.prod);
    expect(env.showBackendNotice, isFalse);
  });

  test('APP_ENV desconocido es un error', () {
    expect(
      () =>
          AppEnv.parse(appEnv: 'staging', supabaseUrl: '', supabasePublishableKey: ''),
      throwsArgumentError,
    );
  });
}
