import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../config/yaml_parser.dart';
import '../utils/template_engine.dart';

/// Local Shelf-based mock server backed by `mock.yaml` route definitions.
class FlutterMockServer {
  /// Creates a mock server instance for the provided config file and bind target.
  FlutterMockServer({
    required this.configPath,
    this.host = 'localhost',
    this.port = 8080,
    YamlConfigParser? parser,
    TemplateEngine? templateEngine,
    Random? random,
  })  : _parser = parser ?? YamlConfigParser(),
        _templateEngine = templateEngine ?? TemplateEngine(),
        _random = random ?? Random();

  final String configPath;
  final String host;
  final int port;
  final YamlConfigParser _parser;
  final TemplateEngine _templateEngine;
  final Random _random;

  HttpServer? _server;
  MockConfig? _config;
  StreamSubscription<FileSystemEvent>? _watchSubscription;
  Timer? _reloadDebounce;

  /// Starts the HTTP server and begins watching the config file for changes.
  Future<void> start() async {
    await _reloadConfig(logReload: false);

    final handler = const Pipeline()
        .addMiddleware(logRequests())
        .addHandler((request) => _handleRequest(request));

    _server = await shelf_io.serve(handler, host, port);
    _server!
      ..autoCompress = true
      ..idleTimeout = const Duration(minutes: 5);

    await _startWatcher();

    stdout.writeln(
        'Mock server listening on http://${_server!.address.host}:${_server!.port}');
    stdout.writeln('Watching ${path.normalize(configPath)} for changes.');
  }

  /// Stops the HTTP server and cancels file watching.
  Future<void> stop() async {
    _reloadDebounce?.cancel();
    await _watchSubscription?.cancel();
    await _server?.close(force: true);
  }

  Future<Response> _handleRequest(Request request) async {
    final config = _config;
    if (config == null) {
      return _jsonResponse(
        status: 500,
        body: {'message': 'Mock server configuration is not loaded.'},
      );
    }

    final requestPath = _normalizeRequestPath(request.requestedUri.path);
    MockRoute? route;
    for (final candidate in config.routes) {
      if (candidate.method == request.method.toUpperCase() &&
          candidate.normalizedPath == requestPath) {
        route = candidate;
        break;
      }
    }

    if (route == null) {
      return _jsonResponse(
        status: 404,
        body: {
          'message': 'No mock route found for ${request.method} $requestPath'
        },
      );
    }

    final resolved = _pickResponse(route.response);

    if (resolved.delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: resolved.delayMs));
    }

    final payload =
        await _resolveBody(resolved.file, resolved.body, config.sourcePath);
    return _buildResponse(
      status: resolved.status,
      body: payload,
      headers: resolved.headers,
    );
  }

  Future<void> _startWatcher() async {
    final configFile = File(configPath).absolute;
    final directory = configFile.parent;
    await directory.create(recursive: true);

    _watchSubscription = directory.watch().listen((event) {
      if (path.equals(
          path.normalize(event.path), path.normalize(configFile.path))) {
        _reloadDebounce?.cancel();
        _reloadDebounce = Timer(const Duration(milliseconds: 250), () async {
          await _reloadConfig(logReload: true);
        });
      }
    });
  }

  Future<void> _reloadConfig({required bool logReload}) async {
    try {
      final nextConfig = await _parser.parseFile(configPath);
      _config = nextConfig;
      if (logReload) {
        stdout.writeln(
            'Reloaded ${path.basename(configPath)} at ${DateTime.now().toIso8601String()}.');
      }
    } on Object catch (error) {
      stderr.writeln('Config reload failed: $error');
      if (_config == null) {
        rethrow;
      }
    }
  }

  _ResolvedResponse _pickResponse(MockResponse response) {
    final error = response.error;
    if (error != null && _random.nextDouble() <= error.rate) {
      return _ResolvedResponse(
        status: error.status,
        file: error.file,
        body: error.body,
        headers: error.headers,
        delayMs: error.delayMs > 0 ? error.delayMs : response.delayMs,
      );
    }

    return _ResolvedResponse(
      status: response.status,
      file: response.file,
      body: response.body,
      headers: response.headers,
      delayMs: response.delayMs,
    );
  }

  Future<Object?> _resolveBody(
      String? filePath, Object? inlineBody, String sourcePath) async {
    Object? body = inlineBody;
    if (filePath != null) {
      final resolvedPath = path.isAbsolute(filePath)
          ? filePath
          : path.normalize(path.join(path.dirname(sourcePath), filePath));
      final file = File(resolvedPath);
      if (!await file.exists()) {
        throw MockConfigException('Response file not found: $resolvedPath');
      }
      final contents = await file.readAsString();
      body = jsonDecode(contents);
    }

    return _templateEngine.render(body);
  }

  Response _buildResponse({
    required int status,
    required Object? body,
    required Map<String, String> headers,
  }) {
    final responseHeaders = <String, String>{...headers};

    if (body == null) {
      return Response(status, headers: responseHeaders);
    }

    if (body is String) {
      responseHeaders.putIfAbsent(
          'content-type', () => 'text/plain; charset=utf-8');
      return Response(status, headers: responseHeaders, body: body);
    }

    responseHeaders.putIfAbsent(
        'content-type', () => 'application/json; charset=utf-8');
    return Response(status, headers: responseHeaders, body: jsonEncode(body));
  }

  Response _jsonResponse({required int status, required Object body}) {
    return Response(
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
      body: jsonEncode(body),
    );
  }

  String _normalizeRequestPath(String rawPath) {
    if (rawPath.isEmpty || rawPath == '/') {
      return '/';
    }
    final normalized = rawPath.startsWith('/') ? rawPath : '/$rawPath';
    return normalized.endsWith('/') && normalized.length > 1
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
  }
}

class _ResolvedResponse {
  _ResolvedResponse({
    required this.status,
    required this.file,
    required this.body,
    required this.headers,
    required this.delayMs,
  });

  final int status;
  final String? file;
  final Object? body;
  final Map<String, String> headers;
  final int delayMs;
}
