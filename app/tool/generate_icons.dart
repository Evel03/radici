// Genera los íconos de Radici con la marca (la R de Cinzel en crema sobre
// oliva, de la fuente que usa la app; ver lib/core/brand.dart): favicon e
// íconos de la web /gestione/, íconos de Android (mipmap-*/ic_launcher.png) y
// de iOS (AppIcon.appiconset). Mismos nombres y tamaños que la plantilla de
// Flutter: no toca nada más de los proyectos nativos.
//
// Uso, desde app/:   dart run tool/generate_icons.dart
//
// test/tool/app_icons_test.dart falla si los PNG del repo no son los que
// genera este script: después de cambiar la marca, la fuente o la lista,
// volver a correrlo.
import 'dart:io';

import 'icons/icon_renderer.dart';

void main() {
  if (!File('pubspec.yaml').existsSync() || !Directory('web').existsSync()) {
    stderr.writeln('Correr desde app/: dart run tool/generate_icons.dart');
    exitCode = 64;
    return;
  }
  final mark = MarkOutline.load();
  for (final spec in appIcons) {
    final file = File(spec.path);
    if (!file.parent.existsSync()) {
      stderr.writeln('No existe la carpeta de ${spec.path}');
      exitCode = 1;
      return;
    }
    file.writeAsBytesSync(encodeIcon(spec, mark));
    stdout.writeln('${spec.path} (${spec.size}×${spec.size})');
  }
}
