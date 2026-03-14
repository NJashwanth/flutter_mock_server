import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

/// Parsed representation of a `mock.yaml` file.
class MockConfig {
  /// Creates a parsed mock configuration.
  MockConfig({
    required this.sourcePath,
    required this.routes,
    required this.models,
    required this.stores,
    required this.seed,
  });

  /// Absolute or normalized source path of the loaded YAML file.
  final String sourcePath;

  /// Route definitions loaded from the YAML document.
  final List<MockRoute> routes;

  /// Reusable model definitions keyed by model name.
  final Map<String, MockModelDefinition> models;

  /// Stateful stores keyed by store name.
  final Map<String, MockStoreDefinition> stores;

  /// Optional deterministic seed for generated data.
  final int? seed;
}

/// A single route entry declared in `mock.yaml`.
class MockRoute {
  /// Creates a route with an HTTP method, path, and either a static response
  /// or a stateful action.
  MockRoute({
    required this.path,
    required this.method,
    required this.response,
    required this.action,
    required this.store,
  }) : _pathSegments = _splitPath(path);

  /// Raw route path as declared in YAML.
  final String path;

  /// HTTP method for the route.
  final String method;

  /// Response configuration for the route.
  final MockResponse? response;

  /// Optional CRUD action for stateful routes.
  final String? action;

  /// Optional backing store name for stateful routes.
  final String? store;

  final List<String> _pathSegments;

  /// Path normalized for runtime matching.
  String get normalizedPath {
    if (path == '/') {
      return '/';
    }
    final trimmed = path.startsWith('/') ? path : '/$path';
    return trimmed.endsWith('/') && trimmed.length > 1
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  /// Returns true when the route is backed by a mutable in-memory store.
  bool get isStateful => action != null && store != null;

  /// Matches a request path against the route path pattern.
  Map<String, String>? matchPath(String requestPath) {
    final normalized = _normalizeRequestPath(requestPath);
    final requestSegments = _splitPath(normalized);

    if (_pathSegments.length != requestSegments.length) {
      return null;
    }

    final parameters = <String, String>{};
    for (var index = 0; index < _pathSegments.length; index++) {
      final routeSegment = _pathSegments[index];
      final requestSegment = requestSegments[index];

      if (routeSegment.startsWith(':')) {
        final parameterName = routeSegment.substring(1);
        if (parameterName.isEmpty) {
          return null;
        }
        parameters[parameterName] = Uri.decodeComponent(requestSegment);
        continue;
      }

      if (routeSegment != requestSegment) {
        return null;
      }
    }

    return parameters;
  }

  static List<String> _splitPath(String rawPath) {
    final normalized = _normalizeRequestPath(rawPath);
    if (normalized == '/') {
      return const <String>[];
    }
    return normalized.substring(1).split('/');
  }

  static String _normalizeRequestPath(String rawPath) {
    if (rawPath.isEmpty || rawPath == '/') {
      return '/';
    }
    final normalized = rawPath.startsWith('/') ? rawPath : '/$rawPath';
    return normalized.endsWith('/') && normalized.length > 1
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
  }
}

/// Successful response configuration for a route.
class MockResponse {
  /// Creates a response configuration.
  MockResponse({
    required this.status,
    required this.file,
    required this.body,
    required this.headers,
    required this.delayMs,
    required this.error,
  });

  final int status;
  final String? file;
  final Object? body;
  final Map<String, String> headers;
  final int delayMs;
  final MockErrorResponse? error;

  /// Returns true when the response explicitly provides a payload source.
  bool get hasExplicitPayload => file != null || body != null;
}

/// Optional error response that may be returned instead of the primary response.
class MockErrorResponse {
  /// Creates an error response configuration.
  MockErrorResponse({
    required this.status,
    required this.file,
    required this.body,
    required this.headers,
    required this.delayMs,
    required this.rate,
  });

  final int status;
  final String? file;
  final Object? body;
  final Map<String, String> headers;
  final int delayMs;
  final double rate;
}

/// Reusable schema definition for generated mock records.
class MockModelDefinition {
  /// Creates a named model definition.
  MockModelDefinition({
    required this.name,
    required this.fields,
  });

  /// Model name as defined in YAML.
  final String name;

  /// Field definitions keyed by field name.
  final Map<String, MockFieldDefinition> fields;
}

/// Field specification inside a reusable model.
class MockFieldDefinition {
  /// Creates a field definition.
  MockFieldDefinition({
    required this.type,
    required this.min,
    required this.max,
    required this.items,
    required this.values,
    required this.example,
    required this.count,
    required this.from,
    required this.to,
    required this.format,
  });

  /// Built-in field type or nested model name.
  final String type;

  /// Optional lower bound for numeric generators.
  final num? min;

  /// Optional upper bound for numeric generators.
  final num? max;

  /// Optional item definition for array-valued fields.
  final MockFieldDefinition? items;

  /// Optional enum values for deterministic selection.
  final List<Object?>? values;

  /// Optional static example value.
  final Object? example;

  /// Optional item count for list-valued fields.
  final int? count;

  /// Optional lower bound for date generation.
  final DateTime? from;

  /// Optional upper bound for date generation.
  final DateTime? to;

  /// Output format for date generation.
  final String? format;
}

/// Backing store definition for generated records.
class MockStoreDefinition {
  /// Creates a store definition.
  MockStoreDefinition({
    required this.name,
    required this.model,
    required this.count,
    required this.primaryKey,
  });

  /// Store name as defined in YAML.
  final String name;

  /// Model used to seed new records.
  final String model;

  /// Number of initial records to generate.
  final int count;

  /// Identifier field used by get, update, and delete actions.
  final String primaryKey;
}

/// Parses and validates `mock.yaml` route configuration.
class YamlConfigParser {
  /// Loads, parses, and validates a YAML file from disk.
  Future<MockConfig> parseFile(String configPath) async {
    final file = File(configPath);
    if (!await file.exists()) {
      throw MockConfigException(
          'Configuration file not found: ${path.normalize(configPath)}');
    }

    final content = await file.readAsString();
    return parseString(content, sourcePath: file.absolute.path);
  }

  /// Parses and validates YAML content already loaded into memory.
  MockConfig parseString(String content, {String sourcePath = 'mock.yaml'}) {
    final Object? document;
    try {
      document = loadYaml(content);
    } on YamlException catch (error) {
      throw MockConfigException(
          'YAML syntax error in $sourcePath: ${error.message}');
    }

    final root = _asMap(document, 'root');
    final seed = _optionalInt(root['seed'], 'seed');
    final models = _parseModels(root['models']);
    final stores = _parseStores(root['stores'], models);

    final routesNode = root['routes'];
    final routesList = _asList(routesNode, 'routes');

    final routes = <MockRoute>[];
    for (var index = 0; index < routesList.length; index++) {
      final routeMap = _asMap(routesList[index], 'routes[$index]');
      routes.add(_parseRoute(routeMap, index, stores));
    }

    if (routes.isEmpty) {
      throw MockConfigException(
          'Configuration must define at least one route.');
    }

    return MockConfig(
      sourcePath: path.normalize(sourcePath),
      routes: routes,
      models: models,
      stores: stores,
      seed: seed,
    );
  }

  Map<String, MockModelDefinition> _parseModels(Object? rawModels) {
    if (rawModels == null) {
      return const {};
    }

    final modelsMap = _asMap(rawModels, 'models');
    final models = <String, MockModelDefinition>{};
    for (final entry in modelsMap.entries) {
      final name = _asString(entry.key, 'models.<key>');
      final modelMap = _asMap(entry.value, 'models.$name');
      final fields = <String, MockFieldDefinition>{};

      for (final fieldEntry in modelMap.entries) {
        final fieldName = _asString(fieldEntry.key, 'models.$name.<field>');
        fields[fieldName] = _parseFieldDefinition(
          fieldEntry.value,
          'models.$name.$fieldName',
        );
      }

      if (fields.isEmpty) {
        throw MockConfigException(
            'Model "$name" must define at least one field.');
      }

      models[name] = MockModelDefinition(name: name, fields: fields);
    }

    return models;
  }

  MockFieldDefinition _parseFieldDefinition(
      Object? rawField, String pathPrefix) {
    if (rawField is String) {
      return MockFieldDefinition(
        type: rawField,
        min: null,
        max: null,
        items: null,
        values: null,
        example: null,
        count: null,
        from: null,
        to: null,
        format: null,
      );
    }

    final fieldMap = _asMap(rawField, pathPrefix);
    final items = fieldMap.containsKey('items')
        ? _parseFieldDefinition(fieldMap['items'], '$pathPrefix.items')
        : null;
    final enumValues = fieldMap.containsKey('enum')
        ? _asList(fieldMap['enum'], '$pathPrefix.enum')
            .map(_normalizeYaml)
            .toList(growable: false)
        : null;
    final example = fieldMap.containsKey('example')
        ? _normalizeYaml(fieldMap['example'])
        : null;

    return MockFieldDefinition(
      type: _optionalString(fieldMap['type'], '$pathPrefix.type') ??
          (enumValues != null ? 'enum' : 'string'),
      min: _optionalNum(fieldMap['min'], '$pathPrefix.min'),
      max: _optionalNum(fieldMap['max'], '$pathPrefix.max'),
      items: items,
      values: enumValues,
      example: example,
      count: _optionalInt(fieldMap['count'], '$pathPrefix.count'),
      from: _optionalDateTime(fieldMap['from'], '$pathPrefix.from'),
      to: _optionalDateTime(fieldMap['to'], '$pathPrefix.to'),
      format: _optionalString(fieldMap['format'], '$pathPrefix.format'),
    );
  }

  Map<String, MockStoreDefinition> _parseStores(
    Object? rawStores,
    Map<String, MockModelDefinition> models,
  ) {
    if (rawStores == null) {
      return const {};
    }

    final storesMap = _asMap(rawStores, 'stores');
    final stores = <String, MockStoreDefinition>{};

    for (final entry in storesMap.entries) {
      final storeName = _asString(entry.key, 'stores.<key>');
      final storeMap = _asMap(entry.value, 'stores.$storeName');
      final modelName = _asString(storeMap['model'], 'stores.$storeName.model');
      if (!models.containsKey(modelName)) {
        throw MockConfigException(
          'Store "$storeName" references unknown model "$modelName".',
        );
      }

      final seedMap = storeMap.containsKey('seed')
          ? _asMap(storeMap['seed'], 'stores.$storeName.seed')
          : null;
      final count =
          _optionalInt(storeMap['count'], 'stores.$storeName.count') ??
              _optionalInt(seedMap?['count'], 'stores.$storeName.seed.count') ??
              0;
      final primaryKey = _optionalString(
              storeMap['primary_key'], 'stores.$storeName.primary_key') ??
          'id';

      if (count < 0) {
        throw MockConfigException('stores.$storeName.count must be >= 0.');
      }

      stores[storeName] = MockStoreDefinition(
        name: storeName,
        model: modelName,
        count: count,
        primaryKey: primaryKey,
      );
    }

    return stores;
  }

  MockRoute _parseRoute(
    Map<Object?, Object?> rawRoute,
    int index,
    Map<String, MockStoreDefinition> stores,
  ) {
    final routePath = _asString(rawRoute['path'], 'routes[$index].path');
    final method =
        _asString(rawRoute['method'], 'routes[$index].method').toUpperCase();
    const supportedMethods = {'GET', 'POST', 'PUT', 'DELETE', 'PATCH'};
    if (!supportedMethods.contains(method)) {
      throw MockConfigException(
        'Unsupported method "$method" at routes[$index].method. Expected one of ${supportedMethods.join(', ')}.',
      );
    }

    final action = _optionalString(rawRoute['action'], 'routes[$index].action');
    final store = _optionalString(rawRoute['store'], 'routes[$index].store');
    final response = rawRoute.containsKey('response')
        ? _parseResponse(
            rawRoute['response'],
            pathPrefix: 'routes[$index].response',
            defaultStatus: _defaultStatusFor(method, action),
            requirePayload: action == null,
          )
        : null;

    if (action != null || store != null) {
      const supportedActions = {'list', 'get', 'create', 'update', 'delete'};
      if (action == null || !supportedActions.contains(action)) {
        throw MockConfigException(
          'routes[$index].action must be one of ${supportedActions.join(', ')} when using a store-backed route.',
        );
      }
      if (store == null || !stores.containsKey(store)) {
        throw MockConfigException(
          'routes[$index].store must reference a defined store.',
        );
      }
    }

    if (action == null && response == null) {
      throw MockConfigException(
        'routes[$index] must define either response or a store-backed action.',
      );
    }

    return MockRoute(
      path: routePath,
      method: method,
      response: response,
      action: action,
      store: store,
    );
  }

  MockResponse _parseResponse(
    Object? rawResponse, {
    required String pathPrefix,
    required int defaultStatus,
    required bool requirePayload,
  }) {
    final responseMap = _asMap(rawResponse, pathPrefix);
    final file = _optionalString(responseMap['file'], '$pathPrefix.file');
    final body = responseMap.containsKey('body')
        ? _normalizeYaml(responseMap['body'])
        : null;
    final headers =
        _parseHeaders(responseMap['headers'], '$pathPrefix.headers');
    final delayMs =
        _optionalInt(responseMap['delay_ms'], '$pathPrefix.delay_ms') ?? 0;
    final status = _optionalInt(responseMap['status'], '$pathPrefix.status') ??
        defaultStatus;
    final error = responseMap.containsKey('error')
        ? _parseErrorResponse(responseMap['error'], '$pathPrefix.error')
        : null;

    if (requirePayload && file == null && body == null) {
      throw MockConfigException('$pathPrefix must define either file or body.');
    }

    return MockResponse(
      status: status,
      file: file,
      body: body,
      headers: headers,
      delayMs: delayMs,
      error: error,
    );
  }

  MockErrorResponse _parseErrorResponse(Object? rawError, String pathPrefix) {
    final errorMap = _asMap(rawError, pathPrefix);
    final file = _optionalString(errorMap['file'], '$pathPrefix.file');
    final body =
        errorMap.containsKey('body') ? _normalizeYaml(errorMap['body']) : null;
    final headers = _parseHeaders(errorMap['headers'], '$pathPrefix.headers');
    final delayMs =
        _optionalInt(errorMap['delay_ms'], '$pathPrefix.delay_ms') ?? 0;
    final status =
        _optionalInt(errorMap['status'], '$pathPrefix.status') ?? 500;
    final rate = _optionalDouble(errorMap['rate'], '$pathPrefix.rate') ?? 1.0;

    if (file == null && body == null) {
      throw MockConfigException('$pathPrefix must define either file or body.');
    }
    if (rate < 0 || rate > 1) {
      throw MockConfigException(
          '$pathPrefix.rate must be between 0.0 and 1.0.');
    }

    return MockErrorResponse(
      status: status,
      file: file,
      body: body,
      headers: headers,
      delayMs: delayMs,
      rate: rate,
    );
  }

  Map<String, String> _parseHeaders(Object? rawHeaders, String pathPrefix) {
    if (rawHeaders == null) {
      return const {};
    }

    final headersMap = _asMap(rawHeaders, pathPrefix);
    return headersMap.map((key, value) {
      final headerName = _asString(key, '$pathPrefix.<key>');
      final headerValue = _asString(value, '$pathPrefix.$headerName');
      return MapEntry(headerName, headerValue);
    });
  }

  int _defaultStatusFor(String method, String? action) {
    if (action == 'create') {
      return 201;
    }
    if (method == 'POST') {
      return 201;
    }
    return 200;
  }

  Map<Object?, Object?> _asMap(Object? value, String fieldName) {
    if (value is YamlMap) {
      return Map<Object?, Object?>.from(value);
    }
    if (value is Map<Object?, Object?>) {
      return value;
    }
    throw MockConfigException('Expected a mapping at $fieldName.');
  }

  List<Object?> _asList(Object? value, String fieldName) {
    if (value is YamlList) {
      return List<Object?>.from(value);
    }
    if (value is List<Object?>) {
      return value;
    }
    throw MockConfigException('Expected a list at $fieldName.');
  }

  String _asString(Object? value, String fieldName) {
    if (value is String && value.trim().isNotEmpty) {
      return value;
    }
    throw MockConfigException('Expected a non-empty string at $fieldName.');
  }

  String? _optionalString(Object? value, String fieldName) {
    if (value == null) {
      return null;
    }
    return _asString(value, fieldName);
  }

  int? _optionalInt(Object? value, String fieldName) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    throw MockConfigException('Expected an integer at $fieldName.');
  }

  double? _optionalDouble(Object? value, String fieldName) {
    if (value == null) {
      return null;
    }
    if (value is num) {
      return value.toDouble();
    }
    throw MockConfigException('Expected a number at $fieldName.');
  }

  num? _optionalNum(Object? value, String fieldName) {
    if (value == null) {
      return null;
    }
    if (value is num) {
      return value;
    }
    throw MockConfigException('Expected a number at $fieldName.');
  }

  DateTime? _optionalDateTime(Object? value, String fieldName) {
    if (value == null) {
      return null;
    }
    if (value is DateTime) {
      return value.toUtc();
    }
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) {
        return parsed.toUtc();
      }
    }
    throw MockConfigException(
      'Expected an ISO-8601 date/time value at $fieldName.',
    );
  }

  Object? _normalizeYaml(Object? value) {
    if (value is YamlMap) {
      return value.map((key, nestedValue) =>
          MapEntry(key.toString(), _normalizeYaml(nestedValue)));
    }
    if (value is YamlList) {
      return value.map(_normalizeYaml).toList(growable: false);
    }
    if (value is Map<Object?, Object?>) {
      return value.map((key, nestedValue) =>
          MapEntry(key.toString(), _normalizeYaml(nestedValue)));
    }
    if (value is List<Object?>) {
      return value.map(_normalizeYaml).toList(growable: false);
    }
    return value;
  }
}

/// Exception thrown when mock configuration is invalid.
class MockConfigException implements Exception {
  /// Creates a configuration exception with a readable message.
  MockConfigException(this.message);

  /// Validation or parsing failure message.
  final String message;

  @override
  String toString() => message;
}
