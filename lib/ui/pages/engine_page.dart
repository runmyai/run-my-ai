import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/backend.dart';
import '../../benchmark/benchmark.dart';
import '../../benchmark/metrics.dart';
import '../../engine/commands.dart';
import '../../state/benchmark.dart';
import '../../state/chats.dart';
import '../../state/library.dart';
import '../../state/profiles.dart';
import '../../state/providers.dart';
import '../../theme.dart';
import '../benchmark/history_view.dart';
import '../benchmark/metric_cards.dart';
import '../benchmark/result_view.dart';
import '../buttons.dart';
import '../select_box.dart';

part 'benchmark_tab.dart';

/// The Benchmark page.
class EnginePage extends ConsumerWidget {
  const EnginePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final entry = ref.watch(shownModelProvider);
    final backend = ref.watch(backendProvider);
    final control = backend is EngineControl ? backend as EngineControl : null;

    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 28, 40, 40),
      children: [
        Text('Benchmark', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: c.text)),
        const SizedBox(height: 16),
        if (entry == null || control == null)
          Text('Get a model from the Store first.', style: TextStyle(fontSize: 14, color: c.textSecondary))
        else ...[
          const SizedBox(height: 16),
          _BenchmarkTab(entry: entry),
        ],
      ],
    );
  }
}

