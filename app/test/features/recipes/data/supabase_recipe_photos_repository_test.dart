// Fotos de los platos contra un servidor HTTP simulado, con las consultas
// reales del SDK: las URL públicas, la subida de los dos archivos (JPEG, una
// semana de caché, sin pisar), set_recipe_photo, la limpieza de la carpeta del
// plato, los errores y los plazos.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:radici/features/recipes/data/recipe_photos_repository.dart';
import 'package:radici/features/recipes/domain/recipe_photo.dart';

import '../../../support/recipe_fixtures.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/supabase_http_fake.dart';

const String _photoId = 'f0000000-0000-4000-8000-000000000001';
const String _oldPhotoId = 'f0000000-0000-4000-8000-000000000002';

final NewRecipePhoto _photo = NewRecipePhoto(
  photoId: _photoId,
  photo: ProcessedRecipePhoto(
    full: Uint8List.fromList([0xff, 0xd8, 0xff, 1, 2, 3]),
    thumb: Uint8List.fromList([0xff, 0xd8, 0xff, 4]),
  ),
);

Matcher _failure(RecipePhotoFailureKind kind) =>
    throwsA(isA<RecipePhotoFailure>().having((f) => f.kind, 'kind', kind));

http.Response _storageError(int status, String statusCode, String error) =>
    jsonResponse({
      'statusCode': statusCode,
      'error': error,
      'message': 'mensaje del servidor',
    }, status: status);

http.Response _postgrestError(String code, {int status = 400}) => jsonResponse({
  'code': code,
  'message': 'error',
  'details': 'rutas',
  'hint': null,
}, status: status);

void main() {
  late FakeSupabaseHttp server;
  late SupabaseRecipePhotosRepository repository;
  const base = '/storage/v1/object/recipe-photos/$testChefId/$lasagneId';

  setUp(() {
    server = FakeSupabaseHttp(
      (request) async => jsonResponse({'Key': 'recipe-photos/x', 'Id': 'id'}),
    );
    repository = SupabaseRecipePhotosRepository(server.client);
  });

  tearDown(() => server.dispose());

  test('publicUrl: la URL pública del archivo, la grande o la miniatura', () {
    expect(
      repository.publicUrl(
        chefId: testChefId,
        recipeId: lasagneId,
        photoId: _photoId,
      ),
      '$fakeSupabaseUrl/storage/v1/object/public/recipe-photos/'
      '$testChefId/$lasagneId/$_photoId.jpg',
    );
    expect(
      repository.publicUrl(
        chefId: testChefId,
        recipeId: lasagneId,
        photoId: _photoId,
        thumb: true,
      ),
      '$fakeSupabaseUrl/storage/v1/object/public/recipe-photos/'
      '$testChefId/$lasagneId/$_photoId-thumb.jpg',
    );
  });

  group('upload', () {
    test('sube los dos archivos a la carpeta del plato: JPEG, una semana de caché y sin pisar', () async {
      await repository.upload(
        chefId: testChefId,
        recipeId: lasagneId,
        photo: _photo,
      );

      expect(server.requests.map((r) => '${r.method} ${r.url.path}').toSet(), {
        'POST $base/$_photoId.jpg',
        'POST $base/$_photoId-thumb.jpg',
      });
      for (final request in server.requests) {
        expect(request.headers['x-upsert'], 'false', reason: 'nunca pisa');
        final body = latin1.decode(request.bodyBytes).toLowerCase();
        expect(body, contains('content-type: image/jpeg'));
        expect(body, contains('name="cachecontrol"\r\n\r\n604800\r\n'));
      }
      final full = server.requests.firstWhere(
        (r) => r.url.path.endsWith('$_photoId.jpg'),
      );
      expect(
        latin1.decode(full.bodyBytes),
        contains(latin1.decode(_photo.photo.full)),
      );
    });

    // Un reintento después de una respuesta perdida: los archivos ya están y
    // son los mismos (el uuid es nuevo en cada foto).
    test('un archivo que ya está (409 Duplicate, o 400 con 409 adentro) cuenta como subido', () async {
      server.handler = (request) async =>
          request.url.path.endsWith('-thumb.jpg')
          ? _storageError(400, '409', 'Duplicate')
          : _storageError(409, '409', 'Duplicate');
      await repository.upload(
        chefId: testChefId,
        recipeId: lasagneId,
        photo: _photo,
      );
      expect(server.requests, hasLength(2));
    });

    test('sin conexión o un 5xx → unavailable; un 4xx de permisos, tamaño o tipo → rejected', () async {
      server.handler = (_) async => throw http.ClientException('sin red');
      await expectLater(
        repository.upload(
          chefId: testChefId,
          recipeId: lasagneId,
          photo: _photo,
        ),
        _failure(RecipePhotoFailureKind.unavailable),
      );

      server.handler = (_) async => _storageError(500, '500', 'internal');
      await expectLater(
        repository.upload(
          chefId: testChefId,
          recipeId: lasagneId,
          photo: _photo,
        ),
        _failure(RecipePhotoFailureKind.unavailable),
      );

      for (final (status, code) in [(400, '403'), (413, '413'), (400, '415')]) {
        server.handler = (request) async =>
            request.url.path.endsWith('-thumb.jpg')
            ? jsonResponse({'Key': 'k'})
            : _storageError(status, code, 'Unauthorized');
        await expectLater(
          repository.upload(
            chefId: testChefId,
            recipeId: lasagneId,
            photo: _photo,
          ),
          _failure(RecipePhotoFailureKind.rejected),
          reason: code,
        );
      }
    });
  });

  group('setPhoto', () {
    test('llama a set_recipe_photo con el plato y la foto, y devuelve la que dejó de usarse', () async {
      server.handler = (_) async => jsonResponse(_oldPhotoId);

      final previous = await repository.setPhoto(
        recipeId: lasagneId,
        photoId: _photoId,
      );

      expect(previous, _oldPhotoId);
      final request = server.last;
      expect(request.method, 'POST');
      expect(request.url.path, '/rest/v1/rpc/set_recipe_photo');
      expect(jsonBodyOf(request), {
        'p_recipe_id': lasagneId,
        'p_photo_id': _photoId,
      });
    });

    test(
      'sacar la foto es p_photo_id null; sin foto anterior devuelve null',
      () async {
        server.handler = (_) async => jsonResponse(null);
        expect(await repository.setPhoto(recipeId: lasagneId), isNull);
        expect(jsonBodyOf(server.last), {
          'p_recipe_id': lasagneId,
          'p_photo_id': null,
        });
      },
    );

    test('los errores de la base y de la red', () async {
      for (final (code, kind) in [
        ('P0002', RecipePhotoFailureKind.notFound),
        ('22023', RecipePhotoFailureKind.rejected),
        ('42501', RecipePhotoFailureKind.rejected),
      ]) {
        server.handler = (_) async => _postgrestError(code);
        await expectLater(
          repository.setPhoto(recipeId: lasagneId, photoId: _photoId),
          _failure(kind),
          reason: code,
        );
      }
      server.handler = (_) async => _postgrestError('XX000', status: 500);
      await expectLater(
        repository.setPhoto(recipeId: lasagneId, photoId: _photoId),
        _failure(RecipePhotoFailureKind.unavailable),
      );
      server.handler = (_) async => throw http.ClientException('sin red');
      await expectLater(
        repository.setPhoto(recipeId: lasagneId, photoId: _photoId),
        _failure(RecipePhotoFailureKind.unavailable),
      );
    });
  });

  group('deleteAllExcept', () {
    const abandoned = 'f0000000-0000-4000-8000-000000000003';
    final folderFiles = [
      {'name': '$_photoId.jpg', 'id': 'o1'},
      {'name': '$_photoId-thumb.jpg', 'id': 'o2'},
      {'name': '$_oldPhotoId.jpg', 'id': 'o3'},
      {'name': '$_oldPhotoId-thumb.jpg', 'id': 'o4'},
      // Un intento abandonado (subió solo la grande).
      {'name': '$abandoned.jpg', 'id': 'o5'},
      // Sin id es una carpeta: no se toca.
      {'name': 'carpeta', 'id': null},
    ];

    test('lista la carpeta del plato y borra, en un pedido, todo lo que no sea la foto que queda', () async {
      server.handler = (request) async => request.method == 'POST'
          ? jsonResponse(folderFiles)
          : jsonResponse(<Object>[]);

      await repository.deleteAllExcept(
        chefId: testChefId,
        recipeId: lasagneId,
        keepPhotoId: _photoId,
      );

      final [list, remove] = server.requests;
      expect(list.method, 'POST');
      expect(list.url.path, '/storage/v1/object/list/recipe-photos');
      expect(
        jsonBodyOf(list),
        containsPair('prefix', '$testChefId/$lasagneId'),
      );
      expect(jsonBodyOf(list), containsPair('limit', 1000));
      expect(remove.method, 'DELETE');
      expect(remove.url.path, '/storage/v1/object/recipe-photos');
      expect(jsonBodyOf(remove), {
        'prefixes': [
          '$testChefId/$lasagneId/$_oldPhotoId.jpg',
          '$testChefId/$lasagneId/$_oldPhotoId-thumb.jpg',
          '$testChefId/$lasagneId/$abandoned.jpg',
        ],
      });
    });

    test('sin foto que quede (la sacó), borra todo', () async {
      server.handler = (request) async => request.method == 'POST'
          ? jsonResponse(folderFiles)
          : jsonResponse(<Object>[]);

      await repository.deleteAllExcept(chefId: testChefId, recipeId: lasagneId);

      expect(jsonBodyOf(server.last)['prefixes'], hasLength(5));
    });

    test('si no sobra nada no borra; si falla el listado o el borrado → unavailable', () async {
      server.handler = (_) async => jsonResponse(folderFiles.sublist(0, 2));
      await repository.deleteAllExcept(
        chefId: testChefId,
        recipeId: lasagneId,
        keepPhotoId: _photoId,
      );
      expect(server.requests.map((r) => r.method), ['POST']);

      server.handler = (_) async => _storageError(500, '500', 'internal');
      await expectLater(
        repository.deleteAllExcept(chefId: testChefId, recipeId: lasagneId),
        _failure(RecipePhotoFailureKind.unavailable),
      );

      server.handler = (request) async => request.method == 'POST'
          ? jsonResponse(folderFiles)
          : _storageError(500, '500', 'internal');
      await expectLater(
        repository.deleteAllExcept(chefId: testChefId, recipeId: lasagneId),
        _failure(RecipePhotoFailureKind.unavailable),
      );
    });
  });

  // Un pedido que no responde (una red móvil mala) no deja guardando para
  // siempre: reintentar es seguro.
  group('sin respuesta', () {
    late SupabaseRecipePhotosRepository quick;

    setUp(() {
      server.handler = (_) => Completer<http.Response>().future;
      quick = SupabaseRecipePhotosRepository(
        server.client,
        uploadTimeout: const Duration(milliseconds: 20),
        requestTimeout: const Duration(milliseconds: 20),
      );
    });

    test('la subida, set_recipe_photo y la limpieza se dan por fallidas (unavailable)', () async {
      final unavailable = _failure(RecipePhotoFailureKind.unavailable);
      await expectLater(
        quick.upload(chefId: testChefId, recipeId: lasagneId, photo: _photo),
        unavailable,
      );
      await expectLater(
        quick.setPhoto(recipeId: lasagneId, photoId: _photoId),
        unavailable,
      );
      await expectLater(
        quick.deleteAllExcept(chefId: testChefId, recipeId: lasagneId),
        unavailable,
      );
    });

    test('los plazos de verdad: un minuto para subir, 30 s para lo demás', () {
      final repository = SupabaseRecipePhotosRepository(server.client);
      expect(repository.uploadTimeout, const Duration(seconds: 60));
      expect(repository.requestTimeout, const Duration(seconds: 30));
    });
  });
}
