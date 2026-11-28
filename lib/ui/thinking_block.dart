import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/thinking.dart';
import '../theme.dart';
import 'clicky.dart';

/// What the model thought before a reply, as one control that behaves the same while the model thinks and after.
/// Its header, "Thinking… 12 s" and then "Thought for 12 s", never moves or changes shape, and a click on it opens
/// or closes the thought at any moment. It is closed to begin with: while the model thinks a light band sweeps across
/// the header and the line under it shows the latest finished sentence of the thought, changing with a short fade at
/// most every [_ThinkingBlockState._pulseEvery]. Open, the thought streams in a window that follows its end
/// unless the user has scrolled up. The time and whether it is open belong to the message ([thinkingProvider]), not
/// to this widget, so scrolling away or leaving the chat changes nothing.
class ThinkingBlock extends ConsumerStatefulWidget {
  const ThinkingBlock({
    super.key,
    required this.chatId,
    required this.index,
    required this.text,
    required this.thinking,
    this.millis,
  });

  /// The message this is the thinking of: its chat and its place in the chat.
  final String chatId;
  final int index;

  final String text;

  /// The model is still thinking.
  final bool thinking;

  /// How long it thought, once it is done.
  final int? millis;

  @override
  ConsumerState<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends ConsumerState<ThinkingBlock> with TickerProviderStateMixin {
  static const _motion = Duration(milliseconds: 180);

  /// The most the open thought shows at a time; more scrolls.
  static const _windowHeight = 240.0;

  /// The window follows the end of the thought while the view is within this much of it.
  static const _followWithin = 24.0;

  final _scroll = ScrollController();
  late final _openness = AnimationController(vsync: this, duration: _motion, value: _isOpen ? 1 : 0);
  late final _shimmer = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
  Timer? _tick;

  /// The closed line changes at most this often, so it can be read.
  static const _pulseEvery = Duration(milliseconds: 1200);

  /// How long the old sentence fades out and the new one in.
  static const _pulse = Duration(milliseconds: 260);

  /// The sentence on the closed line, and when (on the thinking clock) it came.
  String? _line;
  Duration? _lineAt;
  Timer? _lineTimer;

  ThinkingKey get _key => (chatId: widget.chatId, index: widget.index);

  bool get _isOpen => ref.read(thinkingProvider)[_key]?.open ?? false;

  /// How long the model has thought so far (while it does).
  int get _elapsed {
    final since = ref.read(thinkingProvider)[_key]?.since;
    return since == null ? widget.millis ?? 0 : (ref.read(thinkingClockProvider)() - since).inMilliseconds;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
    _pickLine();
  }

  @override
  void didUpdateWidget(ThinkingBlock old) {
    super.didUpdateWidget(old);
    final moved = old.chatId != widget.chatId || old.index != widget.index;
    if (moved) {
      _openness.value = _isOpen ? 1 : 0;
      _line = null;
      _lineAt = null;
    }
    if (widget.thinking && widget.text != old.text) _follow();
    if (old.thinking != widget.thinking || moved) _sync();
    if (old.thinking != widget.thinking || moved || widget.text != old.text) _pickLine();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _lineTimer?.cancel();
    _shimmer.dispose();
    _openness.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Starts or stops what moves while the model thinks: the shimmer of the header and the count of seconds.
  void _sync() {
    _tick?.cancel();
    if (!widget.thinking) {
      _shimmer.stop();
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _shimmer.stop();
    } else if (!_shimmer.isAnimating) {
      _shimmer.repeat();
    }
    _tick = Timer(Duration(milliseconds: millisToNextLength(_elapsed)), () {
      if (!mounted) return;
      setState(() {});
      _sync();
    });
  }

  /// Once the thought has grown, the window goes to its end, unless the user has scrolled up to read.
  void _follow() {
    final following = !_scroll.hasClients || _scroll.position.extentAfter < _followWithin;
    if (!following) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// Puts the latest finished sentence on the closed line: the first one at once, a newer one once [_pulseEvery] has
  /// passed since the last change (a timer waits for that moment). Returns whether the line changed.
  bool _pickLine() {
    _lineTimer?.cancel();
    if (!widget.thinking) return false;
    final latest = latestFinishedSentence(widget.text);
    if (latest == null || latest == _line) return false;
    final now = ref.read(thinkingClockProvider)();
    final wait = _lineAt == null ? Duration.zero : _pulseEvery - (now - _lineAt!);
    if (wait > Duration.zero) {
      _lineTimer = Timer(wait, () {
        if (mounted && _pickLine()) setState(() {});
      });
      return false;
    }
    _line = latest;
    _lineAt = now;
    return true;
  }

  void _toggle() => ref.read(thinkingProvider.notifier).toggle(_key);

  String get _title {
    if (widget.thinking) return 'Thinking… ${thoughtLength(_elapsed)}';
    final millis = widget.millis;
    return millis == null ? 'Thought' : 'Thought for ${thoughtLength(millis)}';
  }

  /// The header's words; while the model thinks a light band sweeps across them.
  Widget _shimmering(String title, TextStyle style, AppColors c) {
    if (!widget.thinking || MediaQuery.disableAnimationsOf(context)) return Text(title, style: style);
    return AnimatedBuilder(
      animation: _shimmer,
      builder: (context, _) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (rect) => LinearGradient(
          colors: [c.textMuted, c.text, c.textMuted],
          stops: const [0.35, 0.5, 0.65],
          // The band starts left of the text and ends right of it.
          transform: _Slide(_shimmer.value * 2 - 1),
        ).createShader(rect),
        child: Text(title, style: style.copyWith(color: Colors.white)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final open = ref.watch(thinkingProvider.select((m) => m[_key]?.open ?? false));
    ref.listen(thinkingProvider.select((m) => m[_key]?.open ?? false), (_, open) {
      if (open) {
        _openness.forward();
        // Opened while the model thinks: it starts at the end.
        if (widget.thinking) _follow();
      } else {
        _openness.reverse();
      }
    });
    // A new message's clock (a reply written again) restarts the count.
    ref.listen(thinkingProvider.select((m) => m[_key]?.since), (_, _) => _sync());

    final style = TextStyle(fontSize: 13, height: 1.5, color: c.textMuted, fontFeatures: const [FontFeature.tabularFigures()]);
    final title = _title;
    final header = Transform.translate(
      // (The hover fill reaches a little past the text, which still lines up with the reply's.)
      offset: const Offset(-6, 0),
      child: Clicky.builder(
        key: const Key('thinking-title'),
        radius: 6,
        label: title,
        onTap: _toggle,
        builder: (context, s) {
          final lit = s.hovered || s.pressed;
          return Semantics(
            expanded: open,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: s.pressed ? c.rowPressed : (s.hovered ? c.rowHover : Colors.transparent),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The arrow comes first, so the header's shape does not change with the words after it.
                  AnimatedRotation(
                    turns: open ? 0 : -0.25,
                    duration: _motion,
                    child: Icon(Icons.keyboard_arrow_down, size: 16, color: lit ? c.text : c.textMuted),
                  ),
                  const SizedBox(width: 2),
                  _shimmering(title, style.copyWith(color: lit ? c.text : c.textMuted), c),
                ],
              ),
            ),
          );
        },
      ),
    );

    // While the model thinks and the thought is closed: its latest finished sentence.
    final line = _line;
    final Widget preview = widget.thinking && !open && line != null
        ? Padding(
            key: const Key('thinking-preview'),
            padding: const EdgeInsets.only(left: 18, top: 1),
            child: SizedBox(
              height: 20,
              width: double.infinity,
              child: AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : _pulse,
                layoutBuilder: (current, previous) =>
                    Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
                child: Text(
                  line,
                  key: ValueKey(line),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: style.copyWith(fontSize: 12.5),
                ),
              ),
            ),
          )
        : const SizedBox(width: double.infinity);

    final body = AnimatedBuilder(
      animation: _openness,
      builder: (context, _) => _openness.isDismissed
          ? const SizedBox(width: double.infinity)
          : SizeTransition(
              sizeFactor: _openness,
              alignment: Alignment.topLeft,
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 4, left: 2),
                padding: const EdgeInsets.only(left: 12),
                decoration: BoxDecoration(border: Border(left: BorderSide(color: c.buttonBorder, width: 1.5))),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: _windowHeight),
                  child: AnimatedBuilder(
                    animation: _scroll,
                    builder: (context, child) {
                      final scrolled = _scroll.hasClients && _scroll.position.extentBefore > 4;
                      return ShaderMask(
                        // Once the first lines have scrolled off, they fade out at the top.
                        shaderCallback: (rect) => LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [scrolled ? Colors.transparent : Colors.black, Colors.black],
                          stops: const [0, 0.2],
                        ).createShader(rect),
                        blendMode: BlendMode.dstIn,
                        child: child,
                      );
                    },
                    child: SingleChildScrollView(
                      controller: _scroll,
                      child: SelectableText(widget.text, style: style),
                    ),
                  ),
                ),
              ),
            ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          header,
          AnimatedSize(duration: _motion, curve: Curves.easeOut, alignment: Alignment.topLeft, child: preview),
          body,
        ],
      ),
    );
  }
}

/// Moves a gradient sideways by [t] times its own width.
class _Slide extends GradientTransform {
  const _Slide(this.t);
  final double t;
  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) => Matrix4.translationValues(bounds.width * t, 0, 0);
}

/// The last stretch of [text] ended by `.`, `!`, `?` or a line break, trimmed (an empty stretch is skipped), with its
/// mark (not a line break); null before any has ended.
String? latestFinishedSentence(String text) {
  bool isEnd(int c) => c == 0x2E || c == 0x21 || c == 0x3F || c == 0x0A;
  var end = text.length - 1;
  while (end >= 0) {
    while (end >= 0 && !isEnd(text.codeUnitAt(end))) {
      end--;
    }
    if (end < 0) return null;
    var start = end - 1;
    while (start >= 0 && !isEnd(text.codeUnitAt(start))) {
      start--;
    }
    final sentence = text.substring(start + 1, end).trim();
    if (sentence.isNotEmpty) return text[end] == '\n' ? sentence : '$sentence${text[end]}';
    end = start;
  }
  return null;
}
