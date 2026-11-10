import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/thinking.dart';
import '../theme.dart';
import 'clicky.dart';

/// What the model thought before a reply, as one control that behaves the same while the model thinks and after.
/// Its header, "Thinking… 12 s" and then "Thought for 12 s", never moves or changes shape, and a click on it opens
/// or closes the thought at any moment. It is closed to begin with: while the model thinks the header pulses and a
/// line under it shows the latest line of the thought. Open, the thought streams in a window that follows its end
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
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
  late final _glow = Tween(begin: 1.0, end: 0.5).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
  Timer? _tick;

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
  }

  @override
  void didUpdateWidget(ThinkingBlock old) {
    super.didUpdateWidget(old);
    if (old.chatId != widget.chatId || old.index != widget.index) _openness.value = _isOpen ? 1 : 0;
    if (widget.thinking && widget.text != old.text) _follow();
    if (old.thinking != widget.thinking || old.chatId != widget.chatId || old.index != widget.index) _sync();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _pulse.dispose();
    _openness.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Starts or stops what moves while the model thinks: the pulse of the header and the count of seconds.
  void _sync() {
    _tick?.cancel();
    if (!widget.thinking) {
      _pulse.animateTo(0, duration: _motion);
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.value = 0;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
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

  void _toggle() => ref.read(thinkingProvider.notifier).toggle(_key);

  String get _title {
    if (widget.thinking) return 'Thinking… ${thoughtLength(_elapsed)}';
    final millis = widget.millis;
    return millis == null ? 'Thought' : 'Thought for ${thoughtLength(millis)}';
  }

  /// The latest line of the thought, and a number that changes when a new line begins.
  (String, int) get _latestLine {
    final text = widget.text.trimRight();
    final start = text.lastIndexOf('\n');
    var line = text.substring(start + 1).trim();
    // A long line shows its end, from a whole word.
    if (line.length > 160) {
      line = line.substring(line.length - 160);
      final space = line.indexOf(' ');
      line = '…${space < 0 ? line : line.substring(space + 1)}';
    }
    return (line, start);
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
                  Text(title, style: style.copyWith(color: lit ? c.text : c.textMuted)),
                ],
              ),
            ),
          );
        },
      ),
    );

    // While the model thinks and the thought is closed: its latest line, fading in as it changes.
    final (line, lineKey) = _latestLine;
    final Widget preview = widget.thinking && !open && line.isNotEmpty
        ? Padding(
            key: const Key('thinking-preview'),
            padding: const EdgeInsets.only(left: 18, top: 1),
            child: SizedBox(
              height: 20,
              width: double.infinity,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.centerLeft,
                  children: [...previous, ?current],
                ),
                child: Text(
                  line,
                  key: ValueKey(lineKey),
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
          // The header pulses gently while the model thinks.
          FadeTransition(opacity: _glow, child: header),
          AnimatedSize(duration: _motion, curve: Curves.easeOut, alignment: Alignment.topLeft, child: preview),
          body,
        ],
      ),
    );
  }
}
