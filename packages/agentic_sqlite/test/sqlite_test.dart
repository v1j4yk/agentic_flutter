import 'dart:io';
import 'dart:typed_data';

import 'package:agentic_agents/agentic_agents.dart';
import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_core/testing.dart';
import 'package:agentic_memory/agentic_memory.dart';
import 'package:agentic_sqlite/agentic_sqlite.dart';
import 'package:agentic_vector/agentic_vector.dart';
import 'package:agentic_workflow/agentic_workflow.dart';
import 'package:test/test.dart';

/// Nearly every test here closes the database and opens the file again.
/// Surviving a restart is the only thing this package claims, so a test that
/// never reopens anything would be testing `InMemoryVectorStore` twice.
void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('agentic_sqlite_test');
    path = '${dir.path}${Platform.pathSeparator}agentic.db';
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// Opens [path], runs [body], and always closes it again.
  Future<T> withDb<T>(Future<T> Function(AgenticDatabase db) body) async {
    final db = await AgenticDatabase.open(path);
    try {
      return await body(db);
    } finally {
      await db.dispose();
    }
  }

  VectorRecord record(
    String id,
    List<double> vector, {
    JsonMap metadata = const <String, Object?>{},
    String? text,
  }) => VectorRecord(id: id, vector: vector, metadata: metadata, text: text);

  group('AgenticDatabase', () {
    test('creates a file and reopens it', () async {
      await withDb((db) async {});
      expect(File(path).existsSync(), isTrue);
      await withDb((db) async {});
    });

    test('refuses a file written by a newer schema', () async {
      // An upgrade followed by a downgrade must not write to a schema this
      // build does not understand.
      await withDb((db) async {
        db.connection.userVersion = AgenticDatabase.schemaVersion + 1;
      });
      await expectLater(
        AgenticDatabase.open(path),
        throwsA(
          isA<StorageException>().having(
            (e) => e.message,
            'message',
            contains('newer version'),
          ),
        ),
      );
    });

    test('upgrades a schema 1 file in place, keeping its data', () async {
      // A real upgrade, not a fresh file: build the current schema, strip it
      // back to exactly what schema 1 had, then reopen.
      await withDb((db) async {
        final notes = await db.vectorStore(name: 'notes', dimensions: 2);
        await notes.upsert(<VectorRecord>[
          record('kept', <double>[1, 0]),
        ]);
        await notes.dispose();
        db.connection
          ..execute('DROP TABLE sessions')
          ..execute('DROP TABLE workflow_snapshots')
          ..userVersion = 1;
      });

      await withDb((db) async {
        expect(db.connection.userVersion, AgenticDatabase.schemaVersion);
        final notes = await db.vectorStore(name: 'notes', dimensions: 2);
        expect(await notes.get('kept'), isNotNull);
        // The tables schema 2 adds are usable.
        final chats = db.sessionStore();
        await chats.save(AgentSession(id: 's1'));
        expect(await chats.list(), hasLength(1));
      });
    });

    test('a disposed database says so rather than crashing', () async {
      final db = await AgenticDatabase.open(path);
      await db.dispose();
      await expectLater(
        db.vectorStore(name: 'notes', dimensions: 3),
        throwsA(isA<InvalidStateException>()),
      );
    });

    test('a collection cannot be open twice at once', () async {
      // Two stores over the same rows would each keep a copy in memory, and
      // the second write would make the first store's searches stale.
      await withDb((db) async {
        final first = await db.vectorStore(name: 'notes', dimensions: 3);
        await expectLater(
          db.vectorStore(name: 'notes', dimensions: 3),
          throwsA(isA<InvalidStateException>()),
        );
        await first.dispose();
        // Released on dispose.
        final again = await db.vectorStore(name: 'notes', dimensions: 3);
        await again.dispose();
      });
    });

    test('a vector and a memory store may share a name', () async {
      await withDb((db) async {
        final vectors = await db.vectorStore(name: 'shared', dimensions: 3);
        final memory = await db.memoryStore(name: 'shared');
        await vectors.dispose();
        await memory.dispose();
      });
    });
  });

  group('SqliteVectorStore', () {
    test('records survive a restart, with metadata and text', () async {
      await withDb((db) async {
        final store = await db.vectorStore(name: 'notes', dimensions: 3);
        await store.upsert(<VectorRecord>[
          record(
            'a',
            <double>[1, 0, 0],
            metadata: <String, Object?>{
              'title': 'Standup',
              'tags': <String>['team'],
            },
            text: 'Priya has checkout behind a flag.',
          ),
          record('b', <double>[0, 1, 0]),
        ]);
      });

      await withDb((db) async {
        final store = await db.vectorStore(name: 'notes', dimensions: 3);
        expect(await store.count(), 2);

        final matches = await store.search(
          VectorQuery(vector: <double>[0.9, 0.1, 0], topK: 1),
        );
        expect(matches.single.record.id, 'a');
        expect(matches.single.record.metadata['title'], 'Standup');
        expect(matches.single.record.metadata['tags'], <String>['team']);
        expect(matches.single.record.text, contains('Priya'));
      });
    });

    test('vectors come back to float32 precision', () async {
      const value = 0.123456789012345;
      await withDb((db) async {
        final store = await db.vectorStore(name: 'v', dimensions: 2);
        await store.upsert(<VectorRecord>[
          record('a', <double>[value, -value]),
        ]);
      });
      await withDb((db) async {
        final store = await db.vectorStore(name: 'v', dimensions: 2);
        final back = (await store.get('a'))!.vector;
        expect(back[0], closeTo(value, 1e-7));
        expect(back[1], closeTo(-value, 1e-7));
      });
    });

    test('ranks exactly as the in-memory store does', () async {
      // Search is delegated, so this is a guard against the loaded records
      // differing from the saved ones, not a test of ranking itself.
      final records = <VectorRecord>[
        for (var i = 0; i < 40; i++)
          record('r$i', <double>[(i % 7) / 7, (i % 5) / 5, (i % 3) / 3 + 0.01]),
      ];
      final query = VectorQuery(vector: <double>[0.4, 0.2, 0.9], topK: 10);

      final reference = InMemoryVectorStore(dimensions: 3);
      await reference.upsert(records);
      final expected = (await reference.search(
        query,
      )).map((m) => m.record.id).toList();

      await withDb((db) async {
        final store = await db.vectorStore(name: 'parity', dimensions: 3);
        await store.upsert(records);
      });
      await withDb((db) async {
        final store = await db.vectorStore(name: 'parity', dimensions: 3);
        final actual = (await store.search(
          query,
        )).map((m) => m.record.id).toList();
        expect(actual, expected);
      });
    });

    test('namespaces are kept apart across a restart', () async {
      await withDb((db) async {
        final store = await db.vectorStore(name: 'ns', dimensions: 2);
        await store.upsert(<VectorRecord>[
          record('x', <double>[1, 0]),
        ]);
        await store.upsert(<VectorRecord>[
          record('x', <double>[0, 1]),
        ], namespace: 'work');
      });
      await withDb((db) async {
        final store = await db.vectorStore(name: 'ns', dimensions: 2);
        expect((await store.get('x'))!.vector[0], 1);
        expect((await store.get('x', namespace: 'work'))!.vector[1], 1);
        expect(await store.count(namespace: 'work'), 1);
        expect(await store.count(), 2, reason: 'null counts every namespace');
      });
    });

    test('a delete survives a restart', () async {
      await withDb((db) async {
        final store = await db.vectorStore(name: 'd', dimensions: 2);
        await store.upsert(<VectorRecord>[
          record('a', <double>[1, 0]),
          record('b', <double>[0, 1]),
        ]);
        expect(await store.delete(<String>['a', 'missing']), 1);
      });
      await withDb((db) async {
        final store = await db.vectorStore(name: 'd', dimensions: 2);
        expect(await store.get('a'), isNull);
        expect(await store.get('b'), isNotNull);
      });
    });

    test('deleteWhere with no namespace reaches every namespace', () async {
      // Mirrors InMemoryVectorStore exactly: null is "all" here, but "the
      // default" for upsert, get and delete.
      await withDb((db) async {
        final store = await db.vectorStore(name: 'dw', dimensions: 2);
        await store.upsert(<VectorRecord>[
          record('a', <double>[1, 0], metadata: <String, Object?>{'doc': 1}),
          record('b', <double>[0, 1], metadata: <String, Object?>{'doc': 2}),
        ]);
        await store.upsert(<VectorRecord>[
          record('c', <double>[1, 1], metadata: <String, Object?>{'doc': 1}),
        ], namespace: 'other');

        expect(await store.deleteWhere(const EqualsFilter('doc', 1)), 2);
      });
      await withDb((db) async {
        final store = await db.vectorStore(name: 'dw', dimensions: 2);
        expect(await store.count(), 1);
        expect(await store.get('b'), isNotNull);
      });
    });

    test('clearing one namespace leaves the others', () async {
      await withDb((db) async {
        final store = await db.vectorStore(name: 'c', dimensions: 2);
        await store.upsert(<VectorRecord>[
          record('a', <double>[1, 0]),
        ]);
        await store.upsert(<VectorRecord>[
          record('b', <double>[0, 1]),
        ], namespace: 'scratch');
        await store.clear(namespace: 'scratch');
      });
      await withDb((db) async {
        final store = await db.vectorStore(name: 'c', dimensions: 2);
        expect(await store.count(), 1);
        await store.clear();
      });
      await withDb((db) async {
        final store = await db.vectorStore(name: 'c', dimensions: 2);
        expect(await store.count(), 0);
      });
    });

    test('a batch with a wrong-sized vector writes none of it', () async {
      await withDb((db) async {
        final store = await db.vectorStore(name: 'bad', dimensions: 3);
        await expectLater(
          store.upsert(<VectorRecord>[
            record('ok', <double>[1, 0, 0]),
            record('wrong', <double>[1, 0]),
          ]),
          throwsA(isA<ValidationException>()),
        );
      });
      await withDb((db) async {
        final store = await db.vectorStore(name: 'bad', dimensions: 3);
        expect(await store.count(), 0);
      });
    });

    test('never evicts', () async {
      await withDb((db) async {
        final store = await db.vectorStore(name: 'many', dimensions: 2);
        await store.upsert(<VectorRecord>[
          for (var i = 0; i < 2500; i++)
            record('r$i', <double>[i.toDouble(), 1]),
        ]);
      });
      await withDb((db) async {
        final store = await db.vectorStore(name: 'many', dimensions: 2);
        expect(await store.count(), 2500);
      });
    });

    test(
      'refuses to open with a different shape, then opens with the right one',
      () async {
        await withDb((db) async {
          final store = await db.vectorStore(name: 'shape', dimensions: 3);
          await store.upsert(<VectorRecord>[
            record('a', <double>[1, 0, 0]),
          ]);
        });
        await withDb((db) async {
          await expectLater(
            db.vectorStore(name: 'shape', dimensions: 768),
            throwsA(isA<ConfigurationException>()),
          );
          await expectLater(
            db.vectorStore(
              name: 'shape',
              dimensions: 3,
              metric: SimilarityMetric.dotProduct,
            ),
            throwsA(isA<ConfigurationException>()),
          );
          // The failed opens must not leave the name claimed.
          final store = await db.vectorStore(name: 'shape', dimensions: 3);
          expect(await store.count(), 1);
        });
      },
    );

    test('a damaged row is reported, not silently skipped', () async {
      await withDb((db) async {
        final store = await db.vectorStore(name: 'hurt', dimensions: 4);
        await store.upsert(<VectorRecord>[
          record('a', <double>[1, 0, 0, 0]),
        ]);
        await store.dispose();
        db.connection.execute(
          "UPDATE vectors SET vector = ? WHERE id = 'a'",
          <Object?>[Uint8List(6)],
        );
      });
      await withDb((db) async {
        await expectLater(
          db.vectorStore(name: 'hurt', dimensions: 4),
          throwsA(
            isA<StorageException>().having(
              (e) => e.message,
              'message',
              contains('damaged'),
            ),
          ),
        );
      });
    });

    test('records come back from disk, for a keyword index', () async {
      await withDb((db) async {
        final store = await db.vectorStore(name: 'rec', dimensions: 2);
        await store.upsert(<VectorRecord>[
          record('a', <double>[1, 0], text: 'alpha'),
        ]);
        await store.upsert(<VectorRecord>[
          record('b', <double>[0, 1], text: 'beta'),
        ], namespace: 'other');
      });
      await withDb((db) async {
        final store = await db.vectorStore(name: 'rec', dimensions: 2);
        expect(
          (await store.records()).map((r) => r.id),
          unorderedEquals(<String>['a', 'b']),
        );
        final other = await store.records(namespace: 'other');
        expect(other.single.text, 'beta');
      });
    });

    test('a disposed store refuses further use', () async {
      await withDb((db) async {
        final store = await db.vectorStore(name: 'gone', dimensions: 2);
        await store.dispose();
        expect(() => store.get('a'), throwsA(isA<InvalidStateException>()));
      });
    });
  });

  group('SqliteMemoryStore', () {
    final t0 = DateTime.utc(2026, 9, 1);

    MemoryEntry entry(
      String id,
      String content, {
      double importance = 0.5,
      DateTime? expiresAt,
    }) => MemoryEntry(
      id: id,
      content: content,
      createdAt: t0,
      importance: importance,
      expiresAt: expiresAt,
    );

    test('memories survive a restart and are searchable', () async {
      await withDb((db) async {
        final memory = await db.memoryStore(name: 'assistant');
        await memory.write(entry('m1', 'Ana prefers British English'));
        await memory.write(entry('m2', 'The standup is on Tuesdays'));
      });
      await withDb((db) async {
        final memory = await db.memoryStore(name: 'assistant');
        expect(await memory.count(), 2);
        expect((await memory.read('m1'))!.content, contains('British'));
        final hits = await memory.search(MemoryQuery(text: 'standup tuesday'));
        expect(hits.first.entry.id, 'm2');
      });
    });

    test('a merged duplicate is stored once, not twice', () async {
      // Mirroring the call would have written both; reconciling writes what
      // the in-memory store actually kept.
      await withDb((db) async {
        final memory = await db.memoryStore(name: 'dedupe');
        await memory.write(entry('m1', 'Coffee on Wilton Road'));
        await memory.write(
          entry('m2', 'Coffee on Wilton Road', importance: 0.9),
        );
        expect(await memory.count(), 1);
      });
      await withDb((db) async {
        final memory = await db.memoryStore(name: 'dedupe');
        expect(await memory.count(), 1);
        expect(memory.entries.single.importance, 0.9);
        final rows = db.connection.select(
          "SELECT COUNT(*) AS n FROM memories WHERE store = 'dedupe'",
        );
        expect(rows.first['n'], 1, reason: 'the disk agrees with memory');
      });
    });

    test('an eviction reaches the disk', () async {
      await withDb((db) async {
        final memory = await db.memoryStore(name: 'small', maxEntries: 2);
        await memory.write(entry('low', 'least important', importance: 0.1));
        await memory.write(entry('mid', 'somewhat important'));
        await memory.write(entry('high', 'most important', importance: 0.9));
        expect(memory.entries.map((e) => e.id), isNot(contains('low')));
      });
      await withDb((db) async {
        // Reopened with the *default* limit, and checked on disk directly.
        // Reopening with `maxEntries: 2` would evict `low` again on load and
        // hide a row that was never deleted — which is how this test first
        // passed against a store that did not delete evictions at all.
        final rows = db.connection.select(
          "SELECT id FROM memories WHERE store = 'small' ORDER BY seq",
        );
        expect(rows.map((r) => r['id']), isNot(contains('low')));

        final memory = await db.memoryStore(name: 'small');
        expect(await memory.read('low'), isNull);
        expect(await memory.count(), 2);
      });
    });

    test('reopening with a smaller limit applies it and persists it', () async {
      await withDb((db) async {
        final memory = await db.memoryStore(name: 'shrink');
        for (var i = 0; i < 5; i++) {
          await memory.write(
            entry('m$i', 'memory number $i', importance: i / 10),
          );
        }
      });
      await withDb((db) async {
        final memory = await db.memoryStore(name: 'shrink', maxEntries: 3);
        expect(await memory.count(), 3);
      });
      await withDb((db) async {
        // Opened with the default limit again: the eviction is permanent, not
        // re-applied on every launch from a file that still held all five.
        final memory = await db.memoryStore(name: 'shrink');
        expect(await memory.count(), 3);
      });
    });

    test('write order survives a restart, merges included', () async {
      await withDb((db) async {
        final memory = await db.memoryStore(name: 'order');
        await memory.write(entry('a', 'first'));
        await memory.write(entry('b', 'second'));
        await memory.write(entry('c', 'third'));
        // A merge into `a` must not move it to the end.
        await memory.write(entry('a2', 'first', importance: 0.8));
      });
      await withDb((db) async {
        final memory = await db.memoryStore(name: 'order');
        expect(memory.entries.map((e) => e.id), <String>['a', 'b', 'c']);
      });
    });

    test('delete, prune and clear survive a restart', () async {
      final clock = FakeClock(initialTime: t0);
      await withDb((db) async {
        final memory = await db.memoryStore(name: 'life', clock: clock);
        await memory.write(entry('keep', 'kept'));
        await memory.write(entry('drop', 'dropped'));
        await memory.write(
          entry('stale', 'expired', expiresAt: t0.add(const Duration(days: 1))),
        );
        expect(await memory.delete('drop'), isTrue);
        expect(await memory.prune(now: t0.add(const Duration(days: 2))), 1);
      });
      await withDb((db) async {
        final memory = await db.memoryStore(name: 'life', clock: clock);
        expect(memory.entries.map((e) => e.id), <String>['keep']);
        await memory.clear();
      });
      await withDb((db) async {
        final memory = await db.memoryStore(name: 'life', clock: clock);
        expect(await memory.count(), 0);
      });
    });

    test('when the disk write fails, memory is rolled back', () async {
      // The guarantee that makes the reconciliation safe: a failed write
      // leaves memory as it was, so the two never disagree.
      await withDb((db) async {
        final memory = await db.memoryStore(name: 'fragile');
        await memory.write(entry('before', 'already here'));

        db.connection.execute('DROP TABLE memories');

        await expectLater(
          memory.write(entry('after', 'never stored')),
          throwsA(isA<StorageException>()),
        );
        expect(memory.entries.map((e) => e.id), <String>['before']);
      });
    });

    test('an unchanged file is not rewritten when it opens', () async {
      await withDb((db) async {
        final memory = await db.memoryStore(name: 'quiet');
        await memory.write(entry('a', 'one'));
        await memory.write(entry('b', 'two'));
      });
      await withDb((db) async {
        // `total_changes()` counts every row written on this connection. A
        // rewrite would keep each row's `seq`, so comparing rows could not see
        // it — the counter can.
        int changes() =>
            db.connection.select('SELECT total_changes() AS n').first['n']
                as int;
        final before = changes();
        final memory = await db.memoryStore(name: 'quiet');
        expect(await memory.count(), 2);
        expect(changes(), before);
      });
    });
  });

  group('SqliteSessionStore', () {
    AgentSession chat(String id, List<String> said, {String? title}) =>
        AgentSession(
          id: id,
          history: <Message>[for (final text in said) Message.user(text)],
          metadata: <String, Object?>{'title': ?title},
        );

    test('conversations survive a restart, newest first', () async {
      final clock = FakeClock(initialTime: DateTime.utc(2026, 9, 17, 9));
      await withDb((db) async {
        final chats = db.sessionStore(clock: clock);
        await chats.save(chat('older', <String>['hi'], title: 'Coffee'));
        await clock.advance(const Duration(minutes: 5));
        await chats.save(
          chat('newer', <String>[
            'why the hold?',
            'and then?',
          ], title: 'Rollout'),
        );
      });

      await withDb((db) async {
        final chats = db.sessionStore(clock: clock);
        final listed = await chats.list();
        expect(listed.map((s) => s.id), <String>['newer', 'older']);
        expect(listed.first.messageCount, 2);
        expect(listed.first.metadata['title'], 'Rollout');
        expect(listed.first.updatedAt, DateTime.utc(2026, 9, 17, 9, 5));

        final loaded = await chats.load('newer');
        expect(loaded!.history.map((m) => m.text), <String>[
          'why the hold?',
          'and then?',
        ]);
      });
    });

    test('saving again replaces, and delete says whether it existed', () async {
      await withDb((db) async {
        final chats = db.sessionStore();
        await chats.save(chat('s', <String>['one']));
        await chats.save(chat('s', <String>['one', 'two']));
        expect(await chats.list(), hasLength(1));
        expect((await chats.load('s'))!.history, hasLength(2));

        expect(await chats.delete('s'), isTrue);
        expect(await chats.delete('s'), isFalse);
        expect(await chats.load('s'), isNull);
      });
    });

    test('named stores keep their conversations apart', () async {
      await withDb((db) async {
        await db.sessionStore(name: 'work').save(chat('w', <String>['x']));
        expect(await db.sessionStore(name: 'home').list(), isEmpty);
        expect(await db.sessionStore(name: 'work').list(), hasLength(1));
      });
    });
  });

  group('SqliteWorkflowSnapshotStore', () {
    WorkflowGraph approvalGraph() => WorkflowGraph(
      id: 'send-email',
      nodes: <WorkflowNode>[
        TransformNode(
          id: 'draft',
          writes: <String, JsonSchema>{'draft': JsonSchema.string()},
          transform: (_) async => <String, Object?>{'draft': 'Dear Ada, ...'},
        ),
        HumanApprovalNode(
          id: 'approve',
          message: 'Send this email?',
          reads: <String>{'draft'},
          summarise: (context) => context.require<String>('draft'),
        ),
        TransformNode(
          id: 'discard',
          writes: <String, JsonSchema>{'discarded': JsonSchema.boolean()},
          transform: (_) async => <String, Object?>{'discarded': true},
        ),
        const EndNode(),
      ],
      // An approval node branches on its decision, so both outcomes need a
      // labelled edge — a single unlabelled one leaves the approved run
      // nowhere to go.
      edges: const <WorkflowEdge>[
        WorkflowEdge('draft', 'approve'),
        WorkflowEdge('approve', 'end', label: 'approved'),
        WorkflowEdge('approve', 'discard', label: 'rejected'),
        WorkflowEdge('discard', 'end'),
      ],
      startNodeId: 'draft',
    );

    test('a run suspended before a restart resumes after it', () async {
      // The whole reason this store exists: approve tomorrow what was asked
      // today, in a process that did not exist when the question was asked.
      const engine = WorkflowEngine();
      final graph = approvalGraph();
      late String runId;

      await withDb((db) async {
        final suspended = await engine.run(graph);
        expect(suspended.status, WorkflowStatus.suspended);
        runId = suspended.runId;
        await db.snapshotStore().save(suspended.snapshot!);
      });

      await withDb((db) async {
        final snapshots = db.snapshotStore();
        final pending = await snapshots.list(graphId: graph.id);
        expect(pending.single.runId, runId);

        final finished = await engine.resume(
          graph,
          (await snapshots.load(runId))!,
          resumeValue: <String, Object?>{'approved': true},
        );
        expect(finished.status, WorkflowStatus.completed);
        expect(finished.runId, runId);

        expect(await snapshots.delete(runId), isTrue);
        expect(await snapshots.delete(runId), isFalse);
        expect(await snapshots.list(), isEmpty);
      });
    });

    test('lists the longest-waiting run first', () async {
      const engine = WorkflowEngine();
      final graph = approvalGraph();
      await withDb((db) async {
        final first = (await engine.run(graph)).snapshot!;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        final second = (await engine.run(graph)).snapshot!;
        final snapshots = db.snapshotStore();
        await snapshots.save(second);
        await snapshots.save(first);

        expect((await snapshots.list()).map((s) => s.runId), <String>[
          first.runId,
          second.runId,
        ]);
      });
    });

    test('a snapshot from a newer format keeps its own explanation', () async {
      // Not wrapped in a StorageException: the workflow package's message
      // already says what to do, and burying it would not.
      await withDb((db) async {
        final snapshot = (await const WorkflowEngine().run(
          approvalGraph(),
        )).snapshot!;
        await db.snapshotStore().save(snapshot);
        db.connection.execute(
          'UPDATE workflow_snapshots SET snapshot = '
          r"json_set(snapshot, '$.formatVersion', 99)",
        );
        await expectLater(
          db.snapshotStore().load(snapshot.runId),
          throwsA(isA<SerializationException>()),
        );
      });
    });
  });
}
