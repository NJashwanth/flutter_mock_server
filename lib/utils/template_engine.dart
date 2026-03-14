import 'dart:math';

import 'package:uuid/uuid.dart';

/// Expands template placeholders in inline and file-based mock responses.
class TemplateEngine {
  /// Creates a template engine with an optional random source.
  TemplateEngine({Random? random}) : _random = random ?? Random();

  static final RegExp _templatePattern = RegExp(r'{{\s*([a-zA-Z0-9_]+)\s*}}');
  static const List<String> _sampleNames = [
    'Avery',
    'Casey',
    'Jordan',
    'Mina',
    'Noah',
    'Priya',
    'Sam',
    'Taylor',
  ];

  final Random _random;
  final Uuid _uuid = const Uuid();

  /// Recursively renders placeholders within strings, maps, and lists.
  Object? render(Object? value) {
    if (value is Map<String, Object?>) {
      return value
          .map((key, nestedValue) => MapEntry(key, render(nestedValue)));
    }
    if (value is List<Object?>) {
      return value.map(render).toList(growable: false);
    }
    if (value is String) {
      return _renderString(value);
    }
    return value;
  }

  String _renderString(String input) {
    return input.replaceAllMapped(_templatePattern, (match) {
      final token = match.group(1) ?? '';
      return _resolveToken(token);
    });
  }

  String _resolveToken(String token) {
    switch (token) {
      case 'uuid':
        return _uuid.v4();
      case 'name':
        return _sampleNames[_random.nextInt(_sampleNames.length)];
      case 'timestamp':
        return DateTime.now().toUtc().toIso8601String();
      default:
        return '{{$token}}';
    }
  }
}
