/// Models that write cassettes and models that play them back.
library;

import 'dart:async';
import 'dart:io';

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:agentic_test/src/cassette/cassette.dart';

/// Wraps a real model and records every completed exchange.
///
/// Only answers are recorded. A failed call is rethrown and leaves nothing
/// behind: replaying a rate limit or an outage forever is rarely what a test
/// wants, and `FakeChatModel.failing` scripts those precisely.
///
/// A stream is recorded once it finishes. One the caller abandons midway is
/// not, because there is no complete answer to replay.
final class RecordingChatModel extends DelegatingChatModel {
  /// Records exchanges with [inner] into [cassette].
  ///
  /// [onRecorded] runs after each exchange is added — [cassetteModel] uses it
  /// to write the file immediately, so a test that crashes halfway still
  /// leaves the exchanges it completed.
  RecordingChatModel(
    super.inner, {
    Cassette? cassette,
    this.redact,
    this.onRecorded,
  }) : cassette = cassette ?? Cassette(model: inner.info);

  /// Where exchanges are recorded.
  final Cassette cassette;

  /// Applied to every string before it is recorded.
  final Redactor? redact;

  /// Called after each exchange is recorded.
  final void Function(Cassette cassette)? onRecorded;

  @override
  Future<ChatResponse> generate(
    ChatRequest request, {
    AgenticContext? context,
  }) async {
    final response = await inner.generate(request, context: context);
    _record(request, response);
    return response;
  }

  @override
  Stream<ChatChunk> stream(
    ChatRequest request, {
    AgenticContext? context,
  }) async* {
    final builder = ChatResponseBuilder(modelId: inner.info.id);
    await for (final chunk in inner.stream(request, context: context)) {
      builder.add(chunk);
      yield chunk;
    }
    _record(request, builder.build());
  }

  void _record(ChatRequest request, ChatResponse response) {
    cassette.add(
      CassetteInteraction(
        request: canonicalRequest(request, redact: redact),
        response: encodeResponse(response, redact: redact),
      ),
    );
    onRecorded?.call(cassette);
  }
}

/// A model that answers from a [Cassette], offline.
///
/// Each request is matched against the recording by its canonical form, and
/// each recorded exchange answers once. Matching ignores the order exchanges
/// were recorded in, so agents that call the model concurrently — a
/// supervisor fanning out to workers — replay reliably; identical requests are
/// answered in recorded order.
///
/// A request with no match throws a [CassetteMismatchError] naming the first
/// difference from the closest recording.
final class ReplayChatModel implements ChatModel {
  /// Replays [cassette].
  ///
  /// [redact] must be the function the cassette was recorded with, so the live
  /// request is compared in the same redacted form.
  ReplayChatModel(this.cassette, {this.redact})
    : _used = List<bool>.filled(cassette.interactions.length, false);

  /// The recording being replayed.
  final Cassette cassette;

  /// Applied to each live request before matching.
  final Redactor? redact;

  final List<bool> _used;

  @override
  ModelInfo get info => cassette.model;

  /// How many recorded exchanges have not been replayed yet.
  int get remaining => _used.where((used) => !used).length;

  /// Throws if any recorded exchange was never asked for.
  ///
  /// Call it at the end of a test to catch the opposite failure to a mismatch:
  /// an agent that now stops earlier than it did when recorded — one tool call
  /// fewer, a step skipped — answers every request it makes and would
  /// otherwise pass.
  void verifyExhausted() {
    if (remaining == 0) return;
    throw CassetteMismatchError(
      '$remaining of ${_used.length} recorded exchanges were never replayed. '
      'The code under test made fewer model calls than when the cassette was '
      'recorded.',
    );
  }

  @override
  Future<ChatResponse> generate(
    ChatRequest request, {
    AgenticContext? context,
  }) async {
    context?.throwIfCancelled();
    return _answer(request).copyWith(metadata: request.metadata);
  }

  @override
  Stream<ChatChunk> stream(
    ChatRequest request, {
    AgenticContext? context,
  }) async* {
    context?.throwIfCancelled();
    final response = _answer(request);
    final message = response.message;
    if (message.reasoning case final reasoning?) {
      yield ChatChunk.reasoning(reasoning);
    }
    if (message.text.isNotEmpty) yield ChatChunk.text(message.text);
    for (var i = 0; i < message.toolCalls.length; i++) {
      final call = message.toolCalls[i];
      yield ChatChunk.tool(
        ToolCallDelta(
          index: i,
          id: call.id,
          name: call.name,
          argumentsDelta: call.argumentsJson,
        ),
      );
    }
    yield ChatChunk(
      finishReason: response.finishReason,
      usage: response.usage,
      modelId: response.modelId,
      requestId: response.requestId,
    );
  }

  ChatResponse _answer(ChatRequest request) {
    final actual = canonicalRequest(request, redact: redact);
    final key = _keyOf(actual);
    final interactions = cassette.interactions;
    for (var i = 0; i < interactions.length; i++) {
      if (_used[i] || _keyOf(interactions[i].request) != key) continue;
      _used[i] = true;
      return interactions[i].chatResponse;
    }
    throw CassetteMismatchError(_describeMiss(actual));
  }

  String _describeMiss(JsonMap actual) {
    final interactions = cassette.interactions;
    if (interactions.isEmpty) {
      return 'The cassette is empty, so no request can be answered.';
    }
    final key = _keyOf(actual);
    final alreadyUsed = <int>[
      for (var i = 0; i < interactions.length; i++)
        if (_used[i] && _keyOf(interactions[i].request) == key) i,
    ];
    if (alreadyUsed.isNotEmpty) {
      return 'This request was recorded ${alreadyUsed.length} time(s), and '
          'every recording has already been replayed. The code under test '
          'now asks it more often than when the cassette was recorded.';
    }
    // The closest recording is the unused one sharing the longest prefix of
    // messages — normally the same step of the same conversation.
    var best = -1;
    var bestShared = -1;
    for (var i = 0; i < interactions.length; i++) {
      if (_used[i]) continue;
      final shared = _sharedMessages(interactions[i].request, actual);
      if (shared > bestShared) {
        best = i;
        bestShared = shared;
      }
    }
    if (best < 0) {
      return 'Every recorded exchange has already been replayed. The code '
          'under test makes more model calls than when the cassette was '
          'recorded.';
    }
    return 'No recorded exchange matches this request. Compared with '
        'recording #$best:\n'
        '${describeRequestDifference(interactions[best].request, actual)}\n'
        'If the change is intended, record the cassette again.';
  }

  static int _sharedMessages(JsonMap recorded, JsonMap actual) {
    final a = recorded['messages']! as List<Object?>;
    final b = actual['messages']! as List<Object?>;
    var shared = 0;
    while (shared < a.length &&
        shared < b.length &&
        _keyOf(a[shared]) == _keyOf(b[shared])) {
      shared++;
    }
    return shared;
  }

  static String _keyOf(Object? json) => canonicalJsonKey(json);

  @override
  Future<void> dispose() async {}

  @override
  String toString() =>
      'ReplayChatModel(${cassette.model.id}, $remaining remaining)';
}

/// How [cassetteModel] decides between the network and the file.
enum CassetteMode {
  /// Replay when the cassette exists; record when it does not.
  ///
  /// The default. The first run of a new test needs a key and records; every
  /// run after is offline. Setting `AGENTIC_RECORD=1` records again.
  auto,

  /// Always call the live model and overwrite the cassette.
  record,

  /// Always replay; fail when the cassette is missing.
  ///
  /// What CI should use, so a forgotten cassette fails loudly instead of
  /// quietly spending money with a key someone left in the environment.
  replay,
}

/// A model backed by the cassette at [path].
///
/// ```dart
/// final model = cassetteModel(
///   'test/cassettes/weather_agent.json',
///   live: () => GeminiChatModel(apiKey: Platform.environment['GEMINI_API_KEY']!),
/// );
/// ```
///
/// [live] is a function so that replaying never constructs the real model,
/// and so never needs its key. With [CassetteMode.auto], the environment
/// variable `AGENTIC_RECORD=1` switches to recording.
///
/// A recording is written after every exchange, starting from an empty
/// cassette, so re-recording never mixes old and new answers.
ChatModel cassetteModel(
  String path, {
  required ChatModel Function() live,
  CassetteMode mode = CassetteMode.auto,
  Redactor? redact,
  Map<String, String>? environment,
}) {
  final file = File(path);
  final env = environment ?? Platform.environment;
  final record = switch (mode) {
    CassetteMode.record => true,
    CassetteMode.replay => false,
    CassetteMode.auto => env['AGENTIC_RECORD'] == '1' || !file.existsSync(),
  };

  if (!record) {
    if (!file.existsSync()) {
      throw StateError(
        'No cassette at $path. Record it once with a real model: run the test '
        'with AGENTIC_RECORD=1 and a provider key, then commit the file.',
      );
    }
    return ReplayChatModel(
      Cassette.parse(file.readAsStringSync()),
      redact: redact,
    );
  }

  final model = live();
  return RecordingChatModel(
    model,
    redact: redact,
    onRecorded: (cassette) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(cassette.encode());
    },
  );
}
