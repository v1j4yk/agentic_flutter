/// The `build_runner` entry point for `@ToolFunction`.
///
/// Configured in this package's `build.yaml`, so adding the package as a dev
/// dependency is the whole setup: `dart run build_runner build` then writes
/// the tools into each library's `.g.dart` part.
library;

import 'package:agentic_tools_generator/src/agent_tool_generator.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

/// Builds tools from `@ToolFunction` functions and methods.
Builder agentToolBuilder(BuilderOptions options) =>
    SharedPartBuilder(const <Generator>[AgentToolGenerator()], 'agent_tool');
