import 'package:agentic_core/agentic_core.dart';
import 'package:test/test.dart';

void main() {
  group('UntrustedContentLedger', () {
    test('starts clean', () {
      final ledger = UntrustedContentLedger();
      expect(ledger.isTainted, isFalse);
      expect(ledger.sources, isEmpty);
    });

    test('records sources in arrival order, once each', () {
      final ledger = UntrustedContentLedger()
        ..record('search_notes')
        ..record('fetch_page')
        ..record('search_notes');
      expect(ledger.isTainted, isTrue);
      expect(ledger.sources, <String>['search_notes', 'fetch_page']);
    });

    test('the sources it hands out cannot be edited to clear the taint', () {
      // Content a model has read cannot be un-read, so there is deliberately
      // no path — not even a mutable list — back to a clean ledger.
      final ledger = UntrustedContentLedger()..record('search_notes');
      expect(() => ledger.sources.clear(), throwsUnsupportedError);
      expect(ledger.isTainted, isTrue);
    });
  });

  group('AgenticContext', () {
    test('shares one ledger with every descendant', () {
      final root = AgenticContext.root();
      root.child('agent').child('tool').untrustedContent.record('mcp_fetch');

      expect(root.untrustedContent.sources, <String>['mcp_fetch']);
    });

    test('separate runs do not share a ledger', () {
      AgenticContext.root().untrustedContent.record('search_notes');
      expect(AgenticContext.root().untrustedContent.isTainted, isFalse);
    });
  });
}
