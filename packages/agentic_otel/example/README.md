# Example

Run a collector, then the example:

```sh
docker run --rm -p 4318:4318 otel/opentelemetry-collector
dart run example/agentic_otel_example.dart
```

Without a collector the export fails, says so through `onError`, and the run
finishes — which is the point.
