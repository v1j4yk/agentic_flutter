/// Test doubles for code built on `agentic_llm`.
///
/// Kept in a separate entry point so production builds never carry test
/// scaffolding, while applications and third-party plugins test against the
/// same doubles the framework uses on itself.
///
/// ```dart
/// import 'package:agentic_llm/testing.dart';
///
/// final model = FakeChatModel.toolCall(
///   toolCalls: [ToolCallPart(id: 'c1', name: 'search_web', arguments: {'query': 'dart'})],
///   then: 'Dart 3 added records and patterns.',
/// );
///
/// await agent.run('What is new in Dart 3?');
/// expect(model.callCount, 2);
/// ```
library;

export 'src/testing/fake_chat_model.dart'
    show FakeChatModel, FakeEmbeddingModel, FakeTurn;
