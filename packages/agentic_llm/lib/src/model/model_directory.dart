/// Asking a provider which models it serves.
///
/// Constants go stale and documentation lags; the provider's own list does
/// not. This is the port behind a model picker in an app, and behind the
/// nightly check that a default this framework ships still exists.
library;

import 'package:agentic_core/agentic_core.dart';
import 'package:meta/meta.dart';

/// One model a provider says it serves.
///
/// Deliberately thin. Providers describe their models in wildly different
/// shapes, and pretending otherwise would mean inventing fields that are
/// accurate for one provider and guesses for the rest — the mistake
/// `ModelInfo.capabilities` exists to avoid. The provider's own payload is
/// kept in [raw] for anything this does not model.
@immutable
final class ModelDescriptor {
  /// Creates a descriptor.
  const ModelDescriptor({
    required this.id,
    required this.provider,
    this.displayName,
    this.raw = const <String, Object?>{},
  });

  /// The identifier to pass as `model`, exactly as the provider spells it.
  final String id;

  /// Which adapter this came from, such as `anthropic`.
  final String provider;

  /// A human-readable name, where the provider supplies one.
  final String? displayName;

  /// The provider's own description of this model, unmodified.
  final Map<String, Object?> raw;

  /// What to show a person choosing a model.
  String get label => displayName ?? id;

  @override
  String toString() => 'ModelDescriptor($provider:$id)';

  @override
  bool operator ==(Object other) =>
      other is ModelDescriptor && other.id == id && other.provider == provider;

  @override
  int get hashCode => Object.hash(id, provider);
}

/// A provider that can be asked what it serves.
///
/// Separate from `ChatModel` on purpose: implementing it is optional, so a
/// local or in-house adapter is not forced to invent a listing endpoint, and
/// adding it here never breaks anyone else's `ChatModel`. It is `Disposable`
/// for the same reason every adapter is — a listing call opens the same HTTP
/// client a generation call does.
///
/// ```dart
/// final model = AnthropicChatModel(apiKey: key);
/// if (model is ModelDirectory) {
///   for (final available in await model.listModels()) {
///     print(available.label);          // what this key may actually call
///   }
/// }
/// ```
abstract interface class ModelDirectory implements Disposable {
  /// Lists the models this provider currently serves for these credentials.
  ///
  /// Follows pagination to the end, so the result is the whole list. Throws
  /// the same typed failures as any other call: an invalid key is an
  /// [AuthenticationException], not an empty list.
  Future<List<ModelDescriptor>> listModels({AgenticContext? context});
}
