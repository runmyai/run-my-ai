import 'package:flutter/material.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cmake.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/latex.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/powershell.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/r.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scala.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';

import '../../theme.dart';
import 'md_parse.dart';

/// How a reply's markdown is drawn: the reply's own text style, and the rest made from it and the theme's colours.
class MdLook {
  MdLook(this.base, this.colors);

  /// The reply's text style, complete (merged with the surrounding default style).
  final TextStyle base;
  final AppColors colors;

  double get fontSize => base.fontSize ?? 14;

  /// The space between blocks: one line, as a blank line between paragraphs was before replies were formatted.
  double get gap => fontSize * (base.height ?? 1.2);

  static const _mono = [
    'DejaVu Sans Mono',
    'Liberation Mono',
    'Noto Sans Mono',
    'Cascadia Mono',
    'Consolas',
    'Menlo',
    'Courier New',
    'Noto Color Emoji',
    'Segoe UI Emoji',
  ];

  /// Code: monospace, a little smaller.
  late final TextStyle code = base.copyWith(
    fontFamily: 'monospace',
    fontFamilyFallback: _mono,
    fontSize: fontSize * 0.9,
    height: 1.5,
  );

  /// The faint fill under code inside a line of text.
  late final Color inlineCodeFill = Color.alphaBlend(colors.text.withValues(alpha: 0.08), colors.page);

  TextStyle heading(int level) => base.copyWith(
    fontSize:
        fontSize *
        switch (level) {
          1 => 1.5,
          2 => 1.3,
          3 => 1.15,
          _ => 1.0,
        },
    fontWeight: FontWeight.w700,
    height: 1.35,
  );

  /// The text inside a quote: quieter.
  MdLook get quoted => MdLook(base.copyWith(color: colors.textSecondary), colors);

  late final Color codeFill = colors.inputFill;
  late final Color codeBorder = colors.border;

  /// Syntax colours for code blocks, by highlight.js scope (the part before the first dot), for the light and the
  /// dark themes (the app's themes are greys only; these hues are read easily on their code fills).
  late final Map<String, TextStyle> syntax = _syntax(colors.isLight);

  /// [of] with a run's [bits] (bold, italic, struck, code) added.
  TextStyle styleFor(int bits, TextStyle of) {
    var s = of;
    if (bits & MdRun.code != 0) {
      s = s.copyWith(
        fontFamily: 'monospace',
        fontFamilyFallback: _mono,
        fontSize: (of.fontSize ?? fontSize) * 0.9,
        backgroundColor: inlineCodeFill,
      );
    }
    if (bits & MdRun.bold != 0) s = s.copyWith(fontWeight: FontWeight.w700);
    if (bits & MdRun.italic != 0) s = s.copyWith(fontStyle: FontStyle.italic);
    if (bits & MdRun.strike != 0) s = s.copyWith(decoration: TextDecoration.lineThrough, decorationColor: s.color);
    return s;
  }
}

Map<String, TextStyle> _syntax(bool light) {
  TextStyle c(int v, {bool italic = false}) => TextStyle(color: Color(v), fontStyle: italic ? FontStyle.italic : null);
  final keyword = c(light ? 0xFFCF222E : 0xFFFF7B72);
  final string = c(light ? 0xFF0A3069 : 0xFFA5D6FF);
  final number = c(light ? 0xFF0550AE : 0xFF79C0FF);
  final title = c(light ? 0xFF8250DF : 0xFFD2A8FF);
  final builtIn = c(light ? 0xFF953800 : 0xFFFFA657);
  final comment = c(light ? 0xFF6E7781 : 0xFF8B949E, italic: true);
  final tag = c(light ? 0xFF116329 : 0xFF7EE787);
  return {
    'keyword': keyword,
    'doctag': keyword,
    'meta-keyword': keyword,
    'template-tag': keyword,
    'type': builtIn,
    'built_in': builtIn,
    'symbol': builtIn,
    'title': title,
    'section': title,
    'attr': number,
    'attribute': number,
    'literal': number,
    'number': number,
    'variable': number,
    'meta': number,
    'property': number,
    'selector-attr': number,
    'selector-class': number,
    'selector-id': number,
    'string': string,
    'regexp': string,
    'meta-string': string,
    'char': string,
    'comment': comment,
    'quote': comment,
    'name': tag,
    'tag': tag,
    'selector-tag': tag,
    'selector-pseudo': tag,
    'bullet': builtIn,
    'addition': tag,
    'deletion': keyword,
  };
}

final _highlight = Highlight()
  ..registerLanguages({
    'bash': langBash,
    'c': langC,
    'cmake': langCmake,
    'cpp': langCpp,
    'csharp': langCsharp,
    'css': langCss,
    'dart': langDart,
    'diff': langDiff,
    'dockerfile': langDockerfile,
    'go': langGo,
    'ini': langIni,
    'java': langJava,
    'javascript': langJavascript,
    'json': langJson,
    'kotlin': langKotlin,
    'latex': langLatex,
    'lua': langLua,
    'makefile': langMakefile,
    'markdown': langMarkdown,
    'php': langPhp,
    'powershell': langPowershell,
    'python': langPython,
    'r': langR,
    'ruby': langRuby,
    'rust': langRust,
    'scala': langScala,
    'shell': langShell,
    'sql': langSql,
    'swift': langSwift,
    'typescript': langTypescript,
    'xml': langXml,
    'yaml': langYaml,
  })
  ..registerAliases(['zsh', 'shellscript'], 'bash')
  ..registerAliases(['html', 'htm', 'svg'], 'xml')
  ..registerAliases(['jsonc', 'json5'], 'json');

/// [code] cut into pieces by syntax: where each starts, how long it is, and its highlight.js scope (null for plain
/// text). One plain piece for a language that is not known (or none given).
List<({int at, int length, String? scope})> highlightCode(String code, String language) {
  final plain = [(at: 0, length: code.length, scope: null)];
  if (language.isEmpty || code.isEmpty || _highlight.getLanguage(language) == null) return plain;
  try {
    final pieces = _Pieces();
    _highlight.highlight(code: code, language: language).render(pieces);
    // Should the highlighter not cover all of the code, the rest is plain.
    if (pieces.at < code.length) pieces.out.add((at: pieces.at, length: code.length - pieces.at, scope: null));
    return pieces.at > code.length ? plain : pieces.out;
  } on Object {
    return plain;
  }
}

class _Pieces implements HighlightRenderer {
  final out = <({int at, int length, String? scope})>[];
  final _scopes = <String?>[];
  int at = 0;

  @override
  void addText(String text) {
    out.add((at: at, length: text.length, scope: _scopes.isEmpty ? null : _scopes.last));
    at += text.length;
  }

  @override
  void openNode(DataNode node) => _scopes.add(node.scope ?? (_scopes.isEmpty ? null : _scopes.last));

  @override
  void closeNode(DataNode node) {
    if (_scopes.isNotEmpty) _scopes.removeLast();
  }
}
