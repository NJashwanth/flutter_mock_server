import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

/// Parsed representation of a `mock.yaml` file.
class MockConfig {
  /// Creates a parsed mock configuration.
  MockConfig({
    required this.sourcePath,
    required this.routes,
  });

  /// Absolute or normalized source path of the loaded YAML file.
  final String sourcePath;

  /// Route definitions loaded from the YAML document.
  final List<MockRoute> routes;
}

/// A single route entry declared in `mock.yaml`.
class MockRoute {
  /// Creates a route with an HTTP method, path, and response.
  MockRoute({
    required this.path,
    required this.method,
    required this.response,
  });

  /// Raw route path as declared in YAML.
  final String path;

  /// HTTP method for the route.
  final String method;

  /// Response configuration for the route.
  final MockResponse response;

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
    final routesNode = root['routes'];
    final routesList = _asList(routesNode, 'routes');

    final routes = <MockRoute>[];
    for (var index = 0; index < routesList.length; index++) {
      final routeMap = _asMap(routesList[index], 'routes[$index]');
      routes.add(_parseRoute(routeMap, index));
    }

    if (routes.isEmpty) {
      throw MockConfigException(
          'Configuration must define at least one route.');
    }

    return MockConfig(
      sourcePath: path.normalize(sourcePath),
      routes: routes,
    );
  }

  MockRoute _parseRoute(Map<Object?, Object?> rawRoute, int index) {
    final routePath = _asString(rawRoute['path'], 'routes[$index].path');
    final method =
        _asString(rawRoute['method'], 'routes[$index].method').toUpperCase();
    const supportedMethods = {'GET', 'POST', 'PUT', 'DELETE'};
    if (!supportedMethods.contains(method)) {
      throw MockConfigException(
        'Unsupported method "$method" at routes[$index].method. Expected one of ${supportedMethods.join(', ')}.',
      );
    }

    final response = _parseResponse(
      rawRoute['response'],
      pathPrefix: 'routes[$index].response',
      defaultStatus: method == 'POST' ? 201 : 200,
    );

    return MockRoute(
      path: routePath,
      method: method,
      response: response,
    );
  }

  MockResponse _parseResponse(
    Object? rawResponse, {
    required String pathPrefix,
    required int defaultStatus,
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

    if (file == null && body == null) {
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
