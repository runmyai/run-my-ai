import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/backend.dart';
import '../data/models.dart';
import '../engine/commands.dart';
import 'providers.dart';

/// The profile that comes with each model. It cannot be changed; its commands can be copied.
const autoProfileId = 'auto';

/// A way to run a model: one command per context length, and a memory cap.
class EngineProfile {
  const EngineProfile({required this.id, required this.name, required this.commands, this.memoryCapGiB});

  final String id;
  final String name;
  final List<String> commands;

  /// The memory cap; null: all the RAM but 1 GB.
  final double? memoryCapGiB;

  bool get isAuto => id == autoProfileId;

  /// The context lengths it has commands for, smallest first.
  List<int> get lengths => [for (final c in commands) ?contextOf(c)]..sort();

  EngineProfile copyWith({String? name, List<String>? commands, double? Function()? memoryCapGiB}) => EngineProfile(
    id: id,
    name: name ?? this.name,
    commands: commands ?? this.commands,
    memoryCapGiB: memoryCapGiB != null ? memoryCapGiB() : this.memoryCapGiB,
  );

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'commands': commands, 'memoryCapGiB': memoryCapGiB};

  factory EngineProfile.fromJson(Map<String, Object?> json) => EngineProfile(
    id: json['id']! as String,
    name: json['name']! as String,
    commands: (json['commands']! as List).cast<String>(),
    memoryCapGiB: (json['memoryCapGiB'] as num?)?.toDouble(),
  );
}

/// The user's profiles of one model, and which profile is in use.
class ModelProfiles {
  const ModelProfiles({this.active = autoProfileId, this.custom = const []});

  final String active;
  final List<EngineProfile> custom;
}

/// Each model's profiles, by model file. Saved to profiles.json on every change.
class ProfilesNotifier extends Notifier<Map<String, ModelProfiles>> {
  @override
  Map<String, ModelProfiles> build() {
    final saved = ref.read(storageProvider).readProfiles();
    return {
      for (final MapEntry(key: fileId, value: json) in saved.entries)
        if (json is Map)
          fileId: ModelProfiles(
            active: json['active'] as String? ?? autoProfileId,
            custom: [
              for (final p in json['custom'] as List? ?? const [])
                EngineProfile.fromJson((p as Map).cast<String, Object?>()),
            ],
          ),
    };
  }

  EngineProfile auto(ModelFile file) {
    final backend = ref.read(backendProvider);
    final commands = backend.autoCommands(file);
    return EngineProfile(
      id: autoProfileId,
      name: 'Auto',
      commands: [
        for (final length in contextOptions(backend.maxContext(file)))
          if (commands[length] ?? _sameLabel(commands, length) case final command?) withContextLength(command, length),
      ],
    );
  }

  /// The command of the length that shows as [length] does: the model's longest stands in for the nearest standard one.
  static String? _sameLabel(Map<int, String> commands, int length) {
    final label = contextLabel(length);
    return commands.entries.where((e) => contextLabel(e.key) == label).firstOrNull?.value;
  }

  /// Auto first, then the user's own.
  List<EngineProfile> all(ModelFile file) => [auto(file), ...?state[file.id]?.custom];

  /// The profile in use for this model.
  EngineProfile active(ModelFile file) {
    final id = state[file.id]?.active;
    return all(file).where((p) => p.id == id).firstOrNull ?? auto(file);
  }

  /// How to run [file] at [contextLength] with the profile in use; the closest length it has if it lacks that one.
  EngineRun runFor(ModelFile file, int contextLength) {
    final profile = active(file);
    final length = closestContext(profile.lengths, contextLength);
    final command = profile.commands.firstWhere((c) => contextOf(c) == length);
    return EngineRun(flags: command, contextLength: length, memoryCapGiB: profile.memoryCapGiB);
  }

  /// How to run [file] at [contextLength] with the profile [id].
  EngineRun runWith(ModelFile file, String id, int contextLength) {
    final profile = all(file).where((p) => p.id == id).firstOrNull ?? auto(file);
    final length = closestContext(profile.lengths, contextLength);
    return EngineRun(
      flags: profile.commands.firstWhere((c) => contextOf(c) == length),
      contextLength: length,
      memoryCapGiB: profile.memoryCapGiB,
    );
  }

  void setActive(ModelFile file, String id) => _put(file, active: id);

  /// A new profile with a full copy of Auto's commands; it comes into use.
  void create(ModelFile file) {
    final mine = state[file.id]?.custom ?? const [];
    var n = mine.length + 1;
    while (mine.any((p) => p.name == 'Profile $n')) {
      n++;
    }
    final profile = EngineProfile(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      name: 'Profile $n',
      commands: auto(file).commands,
    );
    _put(file, active: profile.id, custom: [...mine, profile]);
  }

  void delete(ModelFile file, String id) {
    final models = state[file.id];
    if (models == null) return;
    _put(
      file,
      active: models.active == id ? autoProfileId : models.active,
      custom: [for (final p in models.custom) if (p.id != id) p],
    );
  }

  void update(ModelFile file, EngineProfile profile) {
    final models = state[file.id];
    if (models == null) return;
    _put(file, custom: [for (final p in models.custom) p.id == profile.id ? profile : p]);
  }

  void _put(ModelFile file, {String? active, List<EngineProfile>? custom}) {
    final models = state[file.id] ?? const ModelProfiles();
    state = {
      ...state,
      file.id: ModelProfiles(active: active ?? models.active, custom: custom ?? models.custom),
    };
    ref.read(storageProvider).writeProfiles({
      for (final MapEntry(key: id, value: m) in state.entries)
        id: {
          'active': m.active,
          'custom': [for (final p in m.custom) p.toJson()],
        },
    });
  }
}

final profilesProvider = NotifierProvider<ProfilesNotifier, Map<String, ModelProfiles>>(ProfilesNotifier.new);

/// [wanted] if it is among [options] (smallest first); else the largest below it; else the smallest.
int closestContext(List<int> options, int wanted) =>
    options.lastWhere((n) => n <= wanted, orElse: () => options.first);
