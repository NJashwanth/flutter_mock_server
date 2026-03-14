import 'dart:math';

import 'package:uuid/uuid.dart';

import '../config/yaml_parser.dart';

/// Structured request data exposed to template placeholders.
class TemplateContext {
  /// Creates a request-aware template context.
  const TemplateContext({
    this.path = const {},
    this.query = const {},
    this.body,
    this.record,
    this.extra = const {},
  });

  /// Path parameters captured from routes such as `/users/:id`.
  final Map<String, String> path;

  /// Query parameters from the incoming request.
  final Map<String, String> query;

  /// Parsed request body, when one is present.
  final Object? body;

  /// Current store record being rendered, when applicable.
  final Map<String, Object?>? record;

  /// Additional arbitrary bindings.
  final Map<String, Object?> extra;
}

/// Expands template placeholders and generates model-backed data.
class TemplateEngine {
  /// Creates a template engine with an optional random source.
  TemplateEngine({Random? random}) : _random = random ?? Random();

  static final RegExp _templatePattern = RegExp(r'{{\s*([a-zA-Z0-9_\.]+)\s*}}');
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
  static const List<String> _sampleDomains = [
    'example.com',
    'mail.test',
    'mock.dev',
    'sample.app',
  ];
  static const List<String> _sampleWords = [
    'alpha',
    'beta',
    'gamma',
    'delta',
    'ember',
    'nova',
    'pulse',
    'river',
  ];

  final Random _random;
  final Uuid _uuid = const Uuid();

  /// Recursively renders placeholders within strings, maps, and lists.
  Object? render(Object? value,
      {TemplateContext context = const TemplateContext()}) {
    if (value is Map<String, Object?>) {
      return value.map(
        (key, nestedValue) =>
            MapEntry(key, render(nestedValue, context: context)),
      );
    }
    if (value is Map) {
      return value.map(
        (key, nestedValue) => MapEntry(
          key.toString(),
          render(nestedValue, context: context),
        ),
      );
    }
    if (value is List<Object?>) {
      return value
          .map((item) => render(item, context: context))
          .toList(growable: false);
    }
    if (value is String) {
      return _renderString(value, context);
    }
    return value;
  }

  /// Generates a record from a reusable model definition.
  Map<String, Object?> generateModel(
    MockModelDefinition model,
    Map<String, MockModelDefinition> models,
  ) {
    final record = <String, Object?>{};
    model.fields.forEach((fieldName, fieldDefinition) {
      record[fieldName] = _generateFieldValue(fieldDefinition, models);
    });
    return record;
  }

  Object? _generateFieldValue(
    MockFieldDefinition definition,
    Map<String, MockModelDefinition> models,
  ) {
    if (definition.example != null) {
      return render(definition.example);
    }

    if (definition.type == 'array') {
      final itemDefinition = definition.items ??
          MockFieldDefinition(
            type: 'string',
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
      final itemCount = definition.count ?? 0;
      return List<Object?>.generate(
        itemCount,
        (_) => _generateFieldValue(itemDefinition, models),
        growable: false,
      );
    }

    if (definition.count != null) {
      final itemDefinition = MockFieldDefinition(
        type: definition.type,
        min: definition.min,
        max: definition.max,
        items: definition.items,
        values: definition.values,
        example: definition.example,
        count: null,
        from: definition.from,
        to: definition.to,
        format: definition.format,
      );
      return List<Object?>.generate(
        definition.count!,
        (_) => _generateFieldValue(itemDefinition, models),
        growable: false,
      );
    }

    if (definition.values != null && definition.values!.isNotEmpty) {
      return definition.values![_random.nextInt(definition.values!.length)];
    }

    final type = definition.type;
    if (models.containsKey(type)) {
      return generateModel(models[type]!, models);
    }

    switch (type) {
      case 'uuid':
        return _uuid.v4();
      case 'name':
        return _sampleNames[_random.nextInt(_sampleNames.length)];
      case 'email':
        final name =
            _sampleNames[_random.nextInt(_sampleNames.length)].toLowerCase();
        final domain = _sampleDomains[_random.nextInt(_sampleDomains.length)];
        return '$name${_random.nextInt(90) + 10}@$domain';
      case 'timestamp':
        return DateTime.now().toUtc().toIso8601String();
      case 'date':
        return _randomDate(definition.from, definition.to, definition.format);
      case 'int':
        return _randomInt(definition.min?.toInt(), definition.max?.toInt());
      case 'double':
        return _randomDouble(
          definition.min?.toDouble(),
          definition.max?.toDouble(),
        );
      case 'bool':
        return _random.nextBool();
      case 'word':
        return _sampleWords[_random.nextInt(_sampleWords.length)];
      case 'sentence':
        return List<String>.generate(
          4,
          (_) => _sampleWords[_random.nextInt(_sampleWords.length)],
          growable: false,
        ).join(' ');
      case 'string':
      default:
        return _sampleWords[_random.nextInt(_sampleWords.length)];
    }
  }

  Object? _renderString(String input, TemplateContext context) {
    final singleMatch = _templatePattern.matchAsPrefix(input);
    if (singleMatch != null && singleMatch.group(0) == input) {
      final token = singleMatch.group(1) ?? '';
      return _resolveToken(token, context);
    }

    return input.replaceAllMapped(_templatePattern, (match) {
      final token = match.group(1) ?? '';
      final value = _resolveToken(token, context);
      return value?.toString() ?? '';
    });
  }

  Object? _resolveToken(String token, TemplateContext context) {
    switch (token) {
      case 'uuid':
        return _uuid.v4();
      case 'name':
        return _sampleNames[_random.nextInt(_sampleNames.length)];
      case 'timestamp':
        return DateTime.now().toUtc().toIso8601String();
      case 'email':
        final name =
            _sampleNames[_random.nextInt(_sampleNames.length)].toLowerCase();
        return '$name@${_sampleDomains[_random.nextInt(_sampleDomains.length)]}';
      default:
        return _lookupContext(token, context) ?? '{{$token}}';
    }
  }

  Object? _lookupContext(String token, TemplateContext context) {
    final segments = token.split('.');
    if (segments.isEmpty) {
      return null;
    }

    Object? current;
    switch (segments.first) {
      case 'request':
        if (segments.length < 2) {
          return null;
        }
        switch (segments[1]) {
          case 'path':
            current = context.path;
            break;
          case 'query':
            current = context.query;
            break;
          case 'body':
            current = context.body;
            break;
          default:
            return null;
        }
        return _walk(current, segments.skip(2));
      case 'record':
        return _walk(context.record, segments.skip(1));
      default:
        current = context.extra[segments.first];
        return _walk(current, segments.skip(1));
    }
  }

  Object? _walk(Object? current, Iterable<String> segments) {
    var value = current;
    for (final segment in segments) {
      if (value is Map) {
        value = value[segment];
        continue;
      }
      if (value is List) {
        final index = int.tryParse(segment);
        if (index == null || index < 0 || index >= value.length) {
          return null;
        }
        value = value[index];
        continue;
      }
      return null;
    }
    return value;
  }

  int _randomInt(int? min, int? max) {
    final lower = min ?? 0;
    final upper = max ?? 1000;
    if (upper <= lower) {
      return lower;
    }
    return lower + _random.nextInt(upper - lower + 1);
  }

  double _randomDouble(double? min, double? max) {
    final lower = min ?? 0;
    final upper = max ?? 1000;
    if (upper <= lower) {
      return lower;
    }
    final value = lower + _random.nextDouble() * (upper - lower);
    return double.parse(value.toStringAsFixed(2));
  }

  String _randomDate(DateTime? from, DateTime? to, String? format) {
    final lower =
        from ?? DateTime.now().toUtc().subtract(const Duration(days: 30));
    final upper = to ?? DateTime.now().toUtc().add(const Duration(days: 30));
    final normalizedLower = lower.toUtc();
    final normalizedUpper = upper.toUtc();
    final range = normalizedUpper.millisecondsSinceEpoch -
        normalizedLower.millisecondsSinceEpoch;
    final value = range <= 0
        ? normalizedLower
        : DateTime.fromMillisecondsSinceEpoch(
            normalizedLower.millisecondsSinceEpoch + _random.nextInt(range + 1),
            isUtc: true,
          );

    if (format == 'date') {
      return value.toIso8601String().split('T').first;
    }
    return value.toIso8601String();
  }
}
