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
        _providedTemplateEngine = templateEngine,
        _providedRandom = random,
        _templateEngine = templateEngine ?? TemplateEngine(random: random),
        _random = random ?? Random();

  final String configPath;
  final String host;
  final int port;
  final YamlConfigParser _parser;
  final TemplateEngine? _providedTemplateEngine;
  final Random? _providedRandom;

  late TemplateEngine _templateEngine;
  late Random _random;

  HttpServer? _server;
  MockConfig? _config;
  Map<String, _StoreRuntime> _stores = const {};
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

    MockRoute? route;
    Map<String, String> pathParameters = const {};
    for (final candidate in config.routes) {
      if (candidate.method != request.method.toUpperCase()) {
        continue;
      }
      final match = candidate.matchPath(request.requestedUri.path);
      if (match != null) {
        route = candidate;
        pathParameters = match;
        break;
      }
    }

    if (route == null) {
      return _jsonResponse(
        status: 404,
        body: {
          'message':
              'No mock route found for ${request.method} ${request.requestedUri.path}'
        },
      );
    }

    final requestBody = await _parseRequestBody(request);
    final resolved = _pickResponse(route.response, route.method, route.action);

    if (resolved.delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: resolved.delayMs));
    }

    if (route.isStateful) {
      return _handleStatefulRoute(
        route: route,
        request: request,
        config: config,
        resolved: resolved,
        pathParameters: pathParameters,
        requestBody: requestBody,
      );
    }

    final payload = await _resolveBody(
      resolved.file,
      resolved.body,
      config.sourcePath,
      context: TemplateContext(
        path: pathParameters,
        query: request.requestedUri.queryParameters,
        body: requestBody,
      ),
    );

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
      _rebuildRuntime(nextConfig);
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

  void _rebuildRuntime(MockConfig config) {
    final random = _providedRandom ??
        (config.seed == null ? Random() : Random(config.seed!));
    _random = random;
    _templateEngine = _providedTemplateEngine ?? TemplateEngine(random: random);
    _stores = {
      for (final entry in config.stores.entries)
        entry.key: _seedStore(entry.value, config),
    };
  }

  _StoreRuntime _seedStore(MockStoreDefinition definition, MockConfig config) {
    final model = config.models[definition.model]!;
    final records = List<Map<String, Object?>>.generate(
      definition.count,
      (_) => _ensurePrimaryKey(
        _templateEngine.generateModel(model, config.models),
        definition.primaryKey,
      ),
      growable: true,
    );

    return _StoreRuntime(definition: definition, records: records);
  }

  _ResolvedResponse _pickResponse(
    MockResponse? response,
    String method,
    String? action,
  ) {
    if (response == null) {
      return _ResolvedResponse(
        status: action == 'create' || method == 'POST' ? 201 : 200,
        file: null,
        body: null,
        headers: const {},
        delayMs: 0,
      );
    }

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

  Future<Response> _handleStatefulRoute({
    required MockRoute route,
    required Request request,
    required MockConfig config,
    required _ResolvedResponse resolved,
    required Map<String, String> pathParameters,
    required Object? requestBody,
  }) async {
    final runtime = _stores[route.store];
    if (runtime == null) {
      return _jsonResponse(
        status: 500,
        body: {'message': 'Store "${route.store}" is not available.'},
      );
    }

    switch (route.action) {
      case 'list':
        return _handleListRoute(
          route: route,
          request: request,
          config: config,
          resolved: resolved,
          runtime: runtime,
          pathParameters: pathParameters,
          requestBody: requestBody,
        );
      case 'get':
        return _handleGetRoute(
          route: route,
          request: request,
          config: config,
          resolved: resolved,
          runtime: runtime,
          pathParameters: pathParameters,
          requestBody: requestBody,
        );
      case 'create':
        return _handleCreateRoute(
          route: route,
          request: request,
          config: config,
          resolved: resolved,
          runtime: runtime,
          pathParameters: pathParameters,
          requestBody: requestBody,
        );
      case 'update':
        return _handleUpdateRoute(
          route: route,
          request: request,
          config: config,
          resolved: resolved,
          runtime: runtime,
          pathParameters: pathParameters,
          requestBody: requestBody,
        );
      case 'delete':
        return _handleDeleteRoute(
          route: route,
          request: request,
          config: config,
          resolved: resolved,
          runtime: runtime,
          pathParameters: pathParameters,
          requestBody: requestBody,
        );
      default:
        return _jsonResponse(
          status: 500,
          body: {'message': 'Unsupported action: ${route.action}'},
        );
    }
  }

  Future<Response> _handleListRoute({
    required MockRoute route,
    required Request request,
    required MockConfig config,
    required _ResolvedResponse resolved,
    required _StoreRuntime runtime,
    required Map<String, String> pathParameters,
    required Object? requestBody,
  }) async {
    final filtered = _applyQueryParameters(
      runtime.records,
      request.requestedUri.queryParameters,
    );
    final renderedRecords = filtered
        .map((record) => _templateEngine.render(
              record,
              context: TemplateContext(
                path: pathParameters,
                query: request.requestedUri.queryParameters,
                body: requestBody,
                record: record,
              ),
            ))
        .toList(growable: false);

    final payload = resolved.body != null || resolved.file != null
        ? await _resolveBody(
            resolved.file,
            resolved.body,
            config.sourcePath,
            context: TemplateContext(
              path: pathParameters,
              query: request.requestedUri.queryParameters,
              body: requestBody,
              extra: {
                'records': renderedRecords,
                'count': renderedRecords.length,
              },
            ),
          )
        : renderedRecords;

    return _buildResponse(
      status: resolved.status,
      body: payload,
      headers: resolved.headers,
    );
  }

  Future<Response> _handleGetRoute({
    required MockRoute route,
    required Request request,
    required MockConfig config,
    required _ResolvedResponse resolved,
    required _StoreRuntime runtime,
    required Map<String, String> pathParameters,
    required Object? requestBody,
  }) async {
    final record = _findRecord(runtime, pathParameters);
    if (record == null) {
      return _jsonResponse(status: 404, body: {'message': 'Record not found.'});
    }

    final renderedRecord = _templateEngine.render(
      record,
      context: TemplateContext(
        path: pathParameters,
        query: request.requestedUri.queryParameters,
        body: requestBody,
        record: record,
      ),
    );

    final payload = resolved.body != null || resolved.file != null
        ? await _resolveBody(
            resolved.file,
            resolved.body,
            config.sourcePath,
            context: TemplateContext(
              path: pathParameters,
              query: request.requestedUri.queryParameters,
              body: requestBody,
              record: record,
              extra: {'record': renderedRecord},
            ),
          )
        : renderedRecord;

    return _buildResponse(
      status: resolved.status,
      body: payload,
      headers: resolved.headers,
    );
  }

  Future<Response> _handleCreateRoute({
    required MockRoute route,
    required Request request,
    required MockConfig config,
    required _ResolvedResponse resolved,
    required _StoreRuntime runtime,
    required Map<String, String> pathParameters,
    required Object? requestBody,
  }) async {
    final model = config.models[runtime.definition.model]!;
    final generated = _templateEngine.generateModel(model, config.models);
    final requestMap = _asObjectMap(requestBody);
    final record = _ensurePrimaryKey(
      {...generated, ...?requestMap},
      runtime.definition.primaryKey,
    );
    runtime.records.add(record);

    final payload = resolved.body != null || resolved.file != null
        ? await _resolveBody(
            resolved.file,
            resolved.body,
            config.sourcePath,
            context: TemplateContext(
              path: pathParameters,
              query: request.requestedUri.queryParameters,
              body: requestBody,
              record: record,
              extra: {'record': record},
            ),
          )
        : _templateEngine.render(
            record,
            context: TemplateContext(
              path: pathParameters,
              query: request.requestedUri.queryParameters,
              body: requestBody,
              record: record,
            ),
          );

    return _buildResponse(
      status: resolved.status,
      body: payload,
      headers: resolved.headers,
    );
  }

  Future<Response> _handleUpdateRoute({
    required MockRoute route,
    required Request request,
    required MockConfig config,
    required _ResolvedResponse resolved,
    required _StoreRuntime runtime,
    required Map<String, String> pathParameters,
    required Object? requestBody,
  }) async {
    final record = _findRecord(runtime, pathParameters);
    if (record == null) {
      return _jsonResponse(status: 404, body: {'message': 'Record not found.'});
    }

    final requestMap = _asObjectMap(requestBody);
    if (requestMap != null) {
      record.addAll(requestMap);
      record[runtime.definition.primaryKey] ??=
          _resolveIdentifier(pathParameters, runtime.definition.primaryKey);
    }

    final payload = resolved.body != null || resolved.file != null
        ? await _resolveBody(
            resolved.file,
            resolved.body,
            config.sourcePath,
            context: TemplateContext(
              path: pathParameters,
              query: request.requestedUri.queryParameters,
              body: requestBody,
              record: record,
              extra: {'record': record},
            ),
          )
        : _templateEngine.render(
            record,
            context: TemplateContext(
              path: pathParameters,
              query: request.requestedUri.queryParameters,
              body: requestBody,
              record: record,
            ),
          );

    return _buildResponse(
      status: resolved.status,
      body: payload,
      headers: resolved.headers,
    );
  }

  Future<Response> _handleDeleteRoute({
    required MockRoute route,
    required Request request,
    required MockConfig config,
    required _ResolvedResponse resolved,
    required _StoreRuntime runtime,
    required Map<String, String> pathParameters,
    required Object? requestBody,
  }) async {
    final identifier = _resolveIdentifier(
      pathParameters,
      runtime.definition.primaryKey,
    );
    if (identifier == null) {
      return _jsonResponse(
        status: 400,
        body: {'message': 'Missing identifier in route path.'},
      );
    }

    final index = runtime.records.indexWhere(
      (record) => '${record[runtime.definition.primaryKey]}' == identifier,
    );
    if (index == -1) {
      return _jsonResponse(status: 404, body: {'message': 'Record not found.'});
    }

    final removed = runtime.records.removeAt(index);
    final payload = resolved.body != null || resolved.file != null
        ? await _resolveBody(
            resolved.file,
            resolved.body,
            config.sourcePath,
            context: TemplateContext(
              path: pathParameters,
              query: request.requestedUri.queryParameters,
              body: requestBody,
              record: removed,
              extra: {
                'record': removed,
                'deleted': true,
              },
            ),
          )
        : {
            'deleted': true,
            'record': _templateEngine.render(
              removed,
              context: TemplateContext(
                path: pathParameters,
                query: request.requestedUri.queryParameters,
                body: requestBody,
                record: removed,
              ),
            ),
          };

    return _buildResponse(
      status: resolved.status,
      body: payload,
      headers: resolved.headers,
    );
  }

  List<Map<String, Object?>> _applyQueryParameters(
    List<Map<String, Object?>> records,
    Map<String, String> query,
  ) {
    var filtered = List<Map<String, Object?>>.from(records);

    query.forEach((key, value) {
      if (_reservedQueryKeys.contains(key)) {
        return;
      }
      filtered = filtered
          .where((record) => '${record[key] ?? ''}' == value)
          .toList(growable: false);
    });

    final sortField = query['sort'];
    if (sortField != null && sortField.isNotEmpty) {
      final descending = (query['order'] ?? '').toLowerCase() == 'desc';
      filtered.sort((left, right) {
        final comparison =
            '${left[sortField] ?? ''}'.compareTo('${right[sortField] ?? ''}');
        return descending ? -comparison : comparison;
      });
    }

    final limit = int.tryParse(query['limit'] ?? '');
    final page = int.tryParse(query['page'] ?? '') ?? 1;
    if (limit != null && limit > 0) {
      final start = max(0, (page - 1) * limit);
      if (start >= filtered.length) {
        return const [];
      }
      final end = min(filtered.length, start + limit);
      filtered = filtered.sublist(start, end);
    }

    return filtered;
  }

  Future<Object?> _resolveBody(
    String? filePath,
    Object? inlineBody,
    String sourcePath, {
    required TemplateContext context,
  }) async {
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

    return _templateEngine.render(body, context: context);
  }

  Future<Object?> _parseRequestBody(Request request) async {
    final content = await request.readAsString();
    if (content.trim().isEmpty) {
      return null;
    }

    try {
      return jsonDecode(content);
    } on FormatException {
      return content;
    }
  }

  Map<String, Object?>? _asObjectMap(Object? value) {
    if (value is Map<String, Object?>) {
      return Map<String, Object?>.from(value);
    }
    if (value is Map) {
      return value.map(
        (key, nestedValue) => MapEntry(key.toString(), nestedValue),
      );
    }
    return null;
  }

  Map<String, Object?> _ensurePrimaryKey(
    Map<String, Object?> record,
    String primaryKey,
  ) {
    if (record[primaryKey] == null || '${record[primaryKey]}'.isEmpty) {
      record[primaryKey] = _templateEngine.render('{{uuid}}');
    }
    return record;
  }

  Map<String, Object?>? _findRecord(
    _StoreRuntime runtime,
    Map<String, String> pathParameters,
  ) {
    final identifier =
        _resolveIdentifier(pathParameters, runtime.definition.primaryKey);
    if (identifier == null) {
      return null;
    }

    for (final record in runtime.records) {
      if ('${record[runtime.definition.primaryKey]}' == identifier) {
        return record;
      }
    }
    return null;
  }

  String? _resolveIdentifier(
    Map<String, String> pathParameters,
    String primaryKey,
  ) {
    return pathParameters[primaryKey] ??
        pathParameters['id'] ??
        (pathParameters.isNotEmpty ? pathParameters.values.first : null);
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
}

const Set<String> _reservedQueryKeys = {
  'page',
  'limit',
  'sort',
  'order',
};

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

class _StoreRuntime {
  _StoreRuntime({
    required this.definition,
    required this.records,
  });

  final MockStoreDefinition definition;
  final List<Map<String, Object?>> records;
}
