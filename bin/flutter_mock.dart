import 'dart:io';

import 'package:flutter_mock_server/flutter_mock_server.dart';

Future<void> main(List<String> arguments) async {
  final exitCodeValue = await runFlutterMock(arguments);
  exitCode = exitCodeValue;
}
