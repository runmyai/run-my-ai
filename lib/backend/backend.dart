import '../data/models.dart';

/// Everything the app needs from the side that has the models.
///
/// Today this is [DummyBackend] (fake catalog, fake downloads, one fixed reply). Later it is the real
/// catalog, real downloads and the TokenWing engine (llama-server on localhost); the screens do not change.
abstract class Backend {
  Future<List<CatalogModel>> loadCatalog();

  /// Download progress from 0 to 1. Cancelling the subscription cancels the download.
  Stream<double> download(ModelFile file);

  Future<void> deleteDownload(ModelFile file);

  /// The reply to the last message, piece by piece. Cancelling the subscription stops it.
  Stream<String> reply({required String chatId, required ModelFile model, required List<ChatMessage> messages});
}
