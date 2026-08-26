import 'dart:async';

import 'package:agentic_core/agentic_core.dart';
import 'package:test/test.dart';

final class StepStarted extends AgenticEvent {
  const StepStarted({
    required super.id,
    required super.timestamp,
    required this.step,
    super.runId,
  });

  final String step;

  @override
  String get type => 'agent.step.started';

  @override
  JsonMap payload() => <String, Object?>{'step': step};
}

final class StepFinished extends AgenticEvent {
  const StepFinished({
    required super.id,
    required super.timestamp,
    super.runId,
  });

  @override
  String get type => 'agent.step.finished';

  @override
  JsonMap payload() => const <String, Object?>{};
}

StepStarted started(String id, {String step = 'plan', String? runId}) =>
    StepStarted(
      id: id,
      timestamp: DateTime.utc(2026),
      step: step,
      runId: runId,
    );

void main() {
  group('BroadcastEventBus', () {
    late BroadcastEventBus bus;

    setUp(() => bus = BroadcastEventBus());
    tearDown(() => bus.dispose());

    test('delivers published events to subscribers', () async {
      final received = <AgenticEvent>[];
      final subscription = bus.events.listen(received.add);

      bus.publish(started('e1'));
      await Future<void>.delayed(Duration.zero);

      expect(received.map((e) => e.id), <String>['e1']);
      await subscription.cancel();
    });

    test('on<T> filters by concrete event type', () async {
      final steps = <StepStarted>[];
      final subscription = bus.on<StepStarted>().listen(steps.add);

      bus
        ..publish(started('e1'))
        ..publish(StepFinished(id: 'e2', timestamp: DateTime.utc(2026)));
      await Future<void>.delayed(Duration.zero);

      expect(steps.map((e) => e.id), <String>['e1']);
      await subscription.cancel();
    });

    test('replays recent events to a late subscriber', () async {
      // The bug this prevents: a Flutter widget subscribes one frame after the
      // run starts and never sees the first events.
      bus
        ..publish(started('e1'))
        ..publish(started('e2'));

      final received = <String>[];
      final subscription = bus.on<StepStarted>().listen(
        (e) => received.add(e.id),
      );
      await Future<void>.delayed(Duration.zero);

      bus.publish(started('e3'));
      await Future<void>.delayed(Duration.zero);

      expect(received, <String>['e1', 'e2', 'e3']);
      await subscription.cancel();
    });

    test('bounds the replay buffer', () async {
      final bounded = BroadcastEventBus(replayBufferSize: 2);
      for (var i = 1; i <= 5; i++) {
        bounded.publish(started('e$i'));
      }

      expect(bounded.replayBuffer.map((e) => e.id), <String>['e4', 'e5']);
      await bounded.dispose();
    });

    test('replay can be disabled', () async {
      final noReplay = BroadcastEventBus(replayBufferSize: 0)
        ..publish(started('e1'));

      final received = <String>[];
      final subscription = noReplay.on<StepStarted>().listen(
        (e) => received.add(e.id),
      );
      await Future<void>.delayed(Duration.zero);

      expect(received, isEmpty);
      await subscription.cancel();
      await noReplay.dispose();
    });

    test('clearReplay drops history without closing the bus', () async {
      bus
        ..publish(started('e1'))
        ..clearReplay();

      expect(bus.replayBuffer, isEmpty);
      expect(bus.isClosed, isFalse);
    });

    test('forRun filters by run identifier', () async {
      final received = <String>[];
      final subscription = bus
          .forRun<StepStarted>('run-a')
          .listen((e) => received.add(e.id));

      bus
        ..publish(started('e1', runId: 'run-a'))
        ..publish(started('e2', runId: 'run-b'));
      await Future<void>.delayed(Duration.zero);

      expect(received, <String>['e1']);
      await subscription.cancel();
    });

    test('next completes on the first matching event', () async {
      final pending = bus.next<StepFinished>();

      bus
        ..publish(started('e1'))
        ..publish(StepFinished(id: 'e2', timestamp: DateTime.utc(2026)));

      expect((await pending).id, 'e2');
    });

    test('collect gathers events until a signal completes', () async {
      final gate = Completer<void>();
      final pending = bus.collect<StepStarted>(gate.future);

      await Future<void>.delayed(Duration.zero);
      bus
        ..publish(started('e1'))
        ..publish(started('e2'));
      await Future<void>.delayed(Duration.zero);
      gate.complete();

      expect((await pending).map((e) => e.id), <String>['e1', 'e2']);
    });

    test('publishing after dispose is dropped, counted and reported', () async {
      final dropped = <AgenticEvent>[];
      final closing = BroadcastEventBus(onDropped: dropped.add);

      await closing.dispose();
      closing.publish(started('late'));

      expect(closing.droppedCount, 1);
      expect(dropped.single.id, 'late');
      expect(closing.publishedCount, 0);
    });

    test('dispose is idempotent', () async {
      await bus.dispose();
      await expectLater(bus.dispose(), completes);
    });
  });

  group('AgenticEvent', () {
    test('serialises envelope and payload together', () {
      final json = started('e1', runId: 'run-1').toJson();

      expect(json['id'], 'e1');
      expect(json['type'], 'agent.step.started');
      expect(json['runId'], 'run-1');
      expect(json['step'], 'plan');
    });

    test('omits absent envelope fields', () {
      expect(started('e1').toJson().containsKey('runId'), isFalse);
    });

    test('GenericEvent carries an arbitrary payload', () {
      final event = GenericEvent(
        id: 'g1',
        timestamp: DateTime.utc(2026),
        type: 'app.checkpoint',
        data: {'progress': 0.5},
      );

      expect(event.toJson()['progress'], 0.5);
      expect(() => event.data['x'] = 1, throwsUnsupportedError);
    });
  });

  group('NoopEventBus', () {
    test('accepts publications and delivers nothing', () async {
      const bus = NoopEventBus();
      final received = <AgenticEvent>[];
      final subscription = bus.events.listen(received.add);

      bus.publish(started('e1'));
      await Future<void>.delayed(Duration.zero);

      expect(received, isEmpty);
      await subscription.cancel();
    });
  });
}
