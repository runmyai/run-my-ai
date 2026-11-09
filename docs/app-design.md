# App design

Run My AI is a Flutter desktop app for Linux and Windows; a macOS runner exists in `macos/`. It is a chat window with a model store, a settings page and a sidebar of saved chats. It uses `flutter_riverpod` for state, `sqlite3` for chats and `window_manager` for the window. Build and run commands are in `building.md`. Paths below are relative to the app folder.

## 1. Layout of the code

| Path | What it holds |
|---|---|
| `lib/main.dart` | `main()` opens `Storage` and `ChatStore`, sets up the window and runs `appWith(...)`, which wraps `RunMyAiApp` in a `ProviderScope`. |
| `lib/theme.dart` | `AppColors` (the colour sets, a `ThemeExtension`), `DarkLook`, `buildTheme`. |
| `lib/backend/` | `Backend`, the interface to the side that has the models. |
| `lib/data/` | `models.dart` (plain data classes), `storage.dart` (small JSON files), `chat_db.dart` (SQLite), `chat_store.dart` (the database on a background isolate). |
| `lib/dev/` | `screenshot.dart`: developer screenshots, switched on by environment variables. |
| `lib/search/` | `chat_search.dart`: query parsing, matching and ranking for chat search. Pure Dart. |
| `lib/state/` | Riverpod notifiers with their state classes, mostly one per file (section 2). |
| `lib/system/` | `appearance.dart` (is the computer set to light) and `chime.dart` (the reply-finished sound and its FFI player). |
| `lib/ui/` | Widgets: `shell.dart` (the window), `sidebar.dart`, `chat_list.dart`, `shortcuts.dart`, `title_bar.dart`, `live_reply.dart`, `follow.dart` and smaller helpers. |
| `lib/ui/pages/` | One page per section: `chat_page.dart`, `store_page.dart`, `settings_page.dart`, and `simple_pages.dart` (the Code page). |
| `lib/window/` | `app_window.dart`: window set-up, saved size and place, window-state providers. |
| `native/` | `sound.c`, the sound player in C, and `third_party/` with miniaudio and stb_vorbis. |

`assets/` holds the logo, the app icon and the reply-finished sound. `linux/`, `windows/` and `macos/` are the Flutter runners.

## 2. State

`Storage`, `ChatStore` and `Backend` are plain objects exposed by `storageProvider`, `chatStoreProvider` and `backendProvider` in `lib/state/providers.dart`. They throw until `appWith` overrides them in the `ProviderScope`, so `main()` and every test choose their own. The notifiers below reach them with `ref.read`.

| Provider | Holds | Saved to |
|---|---|---|
| `chatsProvider` (`ChatsNotifier`, `ChatsState`) | The chat list (`ChatInfo`, no messages), pinned ids, the open chat with its messages, the id of the chat being replied to, the shown `ChatKind`. | `chats.db` |
| `sectionProvider` | The `Section`: chat, code, store or settings. Choosing chat or code switches `ChatsNotifier` to that kind's chats. | not saved |
| `libraryProvider`, `pickedModelProvider` | Downloaded file ids, downloads in progress, the picked file; the picked `CatalogEntry`. | `library.json` |
| `catalogProvider`, `catalogFilesProvider` | The catalog from `Backend.loadCatalog`, and its files by id. | not saved |
| `prefsProvider` | Theme, sidebar hidden, text size, bell, own sound. | `settings.json` |
| `draftsProvider` | Unsent text per chat and per section's new chat. | `drafts.json`, 500 ms after typing stops |
| `foldsProvider` | Folded groups of the chat list, per section. | `folds.json` |
| `searchProvider`, `searchResultsProvider`, `findProvider` | The search box; its results (searched on the chat store's worker, the newest search wins); the chat opened from a result, with its highlights. | not saved |
| `archiveViewProvider` | The sections whose sidebar shows Archived. | not saved |
| `motionProvider` | `Motion`: how a reply moves while it is written (`smoothMotion` or `rawMotion`). | not saved |
| `deleteGuardProvider` | `DeleteGuard`: when deleting a chat asks first. | not saved |
| `todayProvider` | Today's date, checked each minute, for the list headings. | not saved |
| `systemLightProvider` | Whether the computer is explicitly set to light. | not saved |
| `chimeProvider` | `Chime`, the reply-finished sound. | not saved |
| `windowMaximizedProvider`, `windowFocusedProvider`, `windowFullScreenProvider` | The window's state, from `window_manager` listeners. | not saved |

`ChatsNotifier` is the centre. It keeps messages in memory only for the open chat and the chat being replied to (`_replying`), writes every change to `ChatStore`, and remembers each section's open chat (`_openIn`). Providers follow each other with `ref.listen`: `ChatsNotifier` follows `sectionProvider`, `DraftsNotifier` the chat list (a deleted chat loses its draft), `FoldsNotifier` `findProvider`, `SearchResultsNotifier` the search box and the chats, `Chime` the bell.

## 3. Data

`Storage.open()` uses the folder from `path_provider`'s `getApplicationSupportDirectory()`, or the folder named by the environment variable `RUNMYAI_DATA_DIR`. All saved data is in that folder:

| File | Form | Content |
|---|---|---|
| `chats.db` | SQLite | Chats, messages and a word index. |
| `settings.json` | JSON | `theme`, `sidebarHidden`, `textScale`, `bell`, `soundName`, `soundFile`. |
| `drafts.json` | JSON map | Draft key (a chat id, or `new:chat` / `new:code`) to text. |
| `window.json` | JSON | `width`, `height`, `x`, `y`, `maximized`. |
| `library.json` | JSON | `downloaded` (file ids) and `picked`. |
| `folds.json` | JSON map | Section name to folded group keys (`pinned`, or a day as `YYYY-MM-DD`). |
| `sounds/custom.<ext>` | audio | The copy of the sound file the user chose. |

`Storage` writes each JSON file to a `.tmp` file and renames it, and reads a missing or unreadable file as the defaults. `theme` holds `system` or the picked style (`light`, `silklight`, `dusk`, `dark`, `dark2`, `dark3`).json` keeps only ids.

`ChatDb` creates three tables: `chats` (id, number, title, created, updated, pin, kind, sort, archived), `messages` (role, text, bookmark) and `messages_fts`, an FTS5 index that keeps no copy of the text. A message's row id is its chat's number shifted left 20 bits plus its place in the chat, so a chat's messages are one range of ids and an index hit names its chat and place. Schema changes are numbered upgrades on the database's `userVersion` in `_setUp`. Chats saved by older versions as `chats/<id>.json` plus `pins.json` are moved in when the database opens.

`ChatStore` runs `ChatDb` on its own isolate. Saves (`createChat`, `addMessage`, `rename`, `setPins` ...) are sent without waiting and run in order. `messages`, `search`, `fillLines`, `flush` and `close` wait for an answer. The classes in `models.dart` are `ChatInfo` (a list row), `Chat` (with messages), `ChatMessage` (role, text, bookmark), `ChatKind` (chat or code), `CatalogModel` and `ModelFile`.

## 4. The chat flow

1. `_MessageBox` in `lib/ui/pages/chat_page.dart` owns the text field. Each change goes to `DraftsNotifier.set` under `draftKey(openId, kind)`. Enter calls `_send`; Shift+Enter starts a new line.
2. `_send` does nothing when no model is picked (`pickedModelProvider` is null), a reply is being written, or the text is blank. Otherwise it clears the box and calls `ChatsNotifier.send(text, model.file)`.
3. `send` makes a `Chat` if none is open (id from the clock, title from the first line cut at 40 characters), calls `ChatStore.createChat` or `setUpdated`, and saves the user message with `ChatStore.addMessage`. It adds an empty assistant `ChatMessage` to the chat in memory and sets `replyingId`.
4. It calls `reply(chatId:, model:, messages:)` on `backendProvider`. That returns a `Stream<String>` of pieces. Each piece goes to `_appendToReply`, an error to `_finish()`, the end to `_finish(finished: true)`.
5. `_appendToReply` grows the last message of `_replying` and, if that chat is open, publishes it as `ChatsState.open`. `ChatPage` watches `open` and builds each message as `_Message` inside `_MessageWithActions`. The last assistant message is a `LiveReply` (`lib/ui/live_reply.dart`), which spreads the pieces evenly and paints them in behind a moving edge as `Motion` says. `ReplyFollower` (`lib/ui/follow.dart`) keeps the page at the end while the user is at the bottom.
6. `_finish` saves the assistant message with `ChatStore.addMessage`; it is not saved before, and a reply stopped before its first piece is dropped. A reply that ended by itself calls `Chime.replyDone`, which plays the sound 350 ms later if the bell is on. The Stop button and Esc call `ChatsNotifier.stop`, which cancels the subscription and calls `_finish()` with no sound.

Opening another chat does not stop the reply: `_replying` keeps it, and the message box of other chats shows a hint until it ends. One reply runs at a time.

## 5. Windows and platform code

- **Window.** `setUpWindow` (`lib/window/app_window.dart`) runs before `runApp`. It initialises `window_manager`, sets the minimum size (760 x 520), restores the saved size and place, and adds `_WindowSaver`, which writes `window.json` 500 ms after the window stops changing (while maximized it keeps the last normal size). A saved place is used only if the window's top row is still on a screen (`screen_retriever`), and never on Linux under Wayland.
- **No system title bar.** On Windows and macOS `setUpWindow` hides it with `setTitleBarStyle`; the macOS runner starts the window hidden and `setUpWindow` shows it. On Linux `linux/runner/my_application.cc` sets an empty GTK title bar (GTK keeps the shadow and resize edges), makes the window see-through on a composited screen and rounds it by 8 px.
- **The top row** is drawn by the app (`lib/ui/title_bar.dart`): `WindowDragArea` (drag, double-click to maximize, right-click for the window menu), `WindowButtons` (Windows and Linux), `WindowShape` and `WindowEdge` (the outline, and rounded corners on Linux), `TitleRowFade` (dimmed while the window is behind). `WindowLook` (mac, windows, linux) picks the style; `RUNMYAI_LOOK` previews another system's, and the mac look on another system gets Apple's buttons from `MacButtonsPreview`.
- **Computer theme.** `SystemLightNotifier` (`lib/system/appearance.dart`) reports whether the computer is explicitly set to light. On Linux it runs `gdbus` to read the freedesktop portal's `color-scheme` and falls back to Flutter's platform brightness; on Windows and macOS it uses Flutter's.
- **Native sound library.** `native/sound.c` is built as the shared library `runmyai_sound` by `linux/CMakeLists.txt` and `windows/CMakeLists.txt`. It exports `sound_check`, `sound_play`, `sound_playing` and `sound_stop`, plus `sound_check_w` and `sound_play_w` on Windows (UTF-16 paths). `SoundPlayer.load()` in `lib/system/chime.dart` opens it with `dart:ffi` from next to the executable: `runmyai_sound.dll` on Windows, `lib/librunmyai_sound.so` on Linux, `../Frameworks/librunmyai_sound.dylib` on macOS. If it cannot be opened, `load()` returns null and `Chime` plays nothing; `macos/` has no build rule for it. `Chime` plays the user's copy in `sounds/`, else the app's `reply-done.mp3` from `flutter_assets`, and polls `SoundPlayer.playing` every 250 ms to close the sound device. `Chime.choose` copies a file picked with `file_selector` into the data folder.
- **Platform folders and paths.** The data folder comes from `path_provider`. The sound library, the app's sound and the Linux window icon are found from `Platform.resolvedExecutable`. Shortcuts use Cmd on macOS and Ctrl elsewhere (`_cmd` in `lib/ui/shortcuts.dart`).

## 6. Tests

Run from the app folder. `flutter test` runs every file in `test/` and needs no device; `flutter test test/<file>.dart` runs one. Each file starts with a comment naming the code it covers.

| File | Covers |
|---|---|
| `chat_db_test.dart` | `ChatDb` on an in-memory database: search equals the in-memory search, old chat files moved in, sections, drag place, archive, bookmarks. |
| `chat_search_test.dart` | `SearchQuery` matching and ranking rules. |
| `chat_order_test.dart`, `today_test.dart` | `sortChats`; `dayLabel`. |
| `delete_guard_test.dart` | `DeleteGuard`. |
| `drafts_bell_test.dart` | `DraftsNotifier`, and the bell of `Chime`. |
| `sound_test.dart` | `Chime` and the sound settings, with a stand-in `SoundPlayer`. `native/sound.c` has no test. |
| `motion_test.dart`, `follow_test.dart` | The `Motion` presets; the `ReplyFollower` rules. |
| `folded_text_test.dart`, `cut_title_test.dart` | `FoldedText`; `CutTitle`. |
| `shortcuts_test.dart` | `listOrder` (the order Alt+Up / Alt+Down walk) and the text-size steps of `PrefsNotifier`. |

`integration_test/app_test.dart` has 12 `testWidgets` that click through the real app: Store, downloads, picker, sending, Stop and saving; search; the chat menu (rename, pin, drag, delete) and its keys; folding and archiving; Chat and Code separately; reply following; folded long messages; keyboard shortcuts; bookmarks, drafts and the bell. Each test builds the app with `appWith` on a temporary data folder, a test backend and a `CountingChime` in place of the sound. Run it with `flutter test integration_test/app_test.dart -d linux`. `--dart-define=SHOTS=<folder>` saves screenshots there with `saveScreenshot`.

## 7. Conventions

- Files are `snake_case.dart`. In `lib/state/` a notifier, its state class and its provider sit together, the provider right after the notifier: `final xProvider = NotifierProvider<XNotifier, X>(XNotifier.new);`.
- State classes are immutable (`const` constructors, `final` fields). Those with several fields have `copyWith` (`Prefs`, `ChatsState`); where a field can be set to null it takes a closure (`openId: () => null`).
- Notifiers write to disk through `Storage` or `ChatStore`. Services come from the three providers in `providers.dart`, so tests swap them (`overrideWith`, `overrideWithValue`).
- Widgets that read state are `ConsumerWidget` or `ConsumerStatefulWidget`, watch with `ref.watch(provider.select(...))`, and are private (`_Name`) unless another file needs them.
- Screens read colours from `context.colors` (`AppColors`: `page`, `text`, `textSecondary`, `border`, `selected` ...). The theme sets no accent colour. `DarkLook` (flat, silk, slashes) sets the decoration a theme adds.
- Widgets a test taps carry a `Key('...')` (`send`, `stop`, `store`, `bell`, `new-chat`, `theme-family`, `motion-smooth`).
- Classes and non-obvious fields carry a `///` comment in plain words about what they do.
- **A new setting:** add the field with a default to `PrefsData` in `lib/data/storage.dart` and to `readPrefs` / `writePrefs`; add it to `Prefs`, `copyWith`, `PrefsNotifier.build` and `_save` in `lib/state/prefs.dart`, with a notifier method; add the control to `lib/ui/pages/settings_page.dart` (`_Menu` and `_Choice` take an `id` that becomes the widget key); add a test.
- **A new screen:** add a value to `Section` in `lib/state/section.dart`, a page under `lib/ui/pages/`, and a case in the `switch` in `Shell.build` (it has no default, so the compiler finds a missing case); add a sidebar entry next to Store and Settings in `lib/ui/sidebar.dart`.
- **A new shortcut:** add the binding to the map in `_AppShortcutsState.build` (`lib/ui/shortcuts.dart`) and a row to `ShortcutsSheet._groups`.
- **A new backend call:** add it to `Backend`, implement it, and call it through `ref.read(backendProvider)`.
