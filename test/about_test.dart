// The About page (lib/ui/pages/about_page.dart): the versions it shows, its credits and licences, and how Settings opens
// it. The files that must stay equal to their sources (the licence texts, the thanks list, the version) are checked
// against them when the engine's folder is next to the app.
// Run: flutter test test/about_test.dart
import 'dart:io';

import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/dummy_backend.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/engine/engine_version.dart';
import 'package:runmyai/state/about.dart';
import 'package:runmyai/state/library.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/system/open_url.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/pages/about_page.dart';
import 'package:runmyai/ui/pages/settings_page.dart';

void main() {
  group('versions', () {
    test('the engine\'s own --version output is read', () {
      const output = 'version: 0.8.0-dev (build 12270, commit 1d839794e)\nbuilt with GNU 16.2.1 for Linux x86_64\n';
      expect(parseEngineVersion(output), '0.8.0-dev (build 12270, commit 1d839794e)');
      expect(parseEngineVersion('usage: llama-server [options]\n'), isNull);
      expect(parseEngineVersion(''), isNull);
    });

    test('a program in the folder is asked; a folder without one gives null', () async {
      final folder = Directory.systemTemp.createTempSync('runmyai-engine-');
      addTearDown(() => folder.deleteSync(recursive: true));
      expect(await readEngineVersion(folder.path), isNull);
      if (Platform.isWindows) return;
      final program = File('${folder.path}/llama-server')
        ..writeAsStringSync('#!/bin/sh\necho "version: 1.2.3 (build 4, commit abc)" >&2\n');
      Process.runSync('chmod', ['+x', program.path]);
      expect(await readEngineVersion(folder.path), '1.2.3 (build 4, commit abc)');
    });

    test('the app\'s version is the one in pubspec.yaml', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(RegExp(r'^version:\s*([^+\s]+)', multiLine: true).firstMatch(pubspec)![1], appVersion);
    });
  });

  group('shipped texts', () {
    test('each licence in the app is the file it was copied from', () {
      const sources = {
        'assets/licenses/LICENSE-run-my-ai': 'LICENSE',
        'assets/licenses/LICENSE-tokenwing': '../llama.cpp/LICENSE',
        'assets/licenses/LICENSE-ik_llama.cpp': '../llama.cpp/licenses/LICENSE-ik_llama.cpp',
      };
      expect([for (final (_, asset) in bundledLicenses) asset], sources.keys);
      for (final MapEntry(key: asset, value: source) in sources.entries) {
        if (!File(source).existsSync()) continue;
        expect(File(asset).readAsStringSync(), File(source).readAsStringSync(), reason: '$asset differs from $source');
      }
    }, skip: File('../llama.cpp/LICENSE').existsSync() ? null : 'the engine is not next to the app');

    test('every project the engine thanks is named on the page', () {
      final readme = File('../llama.cpp/README.md').readAsStringSync();
      final thanks = readme.substring(readme.indexOf('## Thanks'), readme.indexOf('## License'));
      for (final name in [...thanksProjects, ...thanksPeople]) {
        expect(thanks, contains(name), reason: '$name is not in the engine\'s Thanks section');
      }
      for (final name in RegExp(r'\[([^\]]+)\]\(https://(?:github\.com|arxiv\.org)[^)]*\)').allMatches(thanks)) {
        final label = name[1]!;
        final named = [...thanksProjects, ...thanksPeople].any(label.contains);
        expect(named, isTrue, reason: '"$label" is in the engine\'s Thanks section but not on the page');
      }
    }, skip: File('../llama.cpp/README.md').existsSync() ? null : 'the engine is not next to the app');
  });

  group('author card', () {
    test('only web addresses are opened', () async {
      expect(await openUrl('file:///etc/passwd'), isFalse);
      expect(await openUrl('mailto:someone@example.com'), isFalse);
      expect(await openUrl('not a url'), isFalse);
    });

    test('the photo is a shipped asset and the links are the two profiles', () {
      expect(File('assets/author/author.png').existsSync(), isTrue);
      expect(File('pubspec.yaml').readAsStringSync(), contains('- assets/author/'));
      expect([for (final (name, _) in authorLinks) name], ['GitHub', 'LinkedIn']);
      expect(
        [for (final (_, url) in authorLinks) url],
        ['https://github.com/HarinManiK', 'https://www.linkedin.com/in/harinmani/'],
      );
    });
  });

  group('page', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('runmyai-about-');
      // An engine folder with no engine in it.
      File('${dir.path}/settings.json').writeAsStringSync('{"engineFolder": "${dir.path}/no-engine"}');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageProvider.overrideWithValue(Storage(dir)),
            backendProvider.overrideWithValue(DummyBackend()),
            shownModelProvider.overrideWithValue(null),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: const Scaffold(body: SettingsPage()),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('about-link')));
      // The licence texts are read from the app's files.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('Settings opens it, it shows versions, credits and licences, and Back returns', (tester) async {
      LicenseRegistry.addLicense(
        () => Stream.value(LicenseEntryWithLineBreaks(['a_test_package'], 'A test licence text.')),
      );
      await open(tester);
      expect(find.byKey(const Key('about-page')), findsOneWidget);
      expect(find.byKey(const Key('about-author-photo')), findsOneWidget);
      expect(find.text('“$authorQuote”'), findsOneWidget);
      expect(find.text(authorBio), findsOneWidget);
      expect(find.byKey(const Key('about-link-GitHub')), findsOneWidget);
      expect(find.byKey(const Key('about-link-LinkedIn')), findsOneWidget);
      expect(find.text(grawnchName), findsOneWidget);
      expect(find.text('“$grawnchQuote”'), findsOneWidget);
      expect(find.byKey(const Key('about-link-Hugging Face')), findsOneWidget);
      expect(tester.widget<SelectableText>(find.byKey(const Key('about-app-version'))).data, appVersion);
      expect(
        tester.widget<SelectableText>(find.byKey(const Key('about-engine-version'))).data,
        'unknown',
        reason: 'no engine in the folder, none running',
      );
      expect(find.text(authorName), findsOneWidget);
      expect(find.textContaining('are made by Harin Mani Karri'), findsOneWidget);
      expect(find.textContaining('llama.cpp'), findsWidgets);

      expect(find.textContaining('Permission is hereby granted'), findsNothing, reason: 'a licence opens when chosen');
      await tester.tap(find.byKey(Key('licence-${bundledLicenses[1].$1}')));
      await tester.pump();
      expect(find.textContaining('The ggml authors', findRichText: true), findsOneWidget);
      expect(find.textContaining('Harin Mani Karri', findRichText: true), findsWidgets);

      expect(find.byKey(const Key('licence-a_test_package')), findsNothing, reason: 'the packages\' licences start closed');
      await tester.tap(find.byKey(const Key('fold-Flutter and its packages')));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('licence-a_test_package')));
      await tester.pump();
      expect(find.text('A test licence text.', findRichText: true), findsOneWidget);

      // The thanks sentence leaves out the user name of the co-founder, who has his own card.
      final thanks = find.textContaining('whose designs and code it started from');
      expect(tester.widget<Text>(thanks).data, isNot(contains('grawnchtoader')));
      expect(tester.widget<Text>(thanks).data, contains('freedomljc, leloch and hikarioyama'));

      await tester.tap(find.byKey(const Key('about-back')));
      await tester.pump();
      expect(find.byKey(const Key('about-page')), findsNothing);
      expect(find.byKey(const Key('about-link')), findsOneWidget);
    });

    testWidgets('Settings calls the link Credits with no description; the page keeps its title', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageProvider.overrideWithValue(Storage(dir)),
            backendProvider.overrideWithValue(DummyBackend()),
            shownModelProvider.overrideWithValue(null),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: const Scaffold(body: SettingsPage()),
          ),
        ),
      );
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pump();
      expect(find.text('Credits'), findsOneWidget);
      expect(find.text('About'), findsNothing);
      expect(find.text('Versions, credits and licences.'), findsNothing);
      expect(find.byTooltip('Versions, credits and licences.'), findsNothing);
      expect(find.ancestor(of: find.text('Credits'), matching: find.byType(Tooltip)), findsNothing);
      expect(find.text('About Run My AI'), findsOneWidget);
      await tester.tap(find.byKey(const Key('about-link')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(find.text('About'), findsOneWidget, reason: 'the page\'s title');
    });

    testWidgets('Model credits start closed and name each model\'s maker, quantized file and licence', (tester) async {
      await open(tester);
      expect(find.byKey(const Key('model-credit-Ling 3.0 Flash')), findsNothing);
      await tester.tap(find.byKey(const Key('fold-Model credits')));
      await tester.pump();
      for (final m in modelCredits) {
        expect(find.byKey(Key('model-credit-${m.model}')), findsOneWidget);
        expect(find.text('Made by ${m.maker}. Quantized file by ${m.quant}. Licence: ${m.licence}.'), findsOneWidget);
      }
      expect([for (final m in modelCredits) m.model], ['Ling 3.0 Flash', 'Flint 40B', 'Qwen3.8 Flash Next']);
    });
  });
}
