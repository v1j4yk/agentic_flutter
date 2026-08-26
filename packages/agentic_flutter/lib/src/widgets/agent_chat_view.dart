/// A chat screen you can drop in, and the pieces to build your own.
library;

import 'dart:async';
import 'dart:math' show pi, sin;

import 'package:agentic_core/agentic_core.dart';
import 'package:agentic_flutter/src/widgets/agent_chat_controller.dart';
import 'package:flutter/material.dart';

/// A complete chat surface over an [AgentChatController].
///
/// # What this is and is not
///
/// It is a working chat screen: transcript, composer, activity line, stop
/// button, error rendering. It is *not* a design system, and it is not trying
/// to be the chat UI of a shipped product — every real one has its own
/// typography, avatars, attachments and empty states.
///
/// The parts it is built from — [ChatEntryTile], [ChatComposer] — are public
/// for exactly that reason. Use the whole thing to get moving, then keep the
/// controller and replace this widget when the design arrives.
///
/// # Testing against it
///
/// While a turn is in flight this shows indeterminate progress — typing dots
/// before the first token, a spinner while a tool runs — and an indeterminate
/// animation never settles. `tester.pumpAndSettle()` therefore times out for
/// as long as a turn is running, exactly as it does around a
/// `CircularProgressIndicator`.
///
/// Drive those stretches with `tester.pump(duration)` instead. Once the turn
/// finishes, nothing is animating and `pumpAndSettle` is fine again.
///
/// ```dart
/// AgentChatView(
///   controller: AgentChatController(agent: agent, runtime: runtime),
///   emptyState: const Text('Ask me anything about the handbook.'),
/// );
/// ```
class AgentChatView extends StatefulWidget {
  /// Creates a chat view.
  const AgentChatView({
    required this.controller,
    this.emptyState,
    this.hintText = 'Send a message',
    this.padding = const EdgeInsets.all(16),
    this.entryBuilder,
    super.key,
  });

  /// The controller driving the conversation.
  final AgentChatController controller;

  /// Shown while the transcript is empty.
  final Widget? emptyState;

  /// Placeholder text in the composer.
  final String hintText;

  /// Padding around the transcript.
  final EdgeInsets padding;

  /// Renders one entry, when the default tile is not wanted.
  final Widget Function(BuildContext context, ChatEntry entry)? entryBuilder;

  @override
  State<AgentChatView> createState() => _AgentChatViewState();
}

class _AgentChatViewState extends State<AgentChatView> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(AgentChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    // Scrolled after the frame that renders the new text, not before it: the
    // maximum extent is not yet correct while a streaming token is still being
    // laid out, and scrolling early lands a few pixels short every time.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      unawaited(
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        ),
      );
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || widget.controller.isBusy) return;
    _input.clear();
    await widget.controller.send(text);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final entries = widget.controller.entries;
      return Column(
        children: <Widget>[
          Expanded(
            child: entries.isEmpty && widget.emptyState != null
                ? Center(child: widget.emptyState)
                : ListView.builder(
                    controller: _scroll,
                    padding: widget.padding,
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return widget.entryBuilder?.call(context, entry) ??
                          ChatEntryTile(
                            key: ValueKey<String>(entry.id),
                            entry: entry,
                          );
                    },
                  ),
          ),
          ChatComposer(
            controller: _input,
            hintText: widget.hintText,
            isBusy: widget.controller.isBusy,
            onSend: _send,
            onStop: widget.controller.cancel,
          ),
        ],
      );
    },
  );
}

/// One entry in the transcript.
class ChatEntryTile extends StatelessWidget {
  /// Creates a tile.
  const ChatEntryTile({required this.entry, super.key});

  /// What to render.
  final ChatEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = entry.role == MessageRole.user;
    final error = entry.error;
    final isPending = entry.text.isEmpty && entry.isStreaming && error == null;

    final Color background;
    final Color foreground;
    if (error != null) {
      background = theme.colorScheme.errorContainer;
      foreground = theme.colorScheme.onErrorContainer;
    } else if (isUser) {
      background = theme.colorScheme.primary;
      foreground = theme.colorScheme.onPrimary;
    } else {
      background = theme.colorScheme.surfaceContainerHigh;
      foreground = theme.colorScheme.onSurface;
    }

    // A square corner on the side the message came from. It is the one cue
    // that survives being glanced at rather than read, which is how a
    // conversation is actually scanned.
    const round = Radius.circular(20);
    const tail = Radius.circular(6);

    final bubble = DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.only(
          topLeft: round,
          topRight: round,
          bottomLeft: isUser ? round : tail,
          bottomRight: isUser ? tail : round,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: isPending
            ? _TypingDots(color: foreground)
            : SelectableText(
                error != null ? _describeError(error) : entry.text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: foreground,
                  height: 1.4,
                ),
              ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (!isUser) ...<Widget>[
            _Avatar(isError: error != null),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.74,
              ),
              child: Column(
                crossAxisAlignment: isUser
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: <Widget>[
                  bubble,
                  if (entry.toolCalls.isNotEmpty || entry.activity != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        alignment: isUser
                            ? WrapAlignment.end
                            : WrapAlignment.start,
                        children: <Widget>[
                          // Tool calls get one chip each rather than a joined
                          // string. Which tools ran is the thing a person is
                          // looking for when an answer surprises them, and a
                          // chip is findable in a way that `a → b → c` is not.
                          for (final call in entry.toolCalls)
                            _ToolChip(label: call),
                          if (entry.activity != null)
                            _ActivityLabel(text: entry.activity!),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Turns a framework failure into something a person can act on.
  ///
  /// The exception's own message is written for a developer. Adding one line
  /// about what to *do* is the difference between a user retrying and a user
  /// leaving.
  static String _describeError(AgenticException error) => switch (error) {
    AuthenticationException() =>
      'The API key was rejected. Check it in settings.',
    RateLimitException() =>
      'The provider is rate-limiting requests. Try again in a moment.',
    QuotaExceededException() =>
      'This account is out of credit. Waiting will not help.',
    AgenticTimeoutException() => 'That took too long and was stopped.',
    _ =>
      error.isRetryable
          ? '${error.message}\n\nThis usually works on a retry.'
          : error.message,
  };
}

/// The small circle that marks a message as the agent's rather than the user's.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.isError});

  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 32,
      height: 32,
      // Nudged down so the icon sits level with the first line of text rather
      // than with the top of the bubble's padding.
      margin: const EdgeInsets.only(top: 2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isError ? scheme.errorContainer : scheme.primaryContainer,
      ),
      child: Icon(
        isError ? Icons.error_outline : Icons.auto_awesome,
        size: 17,
        color: isError ? scheme.onErrorContainer : scheme.onPrimaryContainer,
      ),
    );
  }
}

/// One tool the agent used, named.
class _ToolChip extends StatelessWidget {
  const _ToolChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.bolt, size: 13, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 3),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// What the agent is doing right now, in words.
class _ActivityLabel extends StatelessWidget {
  const _ActivityLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: 10,
          height: 10,
          child: CircularProgressIndicator(
            strokeWidth: 1.6,
            color: theme.colorScheme.outline,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          text,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }
}

/// Three dots that rise in turn while the first token is awaited.
///
/// Replaces a static `…`, which is indistinguishable from a message that
/// genuinely ends in an ellipsis and gives no sign that anything is happening.
class _TypingDots extends StatefulWidget {
  const _TypingDots({required this.color});

  final Color color;

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 20,
    child: AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var i = 0; i < 3; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 5),
            Transform.translate(
              // Each dot is a third of a cycle behind the one before it.
              offset: Offset(
                0,
                -3 * _bounce((_controller.value + i / 3) % 1.0),
              ),
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: 0.55),
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );

  /// A single hump over the first half of the cycle, flat for the rest.
  static double _bounce(double t) => t < 0.5 ? sin(t * 2 * pi) : 0;
}

/// The input row: a field, a send button, and a stop button while busy.
class ChatComposer extends StatelessWidget {
  /// Creates a composer.
  const ChatComposer({
    required this.controller,
    required this.onSend,
    this.onStop,
    this.isBusy = false,
    this.hintText = 'Send a message',
    super.key,
  });

  /// The text being typed.
  final TextEditingController controller;

  /// Called when the user sends.
  final VoidCallback onSend;

  /// Called when the user stops a run in progress.
  final VoidCallback? onStop;

  /// Whether a turn is running.
  final bool isBusy;

  /// Placeholder text.
  final String hintText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                style: theme.textTheme.bodyMedium,
                decoration: InputDecoration(
                  hintText: hintText,
                  hintStyle: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                  // A pill rather than a rectangle, and no visible border until
                  // focus: at the bottom of a conversation the field should
                  // read as somewhere to type, not as a form control.
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(color: theme.colorScheme.primary),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // A stop button that only appears while busy, rather than a
            // disabled send button. Users need a way out of a slow turn far
            // more than they need to be told they cannot send another.
            if (isBusy && onStop != null)
              IconButton.filledTonal(
                onPressed: onStop,
                icon: const Icon(Icons.stop_rounded),
                tooltip: 'Stop',
                style: _buttonStyle,
              )
            else
              IconButton.filled(
                onPressed: isBusy ? null : onSend,
                icon: const Icon(Icons.arrow_upward_rounded),
                tooltip: 'Send',
                style: _buttonStyle,
              ),
          ],
        ),
      ),
    );
  }

  /// Sized to match the pill's height so the row reads as one control.
  static final ButtonStyle _buttonStyle = IconButton.styleFrom(
    minimumSize: const Size(48, 48),
    padding: EdgeInsets.zero,
  );
}
