import 'dart:convert';
import 'dart:io';

import 'package:flutter_mock_server/flutter_mock_server.dart';

Future<void> main() async {
  final tempDir =
      await Directory.systemTemp.createTemp('flutter_mock_example_');
  final configFile = File('${tempDir.path}/mock.yaml');
  final dataDir = Directory('${tempDir.path}/data');
  final ordersJson = File('${dataDir.path}/orders.json');
  await dataDir.create(recursive: true);

  await ordersJson.writeAsString('''[
  {
    "id": "ord_1001",
    "customer": "Avery",
    "total": 149.99
  }
]''');

  await configFile.writeAsString(_initialConfig());

  final port = await _findFreePort();
  final server = FlutterMockServer(
    configPath: configFile.path,
    host: '127.0.0.1',
    port: port,
  );

  try {
    await server.start();
    final client = HttpClient();

    final getOrders = await _request(
      client,
      method: 'GET',
      uri: Uri.parse('http://127.0.0.1:$port/orders'),
    );
    stdout.writeln('GET /orders -> ${getOrders.statusCode} ${getOrders.body}');

    final createOrder = await _request(
      client,
      method: 'POST',
      uri: Uri.parse('http://127.0.0.1:$port/orders'),
    );
    stdout.writeln(
        'POST /orders -> ${createOrder.statusCode} ${createOrder.body}');

    await configFile.writeAsString(_updatedConfig());
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final createAfterReload = await _request(
      client,
      method: 'POST',
      uri: Uri.parse('http://127.0.0.1:$port/orders'),
    );
    stdout.writeln(
      'POST /orders (after hot reload) -> ${createAfterReload.statusCode} ${createAfterReload.body}',
    );

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
}) async {
  final request = await client.openUrl(method, uri);
  final response = await request.close();
  final body = await utf8.decoder.bind(response).join();
  return _ResponseData(response.statusCode, body);
}

String _initialConfig() {
  return '''routes:
  - path: /orders
    method: GET
    response:
      file: data/orders.json

  - path: /orders
    method: POST
    response:
      status: 201
      body:
        message: Order accepted
        id: "{{uuid}}"
        createdAt: "{{timestamp}}"
''';
}

String _updatedConfig() {
  return '''routes:
  - path: /orders
    method: GET
    response:
      file: data/orders.json

  - path: /orders
    method: POST
    response:
      status: 201
      body:
        message: Order accepted after reload
        id: "{{uuid}}"
        createdAt: "{{timestamp}}"
''';
}

class _ResponseData {
  _ResponseData(this.statusCode, this.body);

  final int statusCode;
  final String body;
}
