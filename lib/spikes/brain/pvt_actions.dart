import 'dart:convert';

import 'package:meta/meta.dart';

@immutable
sealed class PvtAction {
  const PvtAction();

  Map<String, Object?> toJson();

  static const allowList = <String>{
    'CLICK',
    'TYPE',
    'WAIT',
    'ABORT',
    'NOOP',
  };

  static PvtAction parseStrict(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('Action must be a JSON object.');
    }

    final action = json['action'];
    if (action is! String) {
      throw const FormatException('Missing or invalid "action".');
    }

    final normalized = action.trim().toUpperCase();
    if (!allowList.contains(normalized)) {
      throw FormatException('Action "$normalized" not in allow-list.');
    }

    final why = json['why'];
    if (why != null && why is! String) {
      throw const FormatException('"why" must be a string when present.');
    }

    switch (normalized) {
      case 'CLICK':
        final target = json['target'];
        if (target is! String || target.trim().isEmpty) {
          throw const FormatException('CLICK requires non-empty "target".');
        }
        return ClickAction(target: target, why: why as String?);
      case 'TYPE':
        final text = json['text'];
        if (text is! String) {
          throw const FormatException('TYPE requires "text" string.');
        }
        return TypeAction(text: text, why: why as String?);
      case 'WAIT':
        final ms = json['ms'];
        if (ms is! num) {
          throw const FormatException('WAIT requires "ms" number.');
        }
        return WaitAction(ms: ms.toInt(), why: why as String?);
      case 'ABORT':
        return AbortAction(why: why as String?);
      case 'NOOP':
        return NoopAction(why: why as String?);
    }

    // Should be unreachable due to allow-list.
    throw FormatException('Unhandled action "$normalized".');
  }

  static String schemaDescription() {
    return const JsonEncoder.withIndent('  ').convert({
      'action': 'CLICK|TYPE|WAIT|ABORT|NOOP',
      'target': 'required when action=CLICK',
      'text': 'required when action=TYPE',
      'ms': 'required when action=WAIT',
      'why': 'optional short reason (string)',
    });
  }
}

@immutable
class ClickAction extends PvtAction {
  const ClickAction({required this.target, this.why});

  final String target;
  final String? why;

  @override
  Map<String, Object?> toJson() => {
        'action': 'CLICK',
        'target': target,
        'why': why,
      };
}

@immutable
class TypeAction extends PvtAction {
  const TypeAction({required this.text, this.why});

  final String text;
  final String? why;

  @override
  Map<String, Object?> toJson() => {
        'action': 'TYPE',
        'text': text,
        'why': why,
      };
}

@immutable
class WaitAction extends PvtAction {
  const WaitAction({required this.ms, this.why});

  final int ms;
  final String? why;

  @override
  Map<String, Object?> toJson() => {
        'action': 'WAIT',
        'ms': ms,
        'why': why,
      };
}

@immutable
class AbortAction extends PvtAction {
  const AbortAction({this.why});

  final String? why;

  @override
  Map<String, Object?> toJson() => {
        'action': 'ABORT',
        'why': why,
      };
}

@immutable
class NoopAction extends PvtAction {
  const NoopAction({this.why});

  final String? why;

  @override
  Map<String, Object?> toJson() => {
        'action': 'NOOP',
        'why': why,
      };
}
