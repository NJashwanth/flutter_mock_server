import 'dart:convert';
import 'dart:io';

import 'package:flutter_mock_server/flutter_mock_server.dart';
import 'package:test/test.dart';

void main() {
  group('FlutterMockServer', () {
    late Directory tempDir;
    late File configFile;
    late FlutterMockServer server;
    late HttpClient client;
    late int port;

    tearDown(() async {
      client.close(force: true);
      await server.stop();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('supports CRUD flows, filtering, pagination, and request bindings',
        () async {
      tempDir = await Directory.systemTemp.createTemp('flutter_mock_test_');
      configFile = File('${tempDir.path}/mock.yaml');
      await configFile.writeAsString(_crudConfig());

      port = await _findFreePort();
      server = FlutterMockServer(
        configPath: configFile.path,
        host: '127.0.0.1',
        port: port,
      );
      client = HttpClient();

      await server.start();

      final listResponse = await _request(
        client,
        method: 'GET',
        uri: Uri.parse(
          'http://127.0.0.1:$port/users?role=admin&sort=name&order=asc&limit=2',
        ),
      );

      expect(listResponse.statusCode, 200);
      final listedUsers = jsonDecode(listResponse.body) as List<dynamic>;
      expect(listedUsers, hasLength(2));
      expect(
        listedUsers
            .every((user) => (user as Map<String, dynamic>)['role'] == 'admin'),
        isTrue,
      );

      final createResponse = await _request(
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

      expect(createResponse.statusCode, 201);
      final createdUser =
          jsonDecode(createResponse.body) as Map<String, dynamic>;
      expect(createdUser['id'], isNotEmpty);
      expect(createdUser['name'], 'Morgan');

      final createdId = createdUser['id'] as String;
      final getResponse = await _request(
        client,
        method: 'GET',
        uri: Uri.parse('http://127.0.0.1:$port/users/$createdId'),
      );

      expect(getResponse.statusCode, 200);
      expect(
        (jsonDecode(getResponse.body) as Map<String, dynamic>)['email'],
        'morgan@sample.app',
      );

      final updateResponse = await _request(
        client,
        method: 'PUT',
        uri: Uri.parse('http://127.0.0.1:$port/users/$createdId'),
        body: {
          'role': 'admin',
        },
      );

      expect(updateResponse.statusCode, 200);
      expect(
        (jsonDecode(updateResponse.body) as Map<String, dynamic>)['role'],
        'admin',
      );

      final sessionResponse = await _request(
        client,
        method: 'POST',
        uri: Uri.parse('http://127.0.0.1:$port/session?source=test-suite'),
        body: {
          'email': 'morgan@sample.app',
        },
      );

      expect(sessionResponse.statusCode, 201);
      final sessionPayload =
          jsonDecode(sessionResponse.body) as Map<String, dynamic>;
      expect(sessionPayload['email'], 'morgan@sample.app');
      expect(sessionPayload['source'], 'test-suite');

      final deleteResponse = await _request(
        client,
        method: 'DELETE',
        uri: Uri.parse('http://127.0.0.1:$port/users/$createdId'),
      );

      expect(deleteResponse.statusCode, 200);
      expect(
        (jsonDecode(deleteResponse.body) as Map<String, dynamic>)['deleted'],
        isTrue,
      );

      final afterDelete = await _request(
        client,
        method: 'GET',
        uri: Uri.parse('http://127.0.0.1:$port/users/$createdId'),
      );

      expect(afterDelete.statusCode, 404);
    });

    test('generates nested models, arrays with item schemas, and ranged dates',
        () async {
      tempDir = await Directory.systemTemp.createTemp('flutter_mock_test_');
      configFile = File('${tempDir.path}/mock.yaml');
      await configFile.writeAsString(_richFieldConfig());

      port = await _findFreePort();
      server = FlutterMockServer(
        configPath: configFile.path,
        host: '127.0.0.1',
        port: port,
      );
      client = HttpClient();

      await server.start();

      final response = await _request(
        client,
        method: 'GET',
        uri: Uri.parse('http://127.0.0.1:$port/orders'),
      );

      expect(response.statusCode, 200);
      final orders = jsonDecode(response.body) as List<dynamic>;
      expect(orders, hasLength(2));

      final firstOrder = orders.first as Map<String, dynamic>;
      final customer = firstOrder['customer'] as Map<String, dynamic>;
      expect(customer['email'], isA<String>());

      final lineItems = firstOrder['items'] as List<dynamic>;
      expect(lineItems, hasLength(3));
      expect(lineItems.first, containsPair('sku', isA<String>()));
      expect(lineItems.first, containsPair('quantity', isA<int>()));

      final deliveryDate = DateTime.parse(firstOrder['deliveryDate'] as String);
      expect(
        deliveryDate.isAfter(
            DateTime.utc(2026, 1, 1).subtract(const Duration(seconds: 1))),
        isTrue,
      );
      expect(
        deliveryDate.isBefore(DateTime.utc(2026, 1, 31, 23, 59, 59)
            .add(const Duration(seconds: 1))),
        isTrue,
      );
    });
  });
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

String _crudConfig() {
  return '''seed: 42
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
        source: "{{request.query.source}}"
        message: Signed in
''';
}

String _richFieldConfig() {
  return '''seed: 9
models:
  Customer:
    id: uuid
    name: name
    email: email
  LineItem:
    sku: word
    quantity:
      type: int
      min: 1
      max: 5
  Order:
    id: uuid
    customer:
      type: Customer
    items:
      type: array
      count: 3
      items:
        type: LineItem
    deliveryDate:
      type: date
      from: 2026-01-01T00:00:00Z
      to: 2026-01-31T23:59:59Z

stores:
  orders:
    model: Order
    count: 2

routes:
  - path: /orders
    method: GET
    action: list
    store: orders
''';
}

class _ResponseData {
  const _ResponseData(this.statusCode, this.body);

  final int statusCode;
  final String body;
}
