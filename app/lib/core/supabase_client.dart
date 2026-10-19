// Acceso al cliente de Supabase para los repositorios. Ningún widget lo usa:
// los widgets leen providers de la capa de aplicación.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mestolo/core/env.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Cliente de Supabase, o null si la app se compiló sin backend (main.dart
/// solo inicializa Supabase cuando hay URL y clave).
final supabaseClientProvider = Provider<SupabaseClient?>((ref) {
  final env = ref.watch(appEnvProvider);
  return env.hasSupabase ? Supabase.instance.client : null;
});
