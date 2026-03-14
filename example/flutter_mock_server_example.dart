import 'dart:io';

import 'package:flutter_mock_server/flutter_mock_server.dart';

Future<void> main() async {
  final tempDir =
      await Directory.systemTemp.createTemp('flutter_mock_example_');
  final configFile = File('${tempDir.path}/mock.yaml');
  final dataDir = Directory('${tempDir.path}/data');
  await dataDir.create(recursive: true);

  await configFile.writeAsString('''routes:
  - path: /orders
    method: GET
    response:
      body:
        orders:
          - id: "{{uuid}}"
            status: placed
            createdAt: "{{timestamp}}"
''');

  final config = await YamlConfigParser().parseFile(configFile.path);
  final rendered = TemplateEngine().render(config.routes.first.response.body);

  stdout.writeln(
      'Loaded ${config.routes.length} mock route(s) from ${configFile.path}.');
  stdout.writeln('Example response payload: $rendered');

  await tempDir.delete(recursive: true);
}
