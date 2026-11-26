// deploy-web.yml y la app coinciden en el id del build: el --dart-define que
// lee core/build_id.dart y el build.json que lee features/web_app (si no, la
// app nunca avisaría de una versión nueva). Y producción comprueba, después
// de publicar, que /gestione/ llegue sin caché.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/build_id.dart';
import 'package:radici/features/web_app/domain/published_build.dart';

import '../support/repo_files.dart';

void main() {
  final workflow = findRepoFile('.github/workflows/deploy-web.yml')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  /// El bloque de un paso: desde su "- name:" hasta el paso siguiente.
  String step(String name) {
    final start = workflow.indexOf('- name: $name\n');
    expect(start, isNot(-1), reason: 'no está el paso "$name"');
    final next = workflow.indexOf('\n      - ', start + 1);
    return workflow.substring(start, next == -1 ? null : next);
  }

  String? condition(String block) => block
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.startsWith('if:'))
      .firstOrNull;

  test('un id por deploy, el del commit que se publica, en producción y en las vistas previas', () {
    final id = step('App - id del build');
    expect(id, contains('github.event.pull_request.head.sha || github.sha'));
    expect(id, contains(r'echo "BUILD_ID=${build_id}" >> "${GITHUB_ENV}"'));
    expect(condition(id), isNull, reason: 'corre en todos los deploys');
  });

  test('la app se compila con ese id: la misma línea para producción y vista previa', () {
    // Con las líneas que siguen a una barra invertida, unidas.
    final build = step('App - build web para /gestione/')
        .replaceAll(RegExp(r'\\\n\s*'), ' ');
    final commands = build
        .split('\n')
        .where((line) => line.contains('flutter build web'))
        .toList();
    expect(commands, hasLength(1));
    expect(
      commands.single,
      contains('"--dart-define=$buildIdDefine=\${BUILD_ID}"'),
    );
  });

  test('publica build.json con el mismo id en las dos entradas, en la clave que lee la app', () {
    // El paso corre el script, con sus tests en el npm test de la raíz
    // (.github/scripts/publish-app-entries.test.ts).
    const script = '.github/scripts/publish-app-entries.sh';
    final copy = step('Copiar /gestione/ y /app/ al sitio');
    expect(copy, contains('run: bash "\${GITHUB_WORKSPACE}/$script"'));
    expect('- "$script"'.allMatches(workflow), hasLength(1));
    final publisher = findRepoFile(script).readAsStringSync();
    expect(
      publisher,
      contains(
        'printf \'{"$publishedBuildIdKey":"%s"}\\n\' "\${build_id}" > '
        '"\${out}/$publishedBuildFile"',
      ),
    );
    // Y comprueba que el id quedó compilado en main.dart.js.
    expect(
      publisher,
      contains(r'grep -qF "\"${build_id}\"" "${out}/main.dart.js"'),
    );
    // Un solo build de la app para las dos entradas: el script cambia la base y el meta de /app/.
    expect('flutter build web'.allMatches(workflow).length, 1);
    expect(publisher, contains('copy_build "\${dist}/gestione"'));
    expect(publisher, contains('copy_build "\${dist}/app"'));
    // Cada entrada con su meta, nunca cruzadas.
    expect(publisher, contains('<meta name="radici-entry" content="app">'));
    expect(publisher, contains('check_entry "\${dist}/gestione" gestione app'));
    expect(publisher, contains('check_entry "\${dist}/app" app gestione'));
  });

  test('producción, después de publicar: /gestione/ y /app/ tienen que llegar con no-cache', () {
    const name = 'Comprobar la caché de /gestione/ y /app/ en el dominio';
    const script = '.github/scripts/check-gestione-cache.sh';
    expect(
      workflow.indexOf('- name: $name'),
      greaterThan(workflow.indexOf('- name: Publicar\n')),
    );
    final check = step(name);
    final runIf = condition(check)!;
    expect(runIf, contains("github.event_name != 'pull_request'"));
    expect(runIf, contains("github.ref_name == 'main'"));
    // El script, con sus tests en el npm test de la raíz
    // (.github/scripts/check-gestione-cache.test.ts).
    expect(check, contains('run: bash "\${GITHUB_WORKSPACE}/$script"'));
    final checker = findRepoFile(script).readAsStringSync();
    expect(
      checker,
      contains(
        'gestione/main.dart.js gestione/flutter_bootstrap.js '
        'app/main.dart.js app/flutter_bootstrap.js',
      ),
    );
    // Un cambio solo en el script también dispara el workflow (el push a main).
    expect('- "$script"'.allMatches(workflow), hasLength(1));
  });

  test('los pull requests no lo disparan: solo main y la ejecución manual', () {
    final start = workflow.indexOf('\non:\n');
    final on = workflow.substring(start, workflow.indexOf('\nconcurrency:'));
    expect(on, contains('branches: [main]'));
    expect(on, contains('workflow_dispatch:'));
    expect(on, isNot(contains('pull_request')));
  });
}
