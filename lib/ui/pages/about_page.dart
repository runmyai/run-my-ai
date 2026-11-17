import 'dart:math' as math;

import 'package:flutter/foundation.dart' show LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/about.dart';
import '../../system/open_url.dart';
import '../../theme.dart';
import '../buttons.dart';
import '../clicky.dart';

/// The licence texts that ship with the app, as (name, asset) pairs: the app's own, the engine's (which carries the
/// ggml authors' notice) and ik_llama.cpp's, whose code the engine uses.
const bundledLicenses = [
  ('Run My AI', 'assets/licenses/LICENSE-run-my-ai'),
  ('TokenWing, the engine (with llama.cpp and ggml)', 'assets/licenses/LICENSE-tokenwing'),
  ('ik_llama.cpp', 'assets/licenses/LICENSE-ik_llama.cpp'),
];

/// The projects and papers the engine draws on, and the people behind its first designs of expert streaming. Kept the
/// same as the engine's "Thanks" section.
const thanksProjects = [
  'llama.cpp', 'ik_llama.cpp', 'ktransformers', 'BELLS', 'Strata', 'AI-der', 'Colibri', 'Pulsar', 'FATE', //
  'Pre-gated MoE', 'ProMoE', 'MoE-Infinity', 'PreScope', 'BigMoeOnEdge', 'apus', 'slotstream', 'MoE-Direct',
  'Fiddler', 'nvmoe', 'qwen-fieldfare', 'vllm-expert-cache', 'PowerInfer',
];
const thanksPeople = ['freedomljc', 'leloch', 'hikarioyama', 'grawnchtoader'];

/// What the author's card says, and the two places it links to.
const authorName = 'Harin Mani Karri';
const authorQuote = "Just another typical nerd you wouldn't find around.";
const authorBio =
    '2nd-year student at Scaler School of Technology, Bangalore, India. '
    "I build games, optimizing tools and I love solving problems. Run My AI is what I'm building now.";
const authorLinks = [
  ('GitHub', 'https://github.com/HarinManiK'),
  ('LinkedIn', 'https://www.linkedin.com/in/harinmani/'),
];

/// The co-founder's card: no photo (a plain person icon instead).
const grawnchName = 'Grawnch';
const grawnchQuote = 'Make no mistakes, run the benchmark again';
const grawnchBio =
    'Math and systems tinkerer obsessed with extreme model compression and optimization. '
    'Built the Grawnch quants to make frontier models actually runnable on normal hardware.';
const grawnchLinks = [('Hugging Face', 'https://huggingface.co/Grawnch')];

/// One licence: whose it is and its text.
typedef Licence = ({String name, String text});

/// The licences of the Flutter framework and the packages the app uses, one entry per package, from what the build
/// registered. Empty when there are none.
Future<List<Licence>> packageLicenses() async {
  final byPackage = <String, List<String>>{};
  try {
    await for (final entry in LicenseRegistry.licenses) {
      final text = [for (final p in entry.paragraphs) '${'    ' * math.max(p.indent, 0)}${p.text}'].join('\n\n');
      for (final package in entry.packages) {
        final texts = byPackage.putIfAbsent(package, () => []);
        if (!texts.contains(text)) texts.add(text);
      }
    }
  } on Exception {
    // What was read so far is shown.
  }
  final names = byPackage.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return [for (final name in names) (name: name, text: byPackage[name]!.join('\n\n--------\n\n'))];
}

Future<List<Licence>> _bundled() async => [
  for (final (name, asset) in bundledLicenses) (name: name, text: (await rootBundle.loadString(asset)).trim()),
];

/// About: the app's and the engine's versions, who made them and who they build on, and the licences of all of it.
/// [onBack] returns to Settings.
class AboutPage extends ConsumerStatefulWidget {
  const AboutPage({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  ConsumerState<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends ConsumerState<AboutPage> {
  final _bundledTexts = _bundled();
  final _packageTexts = packageLicenses();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final engine = ref.watch(engineVersionProvider);
    final engineVersion = engine.when(
      data: (version) => version ?? 'unknown',
      loading: () => '…',
      error: (_, _) => 'unknown',
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 28, 40, 40),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: AppButton(
            key: const Key('about-back'),
            label: 'Settings',
            icon: Icons.chevron_left,
            dense: true,
            onTap: widget.onBack,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'About',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: c.text),
        ),
        const SizedBox(height: 24),
        const _AuthorCard(
          id: 'about-author',
          name: authorName,
          quote: authorQuote,
          bio: authorBio,
          links: authorLinks,
          photo: 'assets/author/author.png',
        ),
        const SizedBox(height: 12),
        const _AuthorCard(
          id: 'about-grawnch',
          name: grawnchName,
          quote: grawnchQuote,
          bio: grawnchBio,
          links: grawnchLinks,
        ),
        const SizedBox(height: 28),
        const _Heading('Versions'),
        const SizedBox(height: 12),
        _Version(id: 'about-app-version', name: 'Run My AI', value: appVersion),
        const SizedBox(height: 6),
        _Version(id: 'about-engine-version', name: 'TokenWing engine', value: engineVersion),
        const SizedBox(height: 28),
        const _Heading('Credits'),
        const SizedBox(height: 12),
        const _Paragraph('Run My AI and TokenWing are made by Harin Mani Karri.'),
        const SizedBox(height: 8),
        const _Paragraph('TokenWing is built on llama.cpp and its ggml library, with parts from ik_llama.cpp.'),
        const SizedBox(height: 8),
        _Paragraph(
          'Thanks to the projects and papers whose work it draws on: ${thanksProjects.join(', ')}; '
          'and to ${_list(thanksPeople)}, whose designs and code it started from.',
        ),
        const SizedBox(height: 28),
        const _Heading('Licences'),
        const SizedBox(height: 2),
        Text(
          'Run My AI and TokenWing are free software under the MIT licence. Choose one to read it.',
          style: TextStyle(fontSize: 13, color: c.textSecondary),
        ),
        const SizedBox(height: 12),
        _Licenses(id: 'about-licenses', texts: _bundledTexts),
        const SizedBox(height: 24),
        const _Heading('Flutter and its packages'),
        const SizedBox(height: 12),
        _Licenses(id: 'about-package-licenses', texts: _packageTexts),
      ],
    );
  }

  static String _list(List<String> names) =>
      names.length < 2 ? names.join() : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: context.colors.text),
  );
}

class _Paragraph extends StatelessWidget {
  const _Paragraph(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: TextStyle(fontSize: 13.5, height: 1.45, color: context.colors.textSecondary));
}

/// One of the makers: a round photo (or a plain person icon), the name, a quote, a few words and links that open in
/// the browser.
class _AuthorCard extends StatelessWidget {
  const _AuthorCard({
    required this.id,
    required this.name,
    required this.quote,
    required this.bio,
    required this.links,
    this.photo,
  });

  final String id;
  final String name;
  final String quote;
  final String bio;
  final List<(String, String)> links;
  final String? photo;

  static const _photo = 96.0;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DecoratedBox(
      key: Key(id),
      decoration: BoxDecoration(
        color: c.inputFill,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: c.border, width: 2),
              ),
              child: ClipOval(
                child: photo == null
                    ? SizedBox(
                        width: _photo,
                        height: _photo,
                        child: ColoredBox(
                          color: c.page,
                          child: Icon(Icons.person, size: _photo * 0.55, color: c.textMuted, semanticLabel: name),
                        ),
                      )
                    : Image.asset(
                        photo!,
                        key: Key('$id-photo'),
                        width: _photo,
                        height: _photo,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.medium,
                        semanticLabel: name,
                      ),
              ),
            ),
            const SizedBox(width: 22),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: c.text),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.only(left: 12),
                    decoration: BoxDecoration(
                      border: Border(left: BorderSide(color: c.textMuted, width: 2)),
                    ),
                    child: Text(
                      '“$quote”',
                      style: TextStyle(fontSize: 14, height: 1.4, fontWeight: FontWeight.w500, color: c.text),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _Paragraph(bio),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (label, url) in links)
                        AppButton(
                          key: Key('about-link-$label'),
                          label: label,
                          trailingIcon: Icons.north_east,
                          dense: true,
                          onTap: () => openUrl(url),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A name and its version, side by side.
class _Version extends StatelessWidget {
  const _Version({required this.id, required this.name, required this.value});

  final String id;
  final String name;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Text(name, style: TextStyle(fontSize: 13.5, color: c.textSecondary)),
        ),
        Expanded(
          child: SelectableText(
            value,
            key: Key(id),
            style: TextStyle(fontSize: 13.5, color: c.text),
          ),
        ),
      ],
    );
  }
}

/// A list of licences, one row each; a row opens to its text. [texts] may still be loading.
class _Licenses extends StatefulWidget {
  const _Licenses({required this.id, required this.texts});

  final String id;
  final Future<List<Licence>> texts;

  @override
  State<_Licenses> createState() => _LicensesState();
}

class _LicensesState extends State<_Licenses> {
  final _open = <String>{};

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return FutureBuilder(
      future: widget.texts,
      builder: (context, snapshot) {
        final licences = snapshot.data;
        if (licences == null || licences.isEmpty) {
          final text = snapshot.hasError || snapshot.connectionState == ConnectionState.done
              ? 'No licence texts were found.'
              : 'Loading…';
          return Text(text, style: TextStyle(fontSize: 13, color: c.textMuted));
        }
        return DecoratedBox(
          key: Key(widget.id),
          decoration: BoxDecoration(
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: Column(
              children: [
                for (var i = 0; i < licences.length; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, color: c.border),
                  _Licence(
                    licence: licences[i],
                    open: _open.contains(licences[i].name),
                    onTap: () => setState(() {
                      if (!_open.remove(licences[i].name)) _open.add(licences[i].name);
                    }),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Licence extends StatelessWidget {
  const _Licence({required this.licence, required this.open, required this.onTap});

  final Licence licence;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Clicky.builder(
          key: Key('licence-${licence.name}'),
          onTap: onTap,
          radius: 0,
          label: licence.name,
          builder: (context, s) => ColoredBox(
            color: s.pressed
                ? c.rowPressed
                : s.hovered
                ? c.rowHover
                : Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Row(
                children: [
                  Expanded(
                    child: Text(licence.name, style: TextStyle(fontSize: 13.5, color: c.text)),
                  ),
                  Icon(open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 18, color: c.textMuted),
                ],
              ),
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: SelectableText(
              licence.text,
              style: TextStyle(fontSize: 12, height: 1.4, color: c.textSecondary, fontFamily: 'monospace'),
            ),
          ),
      ],
    );
  }
}
