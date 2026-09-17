/// Generates agentic_tools tools from `@ToolFunction` functions and methods.
///
/// Add this package as a dev dependency and run `dart run build_runner build`;
/// the builder is configured in this package's `build.yaml`, so there is
/// nothing to import. The library exists for code that drives the builder
/// directly, such as its own tests.
library;

export 'builder.dart' show agentToolBuilder;
