// Saves notes and memories, closes the database, opens it again, and finds
// them still there. That restart is the entire point of this package.
//
//   dart run example/agentic_sqlite_example.dart
import 'dart:io';

import 'package:agentic_memory/agentic_memory.dart';
import 'package:agentic_sqlite/agentic_sqlite.dart';
import 'package:agentic_vector/agentic_vector.dart';

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('agentic_sqlite_example');
  final path = '${dir.path}${Platform.pathSeparator}agentic.db';

  // --- First launch ---------------------------------------------------------
  var db = await AgenticDatabase.open(path);
  var notes = await db.vectorStore(name: 'notes', dimensions: 3);
  var memory = await db.memoryStore(name: 'assistant');

  // In an app these vectors come from an EmbeddingModel; three dimensions keep
  // the example readable.
  await notes.upsert(<VectorRecord>[
    VectorRecord(
      id: 'standup',
      vector: const <double>[0.9, 0.1, 0.0],
      text: 'Holding the checkout rollout until the retry fix lands.',
      metadata: const <String, Object?>{'title': 'Standup — Tuesday'},
    ),
    VectorRecord(
      id: 'coffee',
      vector: const <double>[0.0, 0.2, 0.9],
      text: 'The coffee place on Wilton Road, next to the bike shop.',
      metadata: const <String, Object?>{'title': 'Flat white, Ana said'},
    ),
  ]);
  await memory.remember('Prefers short answers', importance: 0.8);

  print(
    'First launch: saved ${await notes.count()} notes, '
    '${await memory.count()} memory.',
  );
  await db.dispose(); // The app is closed.

  // --- Second launch --------------------------------------------------------
  db = await AgenticDatabase.open(path);
  notes = await db.vectorStore(name: 'notes', dimensions: 3);
  memory = await db.memoryStore(name: 'assistant');

  final match = (await notes.search(
    VectorQuery(vector: const <double>[0.8, 0.2, 0.1], topK: 1),
  )).single;
  final remembered = await memory.search(MemoryQuery(text: 'short answers'));

  print(
    'Second launch: ${await notes.count()} notes, '
    '${await memory.count()} memory.',
  );
  print(
    '  Nearest note: "${match.record.metadata['title']}" '
    '(score ${match.score.toStringAsFixed(2)})',
  );
  print('  Remembered:   "${remembered.first.entry.content}"');

  await db.dispose();
  dir.deleteSync(recursive: true);
}
