import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/feedback.dart';
import '../../theme.dart';
import '../buttons.dart';

/// Settings: a line and a button that opens the feedback form.
class FeedbackSection extends StatelessWidget {
  const FeedbackSection({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Send feedback',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: c.text),
        ),
        const SizedBox(height: 2),
        Text(
          'An idea, a bug, or something you like: it goes straight to us.',
          style: TextStyle(fontSize: 13, color: c.textSecondary),
        ),
        const SizedBox(height: 12),
        AppButton(
          key: const Key('feedback-open'),
          label: 'Send feedback',
          icon: Icons.chat_bubble_outline,
          onTap: () => showDialog<void>(context: context, builder: (_) => const FeedbackForm()),
        ),
      ],
    );
  }
}

/// The feedback form: the kind, the message, an email for a reply, and whether the engine's log goes with it.
class FeedbackForm extends ConsumerStatefulWidget {
  const FeedbackForm({super.key});

  @override
  ConsumerState<FeedbackForm> createState() => _FeedbackFormState();
}

class _FeedbackFormState extends ConsumerState<FeedbackForm> {
  final _message = TextEditingController();
  final _email = TextEditingController();

  @override
  void dispose() {
    _message.dispose();
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final form = ref.watch(feedbackProvider);
    final notifier = ref.read(feedbackProvider.notifier);
    final sending = form.phase == FeedbackPhase.sending;
    final sent = form.phase == FeedbackPhase.sent;

    InputDecoration decoration(String hint) => InputDecoration(
      isDense: true,
      hintText: hint,
      hintStyle: TextStyle(color: c.textMuted),
      counterText: '',
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: c.inputBorder),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: c.inputBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: c.text.withValues(alpha: 0.35)),
      ),
    );

    final fields = <Widget>[
      Wrap(
        spacing: 8,
        children: [
          for (final kind in FeedbackKind.values)
            OptionPill(
              key: Key('feedback-kind-${kind.id}'),
              label: kind.label,
              chosen: form.kind == kind,
              onTap: sending ? null : () => notifier.setKind(kind),
            ),
        ],
      ),
      const SizedBox(height: 14),
      TextField(
        key: const Key('feedback-message'),
        controller: _message,
        enabled: !sending,
        autofocus: true,
        minLines: 5,
        maxLines: 10,
        maxLength: feedbackMessageMax,
        onChanged: (_) => setState(() {}),
        style: TextStyle(fontSize: 13, height: 1.4, color: c.text),
        cursorColor: c.text,
        decoration: decoration('What would you like to tell us?'),
      ),
      const SizedBox(height: 10),
      TextField(
        key: const Key('feedback-email'),
        controller: _email,
        enabled: !sending,
        maxLength: feedbackEmailMax,
        keyboardType: TextInputType.emailAddress,
        style: TextStyle(fontSize: 13, color: c.text),
        cursorColor: c.text,
        decoration: decoration('Your email, if you would like a reply (optional)'),
      ),
      const SizedBox(height: 6),
      InkWell(
        key: const Key('feedback-log'),
        borderRadius: BorderRadius.circular(8),
        onTap: sending ? null : () => notifier.setAttachLog(!form.attachLog),
        child: Row(
          children: [
            Checkbox(
              value: form.attachLog,
              onChanged: sending ? null : (v) => notifier.setAttachLog(v ?? false),
              activeColor: c.mainFill,
              checkColor: c.mainText,
              side: BorderSide(color: c.buttonBorder, width: 1.5),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Text("Attach the engine's log (no chat text)", style: TextStyle(fontSize: 13, color: c.text)),
            ),
          ],
        ),
      ),
      if (form.phase == FeedbackPhase.failed) ...[
        const SizedBox(height: 6),
        Text(
          'Could not send. Check your internet connection and try again.',
          key: const Key('feedback-error'),
          style: TextStyle(fontSize: 13, color: c.danger),
        ),
      ],
    ];

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                sent ? 'Thank you' : 'Send feedback',
                key: const Key('feedback-title'),
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: c.text),
              ),
              const SizedBox(height: 12),
              if (sent)
                Text(
                  'Your feedback has been sent. We read every message.',
                  key: const Key('feedback-sent'),
                  style: TextStyle(fontSize: 13, height: 1.4, color: c.textSecondary),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: fields,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  AppButton(
                    key: const Key('feedback-close'),
                    label: 'Close',
                    onTap: () => Navigator.pop(context),
                  ),
                  if (!sent)
                    MainButton(
                      key: const Key('feedback-send'),
                      label: sending ? 'Sending…' : 'Send',
                      onTap: sending || _message.text.trim().isEmpty
                          ? null
                          : () => notifier.send(_message.text, _email.text),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
