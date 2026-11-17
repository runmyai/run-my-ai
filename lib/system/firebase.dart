import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

// The app's feedback and shared benchmark results go to Cloud Firestore through its REST API (Firebase's own library
// does not run on desktop Linux). The database's rules accept only new documents of fixed shapes, so the app can create
// a document and never read, change or delete one.

const firebaseProject = 'run-my-ai-5876c';

/// The project's web API key: a public name for the project (every website using Firebase carries one), not a secret.
const firebaseApiKey = 'AIzaSyDN01Y9bvnKceKI0wbmnsexVyOdC5M1JBU';

/// Sends [body] (JSON) to [url] with POST; returns the status code and the answer's text.
typedef HttpPost = Future<(int, String)> Function(Uri url, String body);

/// A Dart value as one of Firestore's typed values. A number that is not finite has no JSON form: it becomes null.
Map<String, Object?> firestoreValue(Object? value) => switch (value) {
  null => {'nullValue': null},
  bool b => {'booleanValue': b},
  int i => {'integerValue': '$i'},
  double d => d.isFinite ? {'doubleValue': d} : {'nullValue': null},
  String s => {'stringValue': s},
  Map m => {'mapValue': {'fields': firestoreFields(m.cast<String, Object?>())}},
  Iterable l => {'arrayValue': {'values': [for (final v in l) firestoreValue(v)]}},
  _ => throw ArgumentError('Firestore cannot hold a ${value.runtimeType}'),
};

Map<String, Object?> firestoreFields(Map<String, Object?> fields) => {
  for (final e in fields.entries) e.key: firestoreValue(e.value),
};

/// Creates documents in the project's database.
class Firestore {
  Firestore({HttpPost? post, Random? random}) : _post = post ?? _httpPost, _random = random ?? Random.secure();

  final HttpPost _post;
  final Random _random;

  static const _documents = 'projects/$firebaseProject/databases/(default)/documents';
  static final commitUrl = Uri.parse('https://firestore.googleapis.com/v1/$_documents:commit?key=$firebaseApiKey');

  /// The request that creates a document [id] in [collection] with [fields] and a `createdAt` of the server's time
  /// (the rules ask for exactly that time), only if no such document exists yet.
  static Map<String, Object?> createRequest(String collection, String id, Map<String, Object?> fields) => {
    'writes': [
      {
        'update': {'name': '$_documents/$collection/$id', 'fields': firestoreFields(fields)},
        'updateTransforms': [
          {'fieldPath': 'createdAt', 'setToServerValue': 'REQUEST_TIME'},
        ],
        'currentDocument': {'exists': false},
      },
    ],
  };

  /// Creates a document in [collection] under a new random name; returns that name. Throws [FirestoreFailure] when the
  /// database refuses it or cannot be reached.
  Future<String> create(String collection, Map<String, Object?> fields) async {
    const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final id = String.fromCharCodes([for (var i = 0; i < 20; i++) letters.codeUnitAt(_random.nextInt(letters.length))]);
    final (int, String) answer;
    try {
      answer = await _post(commitUrl, jsonEncode(createRequest(collection, id, fields)));
    } on Exception catch (e) {
      throw FirestoreFailure('$e');
    }
    if (answer.$1 != 200) throw FirestoreFailure('HTTP ${answer.$1}: ${answer.$2}');
    return '$collection/$id';
  }

  static Future<(int, String)> _httpPost(Uri url, String body) async {
    // Tests never reach the real database: they give their own post.
    if (Platform.environment.containsKey('FLUTTER_TEST')) throw const FirestoreFailure('no network in tests');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(url);
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(body));
      final response = await request.close().timeout(const Duration(seconds: 30));
      return (response.statusCode, await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 30)));
    } finally {
      client.close(force: true);
    }
  }
}

class FirestoreFailure implements Exception {
  const FirestoreFailure(this.message);

  final String message;

  @override
  String toString() => 'Firestore: $message';
}

/// The database (the tests give their own).
final firestoreProvider = Provider<Firestore>((ref) => Firestore());
