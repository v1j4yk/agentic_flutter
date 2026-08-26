/// An explicit success-or-failure value.
///
/// The framework throws [AgenticException] from its asynchronous APIs, because
/// that is Dart's idiom and it is what composes with `await` and `Stream`.
/// [Result] is the opt-in complement for the places where a value reads better
/// than a `try` block:
///
/// * fan-out, where some branches fail and the failures must be collected
///   rather than propagated — a parallel workflow node, a multi-agent round;
/// * batch operations, where a partial success is the expected outcome — a
///   RAG ingestion run over two hundred documents;
/// * boundaries that must not throw, such as an isolate's return channel.
///
/// [Result] is `sealed`, unlike [AgenticException]: there are exactly two
/// outcomes and nobody needs a third, so exhaustive `switch` is a feature here
/// rather than a restriction.
///
/// ```dart
/// final result = await Result.guardAsync(() => model.generate(request));
/// final text = switch (result) {
///   Ok(:final value) => value.text,
///   Err(:final error) => 'failed: ${error.message}',
/// };
/// ```
library;

import 'dart:async';

import 'package:agentic_core/src/error/agentic_exception.dart';
import 'package:meta/meta.dart';

/// The outcome of a computation that either produced a [T] or failed.
@immutable
sealed class Result<T> {
  /// Const-constructible base for the two outcomes.
  const Result();

  /// Creates a successful result holding [value].
  const factory Result.ok(T value) = Ok<T>;

  /// Creates a failed result holding [error].
  const factory Result.err(AgenticException error) = Err<T>;

  /// Runs [action], capturing any thrown error as an [Err].
  ///
  /// Errors that are not already an [AgenticException] are wrapped in an
  /// [UnexpectedException] so that [Err.error] is always well-typed and always
  /// serialisable.
  static Result<T> guard<T>(T Function() action) {
    try {
      return Ok<T>(action());
    } on AgenticException catch (error) {
      return Err<T>(error);
    } on Object catch (error, stackTrace) {
      return Err<T>(
        UnexpectedException(
          'Computation failed: $error',
          cause: error,
          causeStackTrace: stackTrace,
        ),
      );
    }
  }

  /// Runs the asynchronous [action], capturing any thrown error as an [Err].
  ///
  /// The returned future never completes with an error, which is exactly what
  /// makes this safe to use with `Future.wait` when one failing branch must not
  /// abort the others.
  ///
  /// ```dart
  /// final results = await Future.wait(
  ///   documents.map((d) => Result.guardAsync(() => ingest(d))),
  /// );
  /// final failed = results.whereType<Err<Document>>().length;
  /// ```
  static Future<Result<T>> guardAsync<T>(FutureOr<T> Function() action) async {
    try {
      return Ok<T>(await action());
    } on AgenticException catch (error) {
      return Err<T>(error);
    } on Object catch (error, stackTrace) {
      return Err<T>(
        UnexpectedException(
          'Asynchronous computation failed: $error',
          cause: error,
          causeStackTrace: stackTrace,
        ),
      );
    }
  }

  /// Partitions [results] into successful values and failures, in order.
  ///
  /// The natural finish to a fan-out: run everything, then decide what a
  /// partial failure means for this particular call site.
  static (List<T> values, List<AgenticException> errors) partition<T>(
    Iterable<Result<T>> results,
  ) {
    final values = <T>[];
    final errors = <AgenticException>[];
    for (final result in results) {
      switch (result) {
        case Ok<T>(:final value):
          values.add(value);
        case Err<T>(:final error):
          errors.add(error);
      }
    }
    return (values, errors);
  }

  /// Whether this result holds a value.
  bool get isOk => this is Ok<T>;

  /// Whether this result holds an error.
  bool get isErr => this is Err<T>;

  /// The value, or `null` when this result is an [Err].
  ///
  /// Ambiguous when `T` is itself nullable; prefer a `switch` in that case.
  T? get valueOrNull => switch (this) {
    Ok<T>(:final value) => value,
    Err<T>() => null,
  };

  /// The error, or `null` when this result is an [Ok].
  AgenticException? get errorOrNull => switch (this) {
    Ok<T>() => null,
    Err<T>(:final error) => error,
  };

  /// Collapses both outcomes into a single [R].
  R fold<R>({
    required R Function(T value) onOk,
    required R Function(AgenticException error) onErr,
  }) => switch (this) {
    Ok<T>(:final value) => onOk(value),
    Err<T>(:final error) => onErr(error),
  };

  /// Transforms a successful value with [transform], leaving errors untouched.
  ///
  /// [transform] is not guarded: if it can fail, use [flatMap] with
  /// [Result.guard] so the failure becomes part of the result rather than an
  /// exception escaping from a `map` call.
  Result<R> map<R>(R Function(T value) transform) => switch (this) {
    Ok<T>(:final value) => Ok<R>(transform(value)),
    Err<T>(:final error) => Err<R>(error),
  };

  /// Transforms a failure with [transform], leaving successes untouched.
  ///
  /// Used at layer boundaries to re-describe a low-level failure in the
  /// vocabulary of the layer above.
  Result<T> mapError(
    AgenticException Function(AgenticException error) transform,
  ) => switch (this) {
    Ok<T>() => this,
    Err<T>(:final error) => Err<T>(transform(error)),
  };

  /// Chains another fallible computation onto a successful value.
  Result<R> flatMap<R>(Result<R> Function(T value) transform) => switch (this) {
    Ok<T>(:final value) => transform(value),
    Err<T>(:final error) => Err<R>(error),
  };

  /// Returns the value, throwing [Err.error] when this result is a failure.
  ///
  /// The bridge back into the throwing world. Use it at the point where a
  /// caller genuinely wants the exception, not as a shortcut for handling it.
  T unwrap() => switch (this) {
    Ok<T>(:final value) => value,
    Err<T>(:final error) => throw error,
  };

  /// Returns the value, or [fallback] when this result is a failure.
  T unwrapOr(T fallback) => switch (this) {
    Ok<T>(:final value) => value,
    Err<T>() => fallback,
  };

  /// Returns the value, or the result of [recover] when this is a failure.
  T unwrapOrElse(T Function(AgenticException error) recover) => switch (this) {
    Ok<T>(:final value) => value,
    Err<T>(:final error) => recover(error),
  };
}

/// A successful [Result] holding [value].
@immutable
final class Ok<T> extends Result<T> {
  /// Creates a successful result.
  const Ok(this.value);

  /// The produced value.
  final T value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Ok<T> &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => Object.hash(Ok<T>, value);

  @override
  String toString() => 'Ok($value)';
}

/// A failed [Result] holding [error].
@immutable
final class Err<T> extends Result<T> {
  /// Creates a failed result.
  const Err(this.error);

  /// The failure.
  final AgenticException error;

  /// Re-types this failure for a different value type.
  ///
  /// Errors carry no `T`, so propagating one across a type change is free.
  /// This makes that explicit at call sites that cannot use [Result.map].
  Err<R> cast<R>() => Err<R>(error);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Err<T> &&
          runtimeType == other.runtimeType &&
          error == other.error;

  @override
  int get hashCode => Object.hash(Err<T>, error);

  @override
  String toString() => 'Err(${error.code}: ${error.message})';
}

/// Bridges a throwing [Future] into a [Result].
extension ResultFuture<T> on Future<T> {
  /// Awaits this future, capturing any error as an [Err].
  ///
  /// ```dart
  /// final result = await model.generate(request).toResult();
  /// ```
  Future<Result<T>> toResult() => Result.guardAsync(() => this);
}
