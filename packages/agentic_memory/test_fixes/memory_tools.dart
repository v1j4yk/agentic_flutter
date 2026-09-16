// Written against the 0.1 API. `dart fix --compare-to-golden` applies
// lib/fix_data.yaml to this file and compares the result with the .expect
// file beside it.
import 'package:agentic_memory/agentic_memory.dart';

void main() {
  final store = InMemoryMemoryStore();
  memoryTools(store);
  memoryTools(store, sessionId: 's1', includeForget: true);
  rememberTool(store, agentName: 'assistant');
  recallTool(store);
  forgetTool(store);
}
