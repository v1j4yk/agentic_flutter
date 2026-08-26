/// Checking a project name before writing forty files under it.
///
/// # Why this is its own file
///
/// The errors here are the ones people actually hit — a hyphen, a capital, a
/// reserved word — and every one of them fails *later*, from `pub`, with a
/// message about a pubspec the user did not write. Catching them before
/// anything is created turns a confusing failure into a sentence.
library;

/// Why a name was rejected, or `null` when it is fine.
///
/// A string rather than an exception: this is a command-line tool talking to a
/// person, and the only useful thing to do with the answer is print it.
String? validateProjectName(String name) {
  if (name.isEmpty) return 'A project name is required.';

  if (name != name.toLowerCase()) {
    return 'Dart package names are lowercase: try "${_suggest(name)}".';
  }
  if (name.contains('-') || name.contains(' ')) {
    return 'Dart package names use underscores, not hyphens or spaces: '
        'try "${_suggest(name)}".';
  }
  if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name)) {
    return 'A package name must start with a letter and contain only '
        'lowercase letters, digits and underscores.';
  }
  if (name.endsWith('_')) {
    return 'A package name should not end with an underscore.';
  }
  if (name.contains('__')) {
    return 'A package name should not contain a double underscore.';
  }
  if (_reservedWords.contains(name)) {
    return '"$name" is a Dart reserved word, so the generated package could '
        'not be imported.';
  }
  // Not fatal, but it produces a library that cannot be imported alongside the
  // real one, which is a confusing afternoon.
  if (name.startsWith('agentic_')) {
    return 'A name starting with "agentic_" collides with the framework\'s own '
        'packages. Try something that names your app instead.';
  }
  return null;
}

/// The closest legal name to [name].
///
/// Offered rather than applied: silently renaming somebody's project is worse
/// than telling them what is wrong with the name they chose.
String _suggest(String name) {
  final cleaned = name
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '_')
      .replaceAll(RegExp('_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (cleaned.isEmpty) return 'my_app';
  return RegExp('^[0-9]').hasMatch(cleaned) ? 'app_$cleaned' : cleaned;
}

/// A human-readable title derived from a package name.
///
/// `my_notes_app` becomes `My Notes App`, for a window title and an app bar.
String titleFor(String packageName) => packageName
    .split('_')
    .where((word) => word.isNotEmpty)
    .map((word) => word[0].toUpperCase() + word.substring(1))
    .join(' ');

/// Words a Dart library cannot be named.
///
/// The subset that is actually plausible as a project name; the full reserved
/// list includes things nobody would type here.
const Set<String> _reservedWords = <String>{
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'base',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'function',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'of',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'typedef',
  'var',
  'void',
  'when',
  'while',
  'with',
  'yield',
};
