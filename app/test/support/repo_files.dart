// Ubica archivos del repo desde los tests sin depender del directorio actual.
// `flutter test` corre con cwd en app/, pero un IDE o un runner puede usar
// otro; por eso se sube por los directorios padre hasta encontrarlo.
import 'dart:convert';
import 'dart:io';

/// Devuelve el archivo [relativePath] (con `/`) buscando desde el directorio
/// actual hacia arriba. Falla con un mensaje claro si no existe.
File findRepoFile(String relativePath) {
  final parts = relativePath.split('/');
  Directory dir = Directory.current.absolute;
  while (true) {
    final candidate = File([dir.path, ...parts].join(Platform.pathSeparator));
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError(
        'No se encontró $relativePath subiendo desde ${Directory.current.path}',
      );
    }
    dir = parent;
  }
}

/// Lee un JSON cuyo nivel superior es un objeto.
Map<String, dynamic> readJsonObject(File file) =>
    jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
