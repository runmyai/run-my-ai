import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';

/// The part of the app that fills the main area.
enum Section {
  chat,
  code,
  store,
  settings;

  /// The section's own chats (Chat and Code); null for the others.
  ChatKind? get kind => switch (this) {
        Section.chat => ChatKind.chat,
        Section.code => ChatKind.code,
        _ => null,
      };

  static Section of(ChatKind kind) => switch (kind) {
        ChatKind.chat => Section.chat,
        ChatKind.code => Section.code,
      };
}

class SectionNotifier extends Notifier<Section> {
  SectionNotifier([this.initial = Section.chat]);

  final Section initial;

  @override
  Section build() => initial;

  void select(Section section) => state = section;
}

final sectionProvider = NotifierProvider<SectionNotifier, Section>(SectionNotifier.new);
