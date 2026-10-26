// Plataforma en la que corre la app.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Versión web (/gestione/): no hay inicio público y el login es la primera
/// pantalla. Los tests lo sobreescriben para probar las dos variantes.
final isWebProvider = Provider<bool>((ref) => kIsWeb);
