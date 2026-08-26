/// Identifier generation for runs, spans, messages, events and documents.
///
/// The framework identifies a very large number of short-lived objects, and
/// those identifiers end up in logs, traces, database rows and UI keys. The
/// requirements that follow from that are specific:
///
/// * **Lexicographically sortable.** Sorting event or message identifiers as
///   strings must reproduce creation order, so a log tail or a `ORDER BY id`
///   is chronological without a separate timestamp column.
/// * **Monotonic within a millisecond.** Agent loops emit many events per
///   millisecond; identifiers minted in the same tick must still order.
/// * **Collision-resistant across devices.** Offline-first clients generate
///   identifiers locally and reconcile later, with no coordinator to hand out
///   sequences.
/// * **Web-safe.** Flutter Web compiles `int` to a JavaScript double where
///   bitwise operators truncate to 32 bits. Every computation here uses `~/`
///   and `%` so the same identifiers are produced on every platform.
///
/// [Ulid] satisfies all four. Random v4 UUIDs fail the first two, and
/// timestamp-plus-counter schemes fail the third.
library;

import 'dart:math';

import 'package:meta/meta.dart';

/// Mints identifiers.
///
/// Injected rather than called statically so that tests can substitute a
/// deterministic sequence and assert on exact identifiers. Every framework
/// component that needs an identifier takes one of these, usually by way of
/// `AgenticContext`.
abstract interface class IdGenerator {
  /// Returns a new identifier.
  ///
  /// Implementations must be safe to call from a synchronous hot path: this is
  /// invoked once per event, per span and per message.
  String generate();
}

/// Generates ULIDs: 48 bits of timestamp followed by 80 bits of randomness,
/// rendered as 26 characters of Crockford base-32.
///
/// ```dart
/// final ids = Ulid();
/// ids.generate(); // 01JQ8XKF2M7YB4C3D5E6F7G8H9
/// ```
///
/// Within a single millisecond the random component is incremented rather than
/// redrawn, so identifiers minted in the same tick remain strictly increasing.
/// If the system clock moves backwards — a network time correction, a user
/// changing the device clock — generation continues from the last issued
/// timestamp instead of emitting an identifier that sorts before its
/// predecessor. Monotonicity of the identifier sequence is preserved at the
/// cost of the embedded timestamp briefly running ahead of the wall clock,
/// which is the right trade: the identifier is an ordering key first and a
/// timestamp second.
///
/// The random component is drawn from [Random] and is *not* a security token.
/// If an identifier must be unguessable — a share link, a session key — pass
/// `Random.secure()` explicitly and accept the throughput cost.
final class Ulid implements IdGenerator {
  /// Creates a generator.
  ///
  /// [random] defaults to a non-cryptographic [Random]; see the class
  /// documentation for when that matters. [now] defaults to the system clock
  /// and exists so that tests can drive time directly.
  Ulid({Random? random, DateTime Function()? now})
    : _random = random ?? Random(),
      _now = now ?? DateTime.timestamp;

  /// Crockford's base-32 alphabet: no `I`, `L`, `O` or `U`, so a
  /// hand-transcribed identifier cannot be corrupted by the usual confusions.
  static const String alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// Number of characters encoding the millisecond timestamp.
  static const int timeLength = 10;

  /// Number of characters encoding the random component.
  static const int randomLength = 16;

  /// Total length of a rendered ULID.
  static const int length = timeLength + randomLength;

  static const int _radix = 32;
  static const int _maxDigit = _radix - 1;

  final Random _random;
  final DateTime Function() _now;

  /// Base-32 digits of the current random component, most significant first.
  final List<int> _entropy = List<int>.filled(randomLength, 0);

  int _lastMillis = -1;

  @override
  String generate() {
    final millis = _now().millisecondsSinceEpoch;
    if (millis > _lastMillis) {
      _lastMillis = millis;
      _drawEntropy();
    } else {
      // Same millisecond, or a clock that moved backwards. Keep the previous
      // timestamp and step the random component so ordering still holds.
      if (!_incrementEntropy()) {
        // The 80-bit counter wrapped, which needs 2^80 identifiers inside one
        // millisecond. Redraw and step the timestamp so the sequence stays
        // strictly increasing even in that impossible case.
        _lastMillis += 1;
        _drawEntropy();
      }
    }
    return _encodeTime(_lastMillis) + _encodeEntropy();
  }

  void _drawEntropy() {
    for (var i = 0; i < randomLength; i++) {
      _entropy[i] = _random.nextInt(_radix);
    }
  }

  /// Adds one to the base-32 entropy counter.
  ///
  /// Returns `false` if the counter wrapped past its maximum value.
  bool _incrementEntropy() {
    for (var i = randomLength - 1; i >= 0; i--) {
      if (_entropy[i] < _maxDigit) {
        _entropy[i]++;
        return true;
      }
      _entropy[i] = 0;
    }
    return false;
  }

  String _encodeEntropy() {
    final buffer = StringBuffer();
    for (final digit in _entropy) {
      buffer.write(alphabet[digit]);
    }
    return buffer.toString();
  }

  /// Encodes [millis] as [timeLength] base-32 characters.
  ///
  /// Uses `~/` and `%` rather than shifts and masks: on Flutter Web the
  /// bitwise operators would silently truncate a 48-bit timestamp to 32 bits.
  static String _encodeTime(int millis) {
    final digits = List<int>.filled(timeLength, 0);
    var value = millis;
    for (var i = timeLength - 1; i >= 0; i--) {
      digits[i] = value % _radix;
      value = value ~/ _radix;
    }
    final buffer = StringBuffer();
    for (final digit in digits) {
      buffer.write(alphabet[digit]);
    }
    return buffer.toString();
  }

  /// Recovers the creation timestamp embedded in [ulid].
  ///
  /// Returns `null` if [ulid] is not a well-formed ULID. Useful for ordering
  /// or expiring records without carrying a separate timestamp column.
  static DateTime? timestampOf(String ulid) {
    if (ulid.length != length) return null;
    var millis = 0;
    for (var i = 0; i < timeLength; i++) {
      final digit = alphabet.indexOf(ulid[i]);
      if (digit < 0) return null;
      millis = millis * _radix + digit;
    }
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }
}

/// Produces predictable identifiers of the form `<prefix><n>`.
///
/// Intended for tests and for golden-file fixtures, where an assertion on an
/// exact identifier is far more readable than a regular expression.
///
/// ```dart
/// final ids = SequentialIdGenerator(prefix: 'run-');
/// ids.generate(); // 'run-1'
/// ids.generate(); // 'run-2'
/// ```
@visibleForTesting
final class SequentialIdGenerator implements IdGenerator {
  /// Creates a generator that counts up from [start].
  SequentialIdGenerator({this.prefix = 'id-', int start = 1}) : _next = start;

  /// Text placed before the counter.
  final String prefix;

  int _next;

  /// The value the next call to [generate] will use.
  int get nextValue => _next;

  @override
  String generate() => '$prefix${_next++}';
}

/// Attaches a human-readable namespace to a generated identifier.
///
/// Prefixed identifiers make logs and database rows self-describing: `run_`
/// and `msg_` tell a reader what they are looking at without a join. The
/// prefix precedes the sortable portion, so sorting still groups by kind and
/// then orders by time within each kind.
extension PrefixedIds on IdGenerator {
  /// Returns `<prefix>_<id>`.
  ///
  /// ```dart
  /// ids.prefixed('run'); // run_01JQ8XKF2M7YB4C3D5E6F7G8H9
  /// ```
  String prefixed(String prefix) => '${prefix}_${generate()}';
}
