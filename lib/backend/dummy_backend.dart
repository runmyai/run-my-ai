import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import 'backend.dart';

/// A stand-in until the real catalog and the engine are plugged in. Nothing is downloaded and no model runs.
class DummyBackend implements Backend {
  DummyBackend({
    this.downloadTime = const Duration(seconds: 10),
    double tokensPerSecond = 20,
    this.fixedReply,
    Random? random,
  })  : speed = ValueNotifier(tokensPerSecond),
        _random = random ?? Random();

  final Duration downloadTime;

  /// How fast replies are written, in tokens a second (a token is a short word or a piece of a longer one). The
  /// test speed control changes it, also while a reply is being written.
  final ValueNotifier<double> speed;

  /// Always this reply instead of a random one, except for a story (the tests use it, to know what to expect).
  final String? fixedReply;
  final Random _random;
  int? _lastPick;

  static const _gb = 1000 * 1000 * 1000;

  // Real model names; descriptions and the Qwen file sizes are placeholders.
  static const catalog = [
    CatalogModel(
      id: 'qwen3.8-flash-next',
      name: 'Qwen3.8 Flash Next',
      lab: 'Qwen',
      description: 'Everyday chat and long documents. (Placeholder text.)',
      parameters: '125B',
      activeParameters: '6B',
      files: [
        ModelFile(id: 'qwen3.8-flash-next/ISTA-IQ3_S', quantization: 'ISTA IQ3_S', sizeBytes: 55 * _gb),
        ModelFile(id: 'qwen3.8-flash-next/UD-Q4_K_XL', quantization: 'UD-Q4_K_XL', sizeBytes: 72 * _gb),
      ],
    ),
    CatalogModel(
      id: 'flint-40b',
      name: 'Flint 40B',
      lab: 'Recursive',
      description: 'Coding. (Placeholder text.)',
      parameters: '40B',
      activeParameters: '2.5B',
      files: [
        ModelFile(id: 'flint-40b/UD-Q4_K_XL', quantization: 'UD-Q4_K_XL', sizeBytes: 24 * _gb),
      ],
    ),
    // A model to pick that is plainly the stand-in.
    CatalogModel(
      id: 'dummy',
      name: 'Dummy model',
      lab: 'Run My AI',
      description: 'A stand-in for trying the app; it answers with sample replies. (Temporary.)',
      parameters: '0B',
      activeParameters: '0B',
      files: [
        ModelFile(id: 'dummy/test', quantization: 'Test', sizeBytes: 1 * _gb),
      ],
    ),
  ];

  /// How long each of [n] tokens takes, in tokens at the set speed (1 = the average): most within about 15 % of
  /// it, and about 1 in 50 two to three and a half times as long (a real model waits now and then, ours on the SSD).
  /// They average 1, so the set speed is the average speed.
  static List<double> tokenCosts(int n, Random random) => [
        for (var i = 0; i < n; i++)
          if (random.nextDouble() < 0.02)
            2 + 1.5 * random.nextDouble()
          else
            // 0.98 * 0.9643 + 0.02 * 2.75 = 1.
            0.9643 * exp(0.15 * _gaussian(random) - 0.15 * 0.15 / 2),
      ];

  static double _gaussian(Random random) =>
      sqrt(-2 * log(1 - random.nextDouble())) * cos(2 * pi * random.nextDouble());

  /// The reply the tests ask for with [fixedReply].
  static const replyText = 'This is a test reply from Run My AI. The real model is not connected yet, so every '
      'message gets this same answer. When the engine is plugged in, the model you picked will answer here.';

  /// Stand-in replies, one picked at random for each message (never the same one twice in a row).
  /// {asked} becomes the start of the user's message.
  static const replies = [
    'Good question. Here is a short answer: it depends on what you want to get out of it, but most people start small '
        'and build up from there.',
    'You asked about "{asked}". Let me break that down into three parts:\n\n'
        '1. What it is and why it matters.\n2. How people usually go about it.\n3. The mistakes that are easy to avoid.\n\n'
        'Tell me which part you want to go deeper on.',
    'Sure! Happy to help with that.',
    'I see what you mean. Before I answer, can you tell me a bit more? For example, is this for work, for study, or '
        'just out of curiosity?',
    'Here is one way to think about it. Imagine you have a big box of parts and a small table. You cannot put every '
        'part on the table at once, so you keep the ones you use most close by and fetch the rest when you need them. '
        'That simple idea shows up in a lot of places.',
    'Short version: yes.\n\nLonger version: yes, as long as you check the details first. Small things can change the '
        'answer, so it is worth a second look before you decide.',
    'Let me try a quick example in Python:\n\n'
        'def greet(name):\n    return f"Hello, {name}!"\n\nprint(greet("world"))\n\n'
        'This prints "Hello, world!". Change the name to try it with anything else.',
    'That is a fun one. "{asked}" sounds simple, but there is more to it than it first seems. People have been '
        'arguing about questions like this for a long time.',
    'Here are a few ideas:\n\n- Write down what you already know.\n- Pick the one thing that matters most.\n'
        '- Try it for a week and see what changes.\n- Keep what works, drop what does not.',
    'I am not sure I fully understood. Did you mean "{asked}" in general, or in one specific case?',
    'Thanks for asking. The honest answer is that there is no single right way. What works best usually depends on '
        'your time, your budget and what you enjoy doing.',
    'Absolutely. Step by step:\n\n'
        'First, get everything ready before you start.\nSecond, do the hard part while you are fresh.\n'
        'Third, check the result and fix anything that looks off.\n\nThat is really all there is to it.',
    'Great, let us go with that.',
    'Interesting! A lot of people ask about "{asked}". The most common answer is to begin with the basics, then '
        'move on once those feel easy. Rushing ahead tends to make things harder later.',
    'Here is a small table to compare the options:\n\n'
        'Option A: quick to start, harder to grow.\nOption B: slower to start, easier to grow.\n'
        'Option C: somewhere in the middle.\n\nIf you are unsure, B is usually the safe choice.',
    'Hmm, let me think about that for a second.\n\nOkay. I would say the main thing is to stay consistent. Doing a '
        'little every day beats doing a lot once in a while.',
    'Good point. I had not looked at it that way. You are right that it changes the picture a bit.',
    'Here is a summary of what we talked about so far:\n\n- You asked about "{asked}".\n- I gave you a few options.\n'
        '- The next step is to pick one and try it.\n\nWant me to help you plan that?',
    'That is a big topic! I will keep it short for now, and you can ask for more on any part. In one sentence: it is '
        'about making the most of what you have, without wasting time on what you do not need.',
    'Sure, here is a quick recipe idea: pasta with garlic, olive oil and a pinch of chilli. Boil the pasta, warm the '
        'garlic gently in the oil, mix it all together and add some cheese on top. Ready in fifteen minutes.',
    'No problem. Just to confirm, you want me to "{asked}"? If so, I can start right away.',
    'Let me explain it with numbers. Say something takes 10 minutes and you do it 6 times a day. That is an hour a '
        'day, about 7 hours a week, and more than 360 hours a year. Small things add up fast.',
    'Yes, that works. One small tip: save your work often, so nothing gets lost if something goes wrong.',
    'Here is a short poem for you:\n\nThe screen glows soft, the night is long,\nthe words come out, a quiet song.\n'
        'One more line, one more try,\nand then the morning sun is high.',
    'I would be careful with that one. It might work, but there are a couple of things that could go wrong. Let me '
        'list them so you can decide for yourself.',
    'Of course! What would you like to talk about next?',
    'This is a placeholder reply from Run My AI. The real model is not connected yet, so the app picks one of a few '
        'dozen sample answers. When the engine is plugged in, the model you picked will answer here.',
    'Done! Let me know if you want any changes.',
    'Let me walk you through it slowly, because this is where most people get stuck. The first part looks easy, and '
        'it is, but the second part depends on getting the first one exactly right. So take your time there. Once that '
        'is in place, the rest usually falls into line without much trouble. If anything is unclear, ask me about that '
        'part and I will explain it in a different way.',
    'Quick answer: around 20 minutes, give or take.',
  ];

  @override
  Future<List<CatalogModel>> loadCatalog() async => catalog;

  @override
  Stream<double> download(ModelFile file) async* {
    const steps = 100;
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(downloadTime ~/ steps);
      yield i / steps;
    }
  }

  @override
  Future<void> deleteDownload(ModelFile file) async {}

  /// The fixed story (assets/dummy/story.txt, about 5000 words) for any message with the word "story" in it.
  static Future<String> story() => rootBundle.loadString('assets/dummy/story.txt');

  @override
  Stream<String> reply({required String chatId, required ModelFile model, required List<ChatMessage> messages}) async* {
    final asked = messages.lastWhere((m) => m.role == Role.user, orElse: () => const ChatMessage(Role.user, '')).text;
    final text = _asksForStory(asked) ? (await story()).trim() : fixedReply ?? commonReply(asked) ?? _pick(messages);
    final tokens = splitTokens(text);
    // Like a real model: each token takes its own time around the set speed (a few much longer), and some reach
    // the app two at a time. The work done so far is counted in tokens at the set speed, so a change of the speed
    // control shows at once.
    final costs = tokenCosts(tokens.length, _random);
    final clock = Stopwatch()..start();
    var last = Duration.zero;
    var done = 0.0;
    var sent = 0;
    var waiting = '';
    while (sent < tokens.length) {
      // Until the next token is done (checked at least every 50 ms, so a speed change is picked up).
      final wait = ((costs[sent] - done) / speed.value).clamp(0.004, 0.05);
      await Future<void>.delayed(Duration(microseconds: (wait * 1e6).round()));
      final now = clock.elapsed;
      done += (now - last).inMicroseconds / 1e6 * speed.value;
      last = now;
      while (sent < tokens.length && done >= costs[sent]) {
        done -= costs[sent];
        waiting += tokens[sent++];
      }
      if (waiting.isEmpty) continue;
      // Sometimes it reaches the app together with the next one.
      if (sent < tokens.length && _random.nextDouble() < 0.15) continue;
      yield waiting;
      waiting = '';
    }
    if (waiting.isNotEmpty) yield waiting;
  }

  /// The same reply every time for a few everyday messages, of three lengths (a sentence or two, a few sentences,
  /// a few paragraphs): the whole message must match, capitals and punctuation aside. Null for any other message.
  static String? commonReply(String asked) {
    final key = asked.toLowerCase().replaceAll(RegExp(r"[^a-z0-9 ]"), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return _common[key];
  }

  static const _hi = 'Hi! How can I help you today?';
  static const _coffee = 'A good cup comes down to a few simple things: fresh beans, the right grind, the right amount, '
      "and water that's hot but not boiling.\n\n"
      '1. Use freshly roasted beans and grind them just before brewing, medium for a filter, fine for espresso.\n'
      '2. Use about 1 gram of coffee for every 16 grams of water, roughly two tablespoons per cup.\n'
      "3. Heat the water to just off the boil, around 92–96 °C. Boiling water can make it bitter.\n"
      '4. Let it brew for 3–4 minutes in a filter or French press, then pour it straight away.\n\n'
      'If it tastes bitter, try a coarser grind or a shorter brew; if it tastes sour or weak, go finer or use a little '
      'more coffee. Small changes make a big difference, so adjust one thing at a time until it tastes right to you.';
  static const _prime = "Here's a simple and fast way to do it:\n\n"
      'def is_prime(n):\n'
      '    if n < 2:\n'
      '        return False\n'
      '    if n % 2 == 0:\n'
      '        return n == 2\n'
      '    d = 3\n'
      '    while d * d <= n:\n'
      '        if n % d == 0:\n'
      '            return False\n'
      '        d += 2\n'
      '    return True\n\n'
      'It first rules out numbers below 2 and even numbers, then only checks odd divisors up to the square root of the '
      'number. Any larger factor would have a smaller partner that was already checked.\n\n'
      'For example, is_prime(29) returns True and is_prime(21) returns False, because 21 is 3 × 7.';
  static const _common = {
    'hi': _hi,
    'hello': _hi,
    'hey': _hi,
    'how are you': "I'm doing well, thanks for asking. What can I do for you today?",
    'fun fact': 'Octopuses have three hearts. Two of them pump blood through the gills, and the third pumps it to the '
        'rest of the body. Their blood is also blue, because it carries oxygen with copper instead of iron. And when '
        'an octopus swims, the main heart actually stops beating, which is one reason they prefer crawling.',
    'what is ai': 'AI, or artificial intelligence, is software that learns patterns from large amounts of examples '
        'instead of following only hand-written rules. A model like me was trained on lots of text, so I can '
        "understand questions and write answers in plain language. I don't think or feel like a person; I predict what "
        'a helpful reply looks like, one piece at a time. And in this app, all of that runs on your own computer.',
    'how do i make a good cup of coffee': _coffee,
    'coffee': _coffee,
    'write a python function to check if a number is prime': _prime,
    'prime code': _prime,
  };

  static bool _asksForStory(String text) => RegExp(r'\bstory\b', caseSensitive: false).hasMatch(text);

  /// [text] in pieces the size of a model's tokens: a short word with the space before it, or a piece of up to
  /// five letters of a longer word, or one other character.
  @visibleForTesting
  static List<String> splitTokens(String text) =>
      [for (final m in RegExp(r'\s*(?:[A-Za-z]{1,5}|[0-9]{1,3}|[^\sA-Za-z0-9])|\s+$').allMatches(text)) m[0]!];

  String _pick(List<ChatMessage> messages) {
    var i = _random.nextInt(replies.length);
    if (i == _lastPick) i = (i + 1) % replies.length;
    _lastPick = i;
    // The first few words of what the user wrote, for the replies that refer to it.
    final asked = messages.lastWhere((m) => m.role == Role.user, orElse: () => const ChatMessage(Role.user, '')).text;
    final words = asked.replaceAll(RegExp(r'\s+'), ' ').trim().split(' ');
    var quote = words.take(6).join(' ');
    if (words.length > 6) quote = '$quote…';
    quote = quote.replaceAll(RegExp(r'[?.!]+$'), '');
    return replies[i].replaceAll('{asked}', quote.isEmpty ? 'this' : quote);
  }
}
