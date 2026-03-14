import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as path;

import '../config/yaml_parser.dart';
import '../server/mock_server.dart';

const int _exitSuccess = 0;
const int _exitUsage = 64;
const int _exitData = 65;
const int _exitSoftware = 70;

/// Runs the `flutter_mock` command-line interface.
///
/// Returns a process exit code after handling the parsed command.
Future<int> runFlutterMock(List<String> arguments) async {
  final parser = ArgParser()
    ..addCommand(
      'init',
      ArgParser()
        ..addFlag(
          'force',
          abbr: 'f',
          help: 'Overwrite mock.yaml and sample data if they already exist.',
          negatable: false,
        ),
    )
    ..addCommand(
      'start',
      ArgParser()
        ..addOption(
          'config',
          abbr: 'c',
          defaultsTo: 'mock.yaml',
          help: 'Path to the YAML configuration file.',
        )
        ..addOption(
          'host',
          defaultsTo: 'localhost',
          help: 'Host interface to bind.',
        )
        ..addOption(
          'port',
          defaultsTo: '8080',
          help: 'Port to bind.',
        ),
    )
    ..addCommand(
      'validate',
      ArgParser()
        ..addOption(
          'config',
          abbr: 'c',
          defaultsTo: 'mock.yaml',
          help: 'Path to the YAML configuration file.',
        ),
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    );

  late final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    _printUsage(parser);
    return _exitUsage;
  }

  if (results['help'] == true || results.command == null) {
    _printUsage(parser);
    return _exitSuccess;
  }

  switch (results.command!.name) {
    case 'init':
      return _runInit(results.command!);
    case 'start':
      return _runStart(results.command!);
    case 'validate':
      return _runValidate(results.command!);
    default:
      _printUsage(parser);
      return _exitUsage;
  }
}

Future<int> _runInit(ArgResults args) async {
  final overwrite = args['force'] as bool;
  final cwd = Directory.current.path;
  final dataDirectory = Directory(path.join(cwd, 'data'));
  await dataDirectory.create(recursive: true);

  final mockYaml = File(path.join(cwd, 'mock.yaml'));
  final usersJson = File(path.join(dataDirectory.path, 'users.json'));

  if (!overwrite && (await mockYaml.exists() || await usersJson.exists())) {
    stdout.writeln(
        'Initialization skipped. Use --force to overwrite existing files.');
    return _exitSuccess;
  }

  await mockYaml.writeAsString(_defaultMockYaml());
  await usersJson.writeAsString(_defaultUsersJson());

  stdout.writeln(
      'Created mock.yaml and data/users.json in ${Directory.current.path}.');
  return _exitSuccess;
}

Future<int> _runStart(ArgResults args) async {
  final configPath = args['config'] as String;
  final host = args['host'] as String;
  final portValue = int.tryParse(args['port'] as String);

  if (portValue == null || portValue < 1 || portValue > 65535) {
    stderr.writeln('Invalid port. Expected a value between 1 and 65535.');
    return _exitUsage;
  }

  final server = FlutterMockServer(
    configPath: configPath,
    host: host,
    port: portValue,
  );

  try {
    await server.start();
  } on Object catch (error) {
    stderr.writeln('Failed to start mock server: $error');
    return _exitSoftware;
  }

  final shutdown = Completer<void>();

  Future<void> handleSignal(ProcessSignal signal) async {
    if (shutdown.isCompleted) {
      return;
    }
    stdout.writeln('\nReceived ${signal.name}. Stopping server...');
    shutdown.complete();
    await server.stop();
  }

  final sigint = ProcessSignal.sigint.watch().listen(handleSignal);
  final sigterm = ProcessSignal.sigterm.watch().listen(handleSignal);

  try {
    await shutdown.future;
  } finally {
    await sigint.cancel();
    await sigterm.cancel();
  }

  return _exitSuccess;
}

Future<int> _runValidate(ArgResults args) async {
  final configPath = args['config'] as String;
  final parser = YamlConfigParser();

  try {
    final config = await parser.parseFile(configPath);
    stdout.writeln(
      jsonEncode({
        'valid': true,
        'routes': config.routes.length,
        'config': path.normalize(configPath),
      }),
    );
    return _exitSuccess;
  } on Object catch (error) {
    stderr.writeln('Invalid mock configuration: $error');
    return _exitData;
  }
}

void _printUsage(ArgParser parser) {
  stdout.writeln('flutter_mock_server 0.1.5');
  stdout.writeln('Usage: flutter_mock <command> [arguments]');
  stdout.writeln('');
  stdout.writeln('Commands:');
  stdout.writeln('  init      Create a starter mock.yaml and data/ folder.');
  stdout.writeln('  start     Start the local mock server.');
  stdout.writeln('  validate  Validate the YAML configuration.');
  stdout.writeln('');
  stdout.writeln(parser.usage);
}

String _defaultMockYaml() {
  return '''routes:
  - path: /users
    method: GET
    response:
      file: data/users.json

  - path: /users
    method: POST
    response:
      status: 201
      body:
        message: User created
        id: "{{uuid}}"
''';
}

String _defaultUsersJson() {
  const encoder = JsonEncoder.withIndent('  ');
  return encoder.convert([
    {'id': '1', 'name': 'Alice'},
    {'id': '2', 'name': 'Bob'},
  ]);
}
