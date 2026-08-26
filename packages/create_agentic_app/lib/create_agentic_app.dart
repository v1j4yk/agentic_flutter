/// Generates a working Flutter app built on the agentic framework.
///
/// ```sh
/// dart pub global activate create_agentic_app
/// create_agentic_app my_app --provider=anthropic
/// ```
///
/// The library is exposed as well as the executable so the framework's own CI
/// can generate a project into a temporary directory and compile it — which is
/// the only thing that keeps a template from rotting.
library;

export 'src/generator.dart' show GenerationResult, generate;
export 'src/project_name.dart' show titleFor, validateProjectName;
export 'src/templates.dart' show TemplateProvider, buildProject;
