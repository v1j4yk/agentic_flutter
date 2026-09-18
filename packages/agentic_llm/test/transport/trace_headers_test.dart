/// A provider call carries the trace it belongs to.
///
/// The provider will not read `traceparent`, but a proxy, a gateway or your own
/// backend in front of one will — and without it the span for "the model call"
/// and the span for "the request that reached our proxy" are two unrelated
/// traces.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_llm/agentic_llm.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

(http.Client, List<http.Request>) recordingClient() {
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    requests.add(request);
    return http.Response(
      '{"choices":[{"message":{"role":"assistant","content":"hi"},'
      '"finish_reason":"stop"}],"model":"m"}',
      200,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  });
  return (client, requests);
}

void main() {
  test('a request carries the run trace when the context has one', () async {
    final (client, requests) = recordingClient();
    final model = OpenAiCompatibleChatModel.openAi(
      apiKey: 'sk-test',
      client: client,
    );
    final context = AgenticContext.root(
      traceContext: const TraceContext(
        traceId: '4bf92f3577b34da6a3ce929d0e0e4736',
        spanId: '00f067aa0ba902b7',
        traceState: 'vendor=abc',
      ),
    );

    await model.generate(ChatRequest.prompt('hello'), context: context);

    final headers = requests.single.headers;
    expect(
      headers['traceparent'],
      '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
    );
    expect(headers['tracestate'], 'vendor=abc');
    await model.dispose();
  });

  test('no context, no trace headers — and no crash', () async {
    final (client, requests) = recordingClient();
    final model = OpenAiCompatibleChatModel.openAi(
      apiKey: 'sk-test',
      client: client,
    );

    await model.generate(ChatRequest.prompt('hello'));

    expect(requests.single.headers.containsKey('traceparent'), isFalse);
    await model.dispose();
  });

  test('authentication is never displaced by a trace header', () async {
    // The trace headers are merged *under* the configured ones, so a caller
    // cannot lose their credentials to a name collision.
    final (client, requests) = recordingClient();
    final model = OpenAiCompatibleChatModel.openAi(
      apiKey: 'sk-test',
      client: client,
    );

    await model.generate(
      ChatRequest.prompt('hello'),
      context: AgenticContext.root(
        traceContext: const TraceContext(
          traceId: '4bf92f3577b34da6a3ce929d0e0e4736',
          spanId: '00f067aa0ba902b7',
        ),
      ),
    );

    expect(requests.single.headers['authorization'], 'Bearer sk-test');
    expect(requests.single.headers['content-type'], contains('json'));
    await model.dispose();
  });

  test('the listing call carries it too', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response(
        '{"data":[{"id":"gpt-5.6"}]}',
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      );
    });
    final model = OpenAiCompatibleChatModel.openAi(
      apiKey: 'sk-test',
      client: client,
    );

    await model.listModels(
      context: AgenticContext.root(
        traceContext: const TraceContext(
          traceId: '4bf92f3577b34da6a3ce929d0e0e4736',
          spanId: '00f067aa0ba902b7',
        ),
      ),
    );

    expect(requests.single.headers.containsKey('traceparent'), isTrue);
    await model.dispose();
  });
}
