import 'dart:convert';
import 'dart:io';

import 'package:flutter_mock_server/flutter_mock_server.dart';

Future<void> main() async {
  final tempDir =
      await Directory.systemTemp.createTemp('flutter_mock_example_');
  final configFile = File('${tempDir.path}/mock.yaml');

  await configFile.writeAsString(_config());

  final port = await _findFreePort();
  final server = FlutterMockServer(
    configPath: configFile.path,
    host: '127.0.0.1',
    port: port,
  );

  try {
    await server.start();
    final client = HttpClient();

    final listUsers = await _request(
      client,
      method: 'GET',
      uri: Uri.parse('http://127.0.0.1:$port/users?role=admin&limit=2'),
    );
    stdout.writeln('GET /users?role=admin&limit=2 -> '
        '${listUsers.statusCode} ${listUsers.body}');

    final createUser = await _request(
      client,
      method: 'POST',
      uri: Uri.parse('http://127.0.0.1:$port/users'),
      body: {
        'name': 'Morgan',
        'email': 'morgan@sample.app',
        'role': 'member',
        'age': 29,
      },
    );
    stdout
        .writeln('POST /users -> ${createUser.statusCode} ${createUser.body}');

    final createdId =
        (jsonDecode(createUser.body) as Map<String, dynamic>)['id'];
    final getUser = await _request(
      client,
      method: 'GET',
      uri: Uri.parse('http://127.0.0.1:$port/users/$createdId'),
    );
    stdout.writeln('GET /users/$createdId -> '
        '${getUser.statusCode} ${getUser.body}');

    final updateUser = await _request(
      client,
      method: 'PUT',
      uri: Uri.parse('http://127.0.0.1:$port/users/$createdId'),
      body: {
        'role': 'admin',
      },
    );
    stdout.writeln('PUT /users/$createdId -> '
        '${updateUser.statusCode} ${updateUser.body}');

    final signIn = await _request(
      client,
      method: 'POST',
      uri: Uri.parse('http://127.0.0.1:$port/session'),
      body: {
        'email': 'morgan@sample.app',
      },
    );
    stdout.writeln('POST /session -> ${signIn.statusCode} ${signIn.body}');

    final deleteUser = await _request(
      client,
      method: 'DELETE',
      uri: Uri.parse('http://127.0.0.1:$port/users/$createdId'),
    );
    stdout.writeln('DELETE /users/$createdId -> '
        '${deleteUser.statusCode} ${deleteUser.body}');

    client.close(force: true);
  } finally {
    await server.stop();
    await tempDir.delete(recursive: true);
  }
}

Future<int> _findFreePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<_ResponseData> _request(
  HttpClient client, {
  required String method,
  required Uri uri,
  Object? body,
}) async {
  final request = await client.openUrl(method, uri);
  if (body != null) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
  }
  final response = await request.close();
  final responseBody = await utf8.decoder.bind(response).join();
  return _ResponseData(response.statusCode, responseBody);
}

String _config() {
  return '''seed: 7
models:
  User:
    id: uuid
    name: name
    email: email
    role:
      enum: [admin, member, viewer]
    age:
      type: int
      min: 18
      max: 60

stores:
  users:
    model: User
    count: 10

routes:
  - path: /users
    method: GET
    action: list
    store: users

  - path: /users/:id
    method: GET
    action: get
    store: users

  - path: /users
    method: POST
    action: create
    store: users

  - path: /users/:id
    method: PUT
    action: update
    store: users

  - path: /users/:id
    method: DELETE
    action: delete
    store: users

  - path: /session
    method: POST
    response:
      status: 201
      body:
        token: "{{uuid}}"
        email: "{{request.body.email}}"
        message: Signed in
 ''';
}

class _ResponseData {
  _ResponseData(this.statusCode, this.body);

  final int statusCode;
  final String body;
}
