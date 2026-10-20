/// A schema-agnostic reader for responses whose shape this project has not
/// established.
///
/// This exists for `ugsqs.whu.edu.cn` (teacher evaluation), which serves **no
/// credential-free assets at all**: every static path 404s because its JS is
/// inlined into protected pages, and the CAS multi-service ticket endpoint
/// 404s too. So unlike the course and timetable services, there is no way to
/// learn the response shape without actually reaching a logged-in session.
///
/// Two honest options existed: invent typed models and have the UI confidently
/// render a structure that does not exist, or build a reader that reports what
/// it finds. This is the second, and [AdaptiveDocument] deliberately carries no
/// semantics — it never claims a field means anything, it only presents it.
///
/// The failure direction is fixed: an HTML sign-in page must never be readable
/// as an empty-but-successful document.
library;

import 'dart:convert';

/// What kind of body arrived.
enum DocKind {
  /// A JSON object or array.
  json,

  /// An HTML document — most often the sign-in page this property redirects to
  /// when the session is absent or expired.
  html,

  /// Non-empty text that is neither JSON nor HTML.
  text,

  /// Nothing at all.
  empty,

  /// Claimed to be JSON but would not decode — a truncated or corrupt body.
  /// Distinct from [text] because it implies a *successful* request that went
  /// wrong mid-transfer.
  malformed,
}

/// The shape of a node in the parsed tree.
enum NodeKind { object, array, string, number, boolean, nullValue }

/// One value in the tree, tagged by its runtime shape rather than by any
/// assumed field meaning.
class AdaptiveNode {
  AdaptiveNode.json(this.path, {this.object, this.array})
      : kind = object != null
            ? NodeKind.object
            : (array != null ? NodeKind.array : NodeKind.nullValue),
        scalar = null;

  /// A scalar node. The two container fields stay final, so the initializer
  /// pins them to null explicitly — they are never populated for scalars.
  AdaptiveNode.scalar(this.path, this.scalar, this.kind)
      : object = null,
        array = null;

  /// Dotted path from the root, e.g. `results.0.title`. Arrays contribute a
  /// numeric segment.
  final String path;

  final NodeKind kind;
  final Map<String, AdaptiveNode>? object;
  final List<AdaptiveNode>? array;

  /// The literal value for scalar nodes, rendered as text. Null for
  /// containers.
  final String? scalar;

  bool get isContainer => kind == NodeKind.object || kind == NodeKind.array;

  /// Text for display. Containers describe themselves rather than stringifying
  /// their whole subtree into something unscannable.
  String get display {
    switch (kind) {
      case NodeKind.object:
        return '{${object?.length ?? 0}}';
      case NodeKind.array:
        return '[${array?.length ?? 0}]';
      case NodeKind.string:
        return scalar ?? '';
      case NodeKind.number:
      case NodeKind.boolean:
      case NodeKind.nullValue:
        return scalar ?? 'null';
    }
  }

  @override
  String toString() => 'AdaptiveNode($path: $display)';
}

/// A parsed body plus enough structure to browse it.
class AdaptiveDocument {
  AdaptiveDocument({
    required this.kind,
    required this.preview,
    this.root,
    this.htmlTitle,
  });

  final DocKind kind;
  final AdaptiveNode? root;

  /// First non-whitespace characters of the body, truncated. Safe to show.
  final String preview;

  /// `<title>` when [kind] is [DocKind.html].
  final String? htmlTitle;

  static const int _previewLimit = 200;

  /// True for anything this project can present as data.
  bool get hasData => kind == DocKind.json && root != null;

  /// Whether this looks like the origin returned its sign-in page instead of
  /// the requested data. This is the single most important read in the file:
  /// reporting it as an empty document would send a reviewer hunting a bug in
  /// code that is fine.
  bool get isSignInPage =>
      kind == DocKind.html &&
      (htmlTitle?.contains('登录') == true ||
          htmlTitle?.contains('统一身份') == true ||
          htmlTitle?.contains('认证') == true ||
          htmlTitle?.contains('sign') == true ||
          preview.toLowerCase().contains('authserver') ||
          preview.contains('登录') ||
          preview.contains('密码'));

  /// Empty, but for reasons worth distinguishing.
  bool get isVacuous =>
      kind == DocKind.empty ||
      (kind == DocKind.json &&
          (root?.kind == NodeKind.array
              ? (root?.array?.isEmpty ?? true)
              : false));

  static AdaptiveDocument parse(String body) {
    final trimmed = body.trimLeft();

    if (trimmed.isEmpty) {
      return AdaptiveDocument(kind: DocKind.empty, preview: '');
    }

    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        return AdaptiveDocument(
          kind: DocKind.json,
          preview: trimmed.substring(0,
              trimmed.length > _previewLimit ? _previewLimit : trimmed.length),
          root: _toNode('', decoded),
        );
      } on FormatException {
        return AdaptiveDocument(
          kind: DocKind.malformed,
          preview: trimmed.substring(0,
              trimmed.length > _previewLimit ? _previewLimit : trimmed.length),
        );
      }
    }

    if (trimmed.startsWith('<')) {
      return AdaptiveDocument(
        kind: DocKind.html,
        preview: trimmed.substring(
            0, trimmed.length > _previewLimit ? _previewLimit : trimmed.length),
        htmlTitle: _htmlTitle(trimmed),
      );
    }

    return AdaptiveDocument(
      kind: DocKind.text,
      preview: trimmed.substring(
          0, trimmed.length > _previewLimit ? _previewLimit : trimmed.length),
    );
  }

  static String? _htmlTitle(String html) {
    final lower = html.toLowerCase();
    final start = lower.indexOf('<title');
    if (start < 0) return null;
    final open = lower.indexOf('>', start);
    if (open < 0) return null;
    final close = lower.indexOf('</title>', open);
    if (close < 0) return null;
    final raw = html.substring(open + 1, close).trim();
    return raw.isEmpty ? null : raw;
  }

  static AdaptiveNode _toNode(String path, Object? value) {
    if (value is Map) {
      final entries = <String, AdaptiveNode>{};
      value.forEach((k, v) {
        final key = k.toString();
        entries[key] = _toNode(path.isEmpty ? key : '$path.$key', v as Object?);
      });
      return AdaptiveNode.json(path, object: entries);
    }
    if (value is List) {
      final items = <AdaptiveNode>[
        for (var i = 0; i < value.length; i++)
          _toNode(path.isEmpty ? '$i' : '$path.$i', value[i]),
      ];
      return AdaptiveNode.json(path, array: items);
    }
    if (value == null) {
      return AdaptiveNode.scalar(path, 'null', NodeKind.nullValue);
    }
    if (value is num) {
      return AdaptiveNode.scalar(path, '$value', NodeKind.number);
    }
    if (value is bool) {
      return AdaptiveNode.scalar(path, '$value', NodeKind.boolean);
    }
    return AdaptiveNode.scalar(path, '$value', NodeKind.string);
  }

  // -------------------------------------------------------------- queries

  /// Looks up a dotted path, e.g. `results.0.name`. Missing paths yield an
  /// empty list rather than throwing: an absent path is a normal answer here.
  List<AdaptiveNode> at(String path) {
    final r = root;
    if (r == null || path.isEmpty) return [if (r != null) r];

    var current = r;
    for (final segment in path.split('.')) {
      if (segment.isEmpty) continue;
      switch (current.kind) {
        case NodeKind.object:
          final next = current.object?[segment];
          if (next == null) return const [];
          current = next;
        case NodeKind.array:
          final index = int.tryParse(segment);
          if (index == null) return const [];
          final arr = current.array;
          if (arr == null || index < 0 || index >= arr.length) return const [];
          current = arr[index];
        default:
          return const [];
      }
    }
    return [current];
  }

  /// Finds every array of objects anywhere in the document whose entries share
  /// a stable key set — the shape that renders as a table.
  ///
  /// This is how a schema you do not know still becomes readable: instead of
  /// guessing which path holds the list, ask which lists *look* like records.
  List<TableCandidate> candidateTables({int minColumns = 2}) {
    final out = <TableCandidate>[];
    void walk(AdaptiveNode node) {
      final items = node.array;
      if (items != null && items.isNotEmpty) {
        final recordItems =
            items.where((n) => n.kind == NodeKind.object).toList();
        if (recordItems.length == items.length) {
          final keys = recordItems.first.object?.keys.toList() ?? const [];
          final uniform =
              recordItems.every((n) => n.object?.keys.length == keys.length);
          if (uniform && keys.length >= minColumns) {
            out.add(TableCandidate(
                path: node.path, columns: keys, rows: recordItems));
          }
        }
      }
      node.object?.values.forEach(walk);
      items?.forEach(walk);
    }

    final r = root;
    if (r != null) walk(r);
    return out;
  }

  /// A short human description of what arrived, for an empty-state or a log
  /// line. Contains no field semantics — it cannot, that is the whole point.
  String describe() => switch (kind) {
        DocKind.empty => 'empty response',
        DocKind.json => root == null
            ? 'json (unavailable)'
            : 'json ${root!.kind == NodeKind.array ? '${root!.array?.length} items' : '${root!.object?.length} fields'}',
        DocKind.html => 'html page${htmlTitle == null ? '' : ' — $htmlTitle'}',
        DocKind.text => 'plain text',
        DocKind.malformed => 'truncated or corrupt json',
      };
}

/// An array that would render as a table if anyone knew what its columns meant.
class TableCandidate {
  const TableCandidate({
    required this.path,
    required this.columns,
    required this.rows,
  });

  /// Dotted path to the array, `''` for the document root.
  final String path;
  final List<String> columns;
  final List<AdaptiveNode> rows;

  /// Rows rendered as display strings, one list per row, column-ordered to
  /// match [columns].
  List<List<String>> render() => [
        for (final row in rows)
          [
            for (final c in columns) row.object?[c]?.display ?? '',
          ],
      ];

  String get label => path.isEmpty ? 'root' : path;

  @override
  String toString() =>
      'TableCandidate($label: ${rows.length}×${columns.length})';
}
