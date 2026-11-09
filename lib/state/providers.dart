import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/backend.dart';
import '../data/chat_store.dart';
import '../data/models.dart';
import '../data/storage.dart';

/// Set in main() (and in tests) with ProviderScope overrides.
final storageProvider = Provider<Storage>((ref) => throw UnimplementedError('storageProvider not set'));
final backendProvider = Provider<Backend>((ref) => throw UnimplementedError('backendProvider not set'));
final chatStoreProvider = Provider<ChatStore>((ref) => throw UnimplementedError('chatStoreProvider not set'));

final catalogProvider = FutureProvider<List<CatalogModel>>((ref) => ref.read(backendProvider).loadCatalog());

/// A model file together with the model it belongs to.
typedef CatalogEntry = ({CatalogModel model, ModelFile file});

/// Every model file in the catalog by its id (empty while the catalog loads).
final catalogFilesProvider = Provider<Map<String, CatalogEntry>>((ref) {
  final catalog = ref.watch(catalogProvider).value ?? const [];
  return {
    for (final m in catalog)
      for (final f in m.files) f.id: (model: m, file: f),
  };
});
