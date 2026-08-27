// Releases the framework to pub.dev, in an order that cannot be got wrong.
//
//   dart run tool/release.dart --version=0.2.0            # check only
//   dart run tool/release.dart --version=0.2.0 --publish  # do it
//
// # Why this is a program and not a checklist
//
// Ten packages that depend on each other have exactly one valid publishing
// order, and pub.dev is append-only: a wrong version published is a version
// that exists forever. Retraction hides a release for seven days; it does not
// remove it, and anyone whose lockfile already names it keeps resolving it.
//
// That makes the *preflight* the point of this file, not the publishing. The
// mistake it exists to catch is the quiet one: bumping every package to 0.2.0
// and leaving the constraints between them reading `^0.1.0`. Every dry run
// passes, every package publishes, and every user resolves the new
// `agentic_tools` against the *old* `agentic_core` — a combination that was
// never tested together because locally the workspace always resolved to the
// source next door. Nothing fails until someone else's build does.
//
// A human checklist cannot catch that; it looks like success at every step.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }
  if (options.error != null) {
    stderr
      ..writeln(options.error)
      ..writeln()
      ..writeln(_usage);
    exitCode = 64; // EX_USAGE
    return;
  }

  final root = _repositoryRoot();
  if (root == null) {
    stderr.writeln(
      'Run this from inside the repository: no packages/ directory found.',
    );
    exitCode = 1;
    return;
  }

  final packages = _discover(root);
  if (packages.isEmpty) {
    stderr.writeln('No publishable packages found under $root/packages.');
    exitCode = 1;
    return;
  }

  final full = _publishOrder(packages);
  if (full == null) {
    stderr.writeln(
      'The packages form a dependency cycle, so no publishing order exists.',
    );
    exitCode = 1;
    return;
  }

  // Resuming a partial release. Everything before `--from` is already live and
  // cannot be withdrawn, so the only safe thing to do with it is skip it —
  // re-running the whole order would fail on the first package with
  // "version already exists" and leave the rest unpublished.
  final order = options.from == null
      ? full
      : full.skipWhile((p) => p.name != options.from).toList();
  if (order.isEmpty) {
    stderr.writeln(
      'No package named "${options.from}". Resume from one of: '
      '${full.map((p) => p.name).join(', ')}.',
    );
    exitCode = 1;
    return;
  }
  if (options.from != null) {
    stdout.writeln(
      'Resuming from ${options.from}; skipping ${full.length - order.length} '
      'already-published package(s).',
    );
  }

  stdout
    ..writeln('Releasing ${options.version} — ${order.length} packages')
    ..writeln()
    ..writeln('Order:')
    ..writeln();
  for (var i = 0; i < order.length; i++) {
    stdout.writeln('  ${i + 1}. ${order[i].name}');
  }
  stdout.writeln();

  final failures = <String>[];
  for (final package in order) {
    final problems = _preflight(package, options.version, packages);
    final label = problems.isEmpty ? 'ok' : '${problems.length} problem(s)';
    stdout.writeln('  ${_pad(package.name)} $label');
    for (final problem in problems) {
      stdout.writeln('      - $problem');
      failures.add('${package.name}: $problem');
    }
  }
  stdout.writeln();

  if (failures.isNotEmpty) {
    stderr
      ..writeln('${failures.length} problem(s). Nothing was published.')
      ..writeln()
      ..writeln(
        'Fix these first: every one of them is something pub.dev will accept '
        'and users will trip over.',
      );
    exitCode = 1;
    return;
  }

  if (!options.skipDryRun) {
    stdout
      ..writeln('Dry run:')
      ..writeln();
    for (final package in order) {
      final complaints = await _dryRun(package);
      stdout.writeln(
        '  ${_pad(package.name)} ${complaints.isEmpty ? 'ok' : 'FAILED'}',
      );
      for (final complaint in complaints) {
        stdout.writeln('      - $complaint');
        failures.add('${package.name}: $complaint');
      }
    }
    stdout.writeln();
    if (failures.isNotEmpty && !options.allowWarnings) {
      stderr
        ..writeln('${failures.length} complaint(s) from pub. Nothing was ')
        ..writeln('published.')
        ..writeln()
        // These are pub's warnings, not this tool's checks. Some are real
        // blockers — uncommitted files mean the archive would not match the
        // repository — and some are structural to a monorepo and will never
        // clear. Which is which is a judgement, so it is left to a person,
        // and taking it needs an explicit flag rather than a shrug.
        ..writeln(
          'Every one of these is a warning pub would also show you at publish '
          'time. Fix the ones that matter — uncommitted files above all, '
          'since the archive would not match the repository — then re-run '
          'with --allow-warnings to proceed past the rest.',
        );
      exitCode = 1;
      return;
    }
    if (failures.isNotEmpty) {
      stdout.writeln(
        'Proceeding past ${failures.length} warning(s) because '
        '--allow-warnings was given.',
      );
      failures.clear();
    }
  }

  if (!options.publish) {
    stdout
      ..writeln('Everything checks out. Nothing published — this was a check.')
      ..writeln()
      ..writeln('To publish for real:')
      ..writeln()
      ..writeln(
        '  dart run tool/release.dart --version=${options.version} --publish',
      )
      ..writeln()
      ..writeln(
        'You will need to be logged in (`dart pub login`) and be an uploader '
        'on every package. Publishing cannot be undone.',
      );
    return;
  }

  stdout
    ..writeln('Publishing for real. This cannot be undone.')
    ..writeln();

  for (final package in order) {
    stdout.writeln('  ${package.name} ${options.version} ...');
    final published = await _publish(package, force: options.force);
    if (!published) {
      stderr
        ..writeln()
        ..writeln('${package.name} failed to publish.')
        ..writeln()
        ..writeln(
          'Everything before it in the order is already live and cannot be '
          'withdrawn. Fix this package and re-run with '
          '--from=${package.name} to resume rather than start over.',
        );
      exitCode = 1;
      return;
    }

    // A dependent cannot publish until pub.dev serves what it depends on:
    // `pub publish` resolves the pubspec, and an unpublished constraint fails
    // that resolution. Skipped for the last package, which nothing waits on.
    if (package != order.last) {
      final live = await _awaitAvailability(package.name, options.version);
      if (!live) {
        stderr
          ..writeln()
          ..writeln(
            'Published ${package.name}, but pub.dev is not serving '
            '${options.version} yet. Wait a minute and resume with '
            '--from=<the next package>.',
          );
        exitCode = 1;
        return;
      }
    }
  }

  stdout
    ..writeln()
    ..writeln('Released ${options.version}.')
    ..writeln()
    ..writeln('Tag the commit so the release is findable from the history:')
    ..writeln()
    ..writeln('  git tag v${options.version} && git push --tags');
}

// ---------------------------------------------------------------------------
// Preflight
// ---------------------------------------------------------------------------

/// Everything wrong with releasing [package] as [version].
///
/// Returns human-readable problems rather than throwing on the first: a
/// release is a batch, and finding out about six problems one run at a time is
/// how a release takes an afternoon.
List<String> _preflight(
  _Package package,
  String version,
  Map<String, _Package> all,
) {
  final problems = <String>[];

  if (package.version != version) {
    problems.add(
      'pubspec says ${package.version}, releasing $version. Bump it or '
      'release ${package.version}.',
    );
  }

  // The check this file exists for. A constraint of `^0.1.0` on a sibling
  // being published as 0.2.0 resolves fine here, where the workspace supplies
  // the source next door, and resolves to the *old* release everywhere else.
  for (final entry in package.internalDependencies.entries) {
    final dependency = all[entry.key];
    if (dependency == null) continue;
    if (!_admits(entry.value, version)) {
      problems.add(
        'depends on ${entry.key}: ${entry.value}, which does not admit '
        '$version — users would resolve it against the previous release.',
      );
    }
  }

  final changelog = File('${package.directory}/CHANGELOG.md');
  if (!changelog.existsSync()) {
    problems.add('has no CHANGELOG.md.');
  } else if (!_mentions(changelog.readAsStringSync(), version)) {
    problems.add(
      'CHANGELOG.md has no heading for $version. pub.dev shows the changelog '
      'on the package page, and an unchanged one reads as an unchanged '
      'package.',
    );
  }

  if (!File('${package.directory}/README.md').existsSync()) {
    problems.add('has no README.md, which is most of the pub.dev score.');
  }
  if (!File('${package.directory}/LICENSE').existsSync()) {
    problems.add('has no LICENSE.');
  }

  return problems;
}

/// Whether a caret or range constraint admits [version].
///
/// Deliberately narrow: it understands the constraint forms this repository
/// actually writes (`^x.y.z`, `any`, an exact version) and refuses to guess at
/// anything else. A release check that silently approves a constraint it did
/// not understand is worse than one that asks a human to look.
bool _admits(String constraint, String version) {
  final trimmed = constraint.trim().replaceAll('"', '').replaceAll("'", '');
  if (trimmed == 'any' || trimmed.isEmpty) return true;

  if (trimmed.startsWith('^')) {
    final floor = _Version.parse(trimmed.substring(1));
    final target = _Version.parse(version);
    if (floor == null || target == null) return false;
    if (target < floor) return false;
    // Caret on a 0.x release pins the minor: ^0.1.0 admits 0.1.9, not 0.2.0.
    // Getting this backwards is the entire failure mode being guarded against.
    if (floor.major == 0) {
      return target.major == 0 && target.minor == floor.minor;
    }
    return target.major == floor.major;
  }

  return trimmed == version;
}

/// Whether [changelog] has a heading naming [version].
bool _mentions(String changelog, String version) {
  for (final line in const LineSplitter().convert(changelog)) {
    if (!line.startsWith('#')) continue;
    if (line.contains(version)) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Ordering
// ---------------------------------------------------------------------------

/// Orders [packages] so that every package follows what it depends on.
///
/// Derived from the pubspecs rather than written down. A hardcoded list is
/// correct until someone adds a dependency, and then it is silently wrong in
/// the one direction that matters.
///
/// Returns null when the graph has a cycle.
List<_Package>? _publishOrder(Map<String, _Package> packages) {
  final ordered = <_Package>[];
  final placed = <String>{};
  final visiting = <String>{};

  bool visit(_Package package) {
    if (placed.contains(package.name)) return true;
    if (!visiting.add(package.name)) return false;

    for (final name in package.internalDependencies.keys.toList()..sort()) {
      final dependency = packages[name];
      if (dependency == null) continue;
      if (!visit(dependency)) return false;
    }

    visiting.remove(package.name);
    placed.add(package.name);
    ordered.add(package);
    return true;
  }

  for (final name in packages.keys.toList()..sort()) {
    if (!visit(packages[name]!)) return null;
  }
  return ordered;
}

// ---------------------------------------------------------------------------
// Running pub
// ---------------------------------------------------------------------------

/// Runs `pub publish --dry-run` and returns what it objected to.
///
/// Empty when it was happy. `pub` exits non-zero for *warnings* as well as
/// errors, so the exit code alone says "something", and reporting that as a
/// bare FAILED is useless at the one moment somebody needs to know what.
Future<List<String>> _dryRun(_Package package) async {
  final result = await Process.run(
    package.isFlutter ? 'flutter' : 'dart',
    <String>['pub', 'publish', '--dry-run'],
    workingDirectory: package.directory,
    runInShell: true,
  );
  if (result.exitCode == 0) return const <String>[];

  // Both streams: `pub` puts the package listing and some complaints on
  // stdout and others on stderr, and which goes where is not something to
  // depend on. Each complaint opens with `* `; the lines under it are
  // elaboration a person can get by running the dry run themselves.
  // A set: pub repeats the same complaint once per offending dependency, and
  // nine identical lines say nothing that one does.
  final complaints = <String>{};
  final output = '${result.stdout}\n${result.stderr}';
  for (final line in const LineSplitter().convert(output)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (!trimmed.startsWith('*')) continue;
    complaints.add(trimmed.substring(1).trim());
  }
  return complaints.isEmpty
      ? <String>['pub exited ${result.exitCode}; run the dry run to see why.']
      : complaints.toList();
}

Future<bool> _publish(_Package package, {required bool force}) async {
  final executable = package.isFlutter ? 'flutter' : 'dart';
  final arguments = <String>['pub', 'publish', if (force) '--force'];

  if (!force) {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: package.directory,
      runInShell: true,
      // Inherited so the confirmation prompt and the OAuth URL reach the
      // person running this. A release tool that swallows an authentication
      // prompt looks like a hang.
      mode: ProcessStartMode.inheritStdio,
    );
    return await process.exitCode == 0;
  }

  // Forced, so there is no prompt to relay and the output can be captured
  // instead — which is what makes a rate limit distinguishable from a real
  // failure.
  for (var attempt = 1; ; attempt++) {
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: package.directory,
      runInShell: true,
    );
    _echo(result.stdout);
    if (result.exitCode == 0) return true;

    final output = '${result.stdout}\n${result.stderr}';
    if (!_isRateLimited(output) || attempt >= _rateLimitAttempts) {
      _echo(result.stderr, toStderr: true);
      return false;
    }

    // pub.dev caps how many *new* packages one account may create in a short
    // window. A monorepo's first release is exactly the shape that exceeds it
    // — eleven packages that have never existed, published back to back — and
    // it is not a failure of any of them. Waiting is the correct response, and
    // doing it here rather than making a person re-run the tool three times is
    // the difference between a release and an afternoon.
    final wait = Duration(minutes: attempt);
    stdout.writeln(
      '    rate-limited by pub.dev; waiting ${wait.inMinutes}m before '
      'attempt ${attempt + 1} of $_rateLimitAttempts',
    );
    await Future<void>.delayed(wait);
  }
}

/// How many times to wait out a rate limit before giving up.
const int _rateLimitAttempts = 6;

/// Whether pub refused because of a rate limit rather than a defect.
bool _isRateLimited(String output) =>
    output.contains('rate limit has been reached');

/// Prints pub's output without the archive file tree.
///
/// The listing is dozens of lines per package and says nothing a release log
/// needs; what matters is the validation result and any complaint.
void _echo(Object? output, {bool toStderr = false}) {
  for (final line in const LineSplitter().convert('$output')) {
    if (line.startsWith('│') ||
        line.startsWith('├') ||
        line.startsWith('└') ||
        line.startsWith('    ')) {
      continue;
    }
    if (line.trim().isEmpty) continue;
    // Written directly rather than through a local, which the analyser reads
    // as a sink somebody forgot to close.
    if (toStderr) {
      stderr.writeln('    $line');
    } else {
      stdout.writeln('    $line');
    }
  }
}

/// Waits until pub.dev serves [version] of [package].
///
/// Publishing is not instant: the archive is accepted before the version is
/// resolvable, and a dependent published into that gap fails on a constraint
/// that is about to become satisfiable.
Future<bool> _awaitAvailability(
  String package,
  String version, {
  Duration timeout = const Duration(minutes: 3),
}) async {
  final client = HttpClient();
  final deadline = DateTime.now().add(timeout);
  try {
    while (DateTime.now().isBefore(deadline)) {
      try {
        final request = await client.getUrl(
          Uri.https('pub.dev', '/api/packages/$package/versions/$version'),
        );
        final response = await request.close();
        await response.drain<void>();
        if (response.statusCode == 200) return true;
      } on Object {
        // Offline, rate-limited, or DNS still catching up. Retrying is the
        // whole point; the deadline is what stops it.
      }
      stdout.write('.');
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    return false;
  } finally {
    client.close(force: true);
  }
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

/// One package in the repository.
final class _Package {
  const _Package({
    required this.name,
    required this.directory,
    required this.version,
    required this.internalDependencies,
    required this.isFlutter,
  });

  final String name;
  final String directory;
  final String version;

  /// Sibling packages this one depends on, and the constraint it names them
  /// with.
  final Map<String, String> internalDependencies;

  /// Whether it needs the Flutter SDK to publish.
  final bool isFlutter;
}

/// Finds the repository root by walking up from the working directory.
String? _repositoryRoot() {
  var directory = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory('${directory.path}/packages').existsSync() &&
        File('${directory.path}/pubspec.yaml').existsSync()) {
      return directory.path.replaceAll(r'\', '/');
    }
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return null;
}

/// Every publishable package under `packages/`, keyed by name.
///
/// `publish_to: none` is how a package says it is a harness. Reading that
/// rather than keeping a list of exclusions means adding another harness needs
/// no change here.
Map<String, _Package> _discover(String root) {
  final packages = <String, _Package>{};

  for (final entity in Directory('$root/packages').listSync()) {
    if (entity is! Directory) continue;
    final pubspec = File('${entity.path}/pubspec.yaml');
    if (!pubspec.existsSync()) continue;

    final source = pubspec.readAsStringSync();
    if (_field(source, 'publish_to') == 'none') continue;

    final name = _field(source, 'name');
    final version = _field(source, 'version');
    if (name == null || version == null) continue;

    packages[name] = _Package(
      name: name,
      directory: entity.path.replaceAll(r'\', '/'),
      version: version,
      internalDependencies: _internalDependencies(source),
      isFlutter: source.contains('sdk: flutter'),
    );
  }
  return packages;
}

/// Reads a top-level scalar field out of a pubspec.
///
/// Enough YAML for the four fields this tool needs, and no dependency on a
/// parser for a release script that must run before anything is resolved.
String? _field(String source, String key) {
  for (final line in const LineSplitter().convert(source)) {
    if (!line.startsWith('$key:')) continue;
    return line
        .substring(key.length + 1)
        .trim()
        .replaceAll('"', '')
        .replaceAll("'", '');
  }
  return null;
}

/// The `agentic_*` and `create_agentic_*` entries in the `dependencies:` block.
Map<String, String> _internalDependencies(String source) {
  final dependencies = <String, String>{};
  var inDependencies = false;

  for (final line in const LineSplitter().convert(source)) {
    if (line.startsWith('dependencies:')) {
      inDependencies = true;
      continue;
    }
    // Any other unindented key ends the block — including `dev_dependencies`,
    // whose entries are not part of the published constraint set.
    if (inDependencies &&
        line.isNotEmpty &&
        !line.startsWith(' ') &&
        !line.startsWith('#')) {
      inDependencies = false;
    }
    if (!inDependencies) continue;

    final match = RegExp(
      r'^  ((?:create_)?agentic_[a-z_]+):\s*(.+)$',
    ).firstMatch(line);
    if (match == null) continue;
    dependencies[match.group(1)!] = match.group(2)!.trim();
  }
  return dependencies;
}

// ---------------------------------------------------------------------------
// Versions
// ---------------------------------------------------------------------------

/// Just enough semver to compare two releases.
final class _Version implements Comparable<_Version> {
  const _Version(this.major, this.minor, this.patch);

  static _Version? parse(String source) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(source.trim());
    if (match == null) return null;
    return _Version(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  final int major;
  final int minor;
  final int patch;

  @override
  int compareTo(_Version other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator <(_Version other) => compareTo(other) < 0;

  @override
  String toString() => '$major.$minor.$patch';
}

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

final class _Options {
  const _Options({
    this.version = '',
    this.publish = false,
    this.force = false,
    this.skipDryRun = false,
    this.allowWarnings = false,
    this.from,
    this.help = false,
    this.error,
  });

  factory _Options.parse(List<String> arguments) {
    var version = '';
    var publish = false;
    var force = false;
    var skipDryRun = false;
    var allowWarnings = false;
    String? from;
    var help = false;

    for (final argument in arguments) {
      if (argument == '-h' || argument == '--help') {
        help = true;
      } else if (argument == '--publish') {
        publish = true;
      } else if (argument == '--force') {
        force = true;
      } else if (argument == '--skip-dry-run') {
        skipDryRun = true;
      } else if (argument == '--allow-warnings') {
        allowWarnings = true;
      } else if (argument.startsWith('--from=')) {
        from = argument.substring('--from='.length);
      } else if (argument.startsWith('--version=')) {
        version = argument.substring('--version='.length);
      } else {
        return _Options(error: 'Unknown option "$argument".');
      }
    }

    if (!help && version.isEmpty) {
      return const _Options(error: 'A --version is required.');
    }
    if (!help && _Version.parse(version) == null) {
      return _Options(error: '"$version" is not a version like 0.2.0.');
    }
    return _Options(
      version: version,
      publish: publish,
      force: force,
      skipDryRun: skipDryRun,
      allowWarnings: allowWarnings,
      from: from,
      help: help,
    );
  }

  final String version;
  final bool publish;
  final bool force;
  final bool skipDryRun;

  /// Whether to proceed past pub warnings the dry run reported.
  final bool allowWarnings;

  /// Where to resume a release that failed part-way.
  final String? from;

  final bool help;
  final String? error;
}

String _pad(String name) => name.padRight(22);

const String _usage = '''
Releases the framework to pub.dev in dependency order.

Usage: dart run tool/release.dart --version=<x.y.z> [options]

Options:
  --version=x.y.z   The version being released. Every package must already
                    declare it; this tool checks, it does not bump.
  --publish         Actually publish. Without it this only checks.
  --force           Skip pub's own confirmation prompt. For CI.
  --skip-dry-run    Skip `pub publish --dry-run`. Only when it was just run.
  --allow-warnings  Proceed past pub's own dry-run warnings. They are shown
                    either way; this says a person has read them. It does not
                    relax this tool's own checks, which are never advisory.
  --from=<package>  Resume a release that failed part-way, skipping everything
                    published before it. Re-running the whole order instead
                    fails on "version already exists" and strands the rest.
  -h, --help        Show this.

Without --publish nothing is uploaded, which is the mode worth running often.
Publishing cannot be undone: pub.dev retracts for seven days but never removes,
and a lockfile that already names a version keeps resolving it.''';
