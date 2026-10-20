/// 正方教务 (ZFWeb) — the university's own academic system.
///
/// This is the data source the grade and evaluation feature belongs to. The
/// third-party app backend also exposes a "grades" namespace, but its
/// `courses` / `reviews` / `offerings` datasets were all verified empty, so
/// building the feature there produces a permanently blank screen. 正方 is
/// where a student's own grades, and the teaching evaluation their school
/// publishes, actually live.
///
/// ## What the login story is
///
/// jwgl is not a token API. It is a server-rendered-into-SPA system behind the
/// university's central authentication: a CAS single sign-on issues a
/// ticket-granting cookie, `jwgl` redeems it into its own session, and from
/// then on the session cookie authorises ordinary page and XHR calls. The
/// WebView sign-in already implemented in `features/whu_auth` produces exactly
/// that session, so no credential handling is added here.
///
/// ## Why the menu has to be fetched rather than hardcoded
///
/// Every route under jwgl returns the **same** SPA shell — verified: nine
/// different paths, nine identical 20602-byte documents — so an endpoint
/// cannot be probed into existence, and its 404 tells you nothing. The set of
/// student functions is delivered at runtime by the menu, and what appears in
/// it depends on the account. The teaching-evaluation entry, in particular, is
/// not in this project's binary string dump at all, which is consistent with
/// the original app not hardcoding it either.
///
/// So the evaluation page cannot be named ahead of time. It is discovered from
/// the menu once a session exists, and the menu itself is captured for
/// diagnosis.
library;

import 'dart:convert';

/// One entry in the student function menu.
class JwglMenuEntry {
  const JwglMenuEntry({
    required this.name,
    this.gnmkdm = '',
    this.url = '',
    this.children = const <JwglMenuEntry>[],
    this.raw = const {},
  });

  /// The label a student sees, e.g. `成绩查询`, `教学评价`.
  final String name;

  /// The function code, e.g. `N305005`.
  final String gnmkdm;

  /// The page this entry opens, when the menu carries one.
  final String url;

  final List<JwglMenuEntry> children;
  final Map<String, Object?> raw;

  bool get hasChildren => children.isNotEmpty;

  /// The same entry reached twice, judged by where it goes rather than by what it
  /// is called: this page labels two different things 学生评教 and two different
  /// things 教材查询, so a label-keyed check would collapse entries that are not
  /// the same.
  String get dedupeKey => '$gnmkdm|$url|$name';

  /// A copy with [children] attached, used when a dropdown grouping is read and
  /// its own label becomes the parent name.
  JwglMenuEntry copyWith({List<JwglMenuEntry>? children}) => JwglMenuEntry(
        name: name,
        gnmkdm: gnmkdm,
        url: url,
        children: children ?? this.children,
        raw: raw,
      );

  /// Whether this entry, or anything under it, looks like teaching evaluation
  /// or grading.
  ///
  /// Matching on the label rather than a path, because **the path is not known
  /// ahead of time** — the evaluation page is only named by the menu, and this
  /// project's binary contains no evaluation path at all. Labels are the only
  /// stable handle available before a real menu has been seen.
  bool get looksLikeEvaluation => _matchesEvaluation(name);

  bool containsEvaluation() {
    if (looksLikeEvaluation) return true;
    return children.any((c) => c.containsEvaluation());
  }

  /// Every entry whose subtree mentions teaching evaluation **and can be opened**.
  ///
  /// The destination requirement is not a detail. This menu draws evaluation as a
  /// dropdown whose own label is also 学生评教 and whose `url` is empty — it exists
  /// to group, not to go anywhere. Counting it would report two evaluation entries
  /// where the system offers one, and the caller would then try to open a label.
  List<JwglMenuEntry> evaluationEntries() {
    final out = <JwglMenuEntry>[];
    void walk(JwglMenuEntry e) {
      if (e.looksLikeEvaluation && e.url.isNotEmpty) out.add(e);
      for (final c in e.children) {
        walk(c);
      }
    }

    walk(this);
    return out;
  }

  /// Every entry, flattened.
  List<JwglMenuEntry> get flattened => <JwglMenuEntry>[
        ...children,
        for (final c in children) ...c.flattened,
      ];

  static bool _matchesEvaluation(String name) {
    const terms = [
      '评教',
      '教学评价',
      '教师评价',
      '学生评教',
      '课程评价',
      '给分',
      'evaluation',
      'teachingquality',
    ];
    final n = name.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    return terms.any((t) => n.contains(t.toLowerCase()));
  }

  @override
  String toString() {
    final code = gnmkdm.isEmpty ? '' : ' $gnmkdm';
    final kids = children.isEmpty ? '' : ' +${children.length}';
    return 'JwglMenuEntry($name$code$kids)';
  }
}

/// The parsed student menu.
class JwglMenu {
  const JwglMenu({this.roots = const <JwglMenuEntry>[], this.rawBody = ''});

  final List<JwglMenuEntry> roots;

  /// The body as received, kept for diagnosis — the menu's exact shape is not
  /// established yet, because it can only be fetched with a session.
  final String rawBody;

  int get length => roots.length;

  bool get isEmpty => roots.isEmpty;

  /// Every teaching-evaluation entry anywhere in the tree.
  List<JwglMenuEntry> evaluationEntries() => <JwglMenuEntry>[
        for (final r in roots) ...r.evaluationEntries(),
      ];

  /// Every entry flattened to one list.
  List<JwglMenuEntry> get all => <JwglMenuEntry>[
        ...roots,
        for (final r in roots) ...r.flattened,
      ];

  /// The parsed menu, or a failure describing why it could not be read.
  ///
  /// The shape is not established, so this accepts several envelopes rather
  /// than asserting one. Each alias here is a candidate to be **narrowed**
  /// once a real menu is captured — not a list to keep widening.
  static JwglMenu parse(String body) {
    final trimmed = body.trimLeft();
    if (trimmed.isEmpty) {
      return const JwglMenu(rawBody: '');
    }

    final decoded = _tryDecode(trimmed);
    if (decoded != null) {
      final roots = <JwglMenuEntry>[];
      _collect(decoded, roots, depth: 0);
      return JwglMenu(roots: roots, rawBody: body);
    }

    // Not JSON: read the menu out of the markup the system actually serves.
    final roots = _fromHtml(body);
    return JwglMenu(roots: roots, rawBody: body);
  }

  static Object? _tryDecode(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  /// Walks a decoded structure looking for menu-shaped nodes.
  ///
  /// A node qualifies when it carries both a label and one of the identifying
  /// fields (`gnmkdm`, `url`). Requiring a label is what keeps arbitrary nested
  /// metadata from being mistaken for a menu entry.
  static void _collect(Object? node, List<JwglMenuEntry> into,
      {int depth = 0}) {
    if (depth > 12 || into.length > 400) return;

    if (node is List) {
      for (final item in node) {
        _collect(item, into, depth: depth);
      }
      return;
    }
    if (node is! Map) return;

    final entry = _entryOf(node);
    if (entry != null) {
      into.add(entry);
      return;
    }

    // A container: descend into the first list-valued property.
    for (final value in node.values) {
      if (value is List) _collect(value, into, depth: depth + 1);
    }
  }

  static JwglMenuEntry? _entryOf(Map<dynamic, dynamic> node) {
    final name = _text(node, const [
      'kjmc',
      'name',
      'title',
      'mc',
      'text',
      'label',
      'gnmkdmName',
    ]);
    if (name == null || name.isEmpty) return null;

    final gnmkdm =
        _text(node, const ['gnmkdm', 'gnm_kdm', 'funcCode', 'code']) ?? '';
    final url = _text(node, const [
          'url',
          'href',
          'pageUrl',
          'funcUrl',
          'path',
          'wj',
        ]) ??
        '';
    if (gnmkdm.isEmpty && url.isEmpty) return null;

    final children = <JwglMenuEntry>[];
    for (final key in const ['children', 'subMenus', 'items', 'subs', 'list']) {
      final v = node[key];
      if (v is List) _collect(v, children, depth: 4);
      if (children.isNotEmpty) break;
    }

    return JwglMenuEntry(
      name: name,
      gnmkdm: gnmkdm,
      url: url,
      children: children,
      raw: Map<String, Object?>.from(node),
    );
  }

  /// Reads the menu out of the HTML the system actually serves.
  ///
  /// Two shapes, both transcribed from a live student session rather than
  /// guessed, because the first version of this parser handled neither and a
  /// dropdown entry in particular was invisible to it:
  ///
  /// ```html
  /// <!-- ordinary entry: the destination is inside the onclick -->
  /// <a onclick="clickMenu('N305005','/cjcx/cjcx_cxDgXscj.html','学生成绩查询','null');">
  ///   学生成绩查询</a>
  ///
  /// <!-- dropdown child: the destination is in a data attribute, and the href
  ///      is javascript:void(0), which a href-only reader skips entirely -->
  /// <li class="dropdown">
  ///   <a href="#" data-toggle="dropdown">学生评教</a>
  ///   <ul class="dropdown-menu">
  ///     <li><a class="nav-target" data-gnmkdm="N05"
  ///            data-dyym="/xtgl/index_cxDddz.html?type=jser&amp;url=https%3A%2F%2Fugsqs.whu.edu.cn%2Fcaslogin"
  ///            href="javascript:void(0);">学生评教</a></li>
  ///   </ul>
  /// </li>
  /// ```
  ///
  /// The evaluation entry is that second shape, and it is the single most
  /// important row in the whole menu for this feature — so the reader has to
  /// understand `data-dyym` or it will keep reporting "no evaluation entry"
  /// while one sits in plain sight.
  static List<JwglMenuEntry> _fromHtml(String html) {
    final roots = <JwglMenuEntry>[];

    // Dropdowns first, and as whole blocks: the markup nests, so splitting on
    // `<li` would cut a parent away from the items underneath it and leave the
    // grouping labels lost. The block runs from the dropdown's own `<li` to the
    // `</ul>` that closes its menu.
    var remainder = html;
    final dropdown = RegExp(
      r'<li[^>]*class\s*=\s*"[^"]*dropdown[^"]*"[^>]*>([\s\S]*?)</ul\s*>',
      caseSensitive: false,
    );
    for (final m in dropdown.allMatches(html)) {
      final block = m.group(0)!;
      final parent = _parentAnchor(block);
      final children = _leafAnchors(block);
      if (parent != null && children.isNotEmpty) {
        roots.add(parent.copyWith(children: children));
      } else {
        roots.addAll(children);
      }
      remainder = remainder.replaceFirst(block, '');
    }

    // Whatever is left is the ungrouped top level.
    roots.addAll(_leafAnchors(remainder));

    // Deduplicate: the same destination can be reachable from more than one
    // anchor on this page, and a repeated row reads as a bug to whoever is
    // looking at the list.
    final seen = <String>{};
    return [
      for (final e in roots)
        if (seen.add(e.dedupeKey)) e,
    ];
  }

  /// The `dropdown-toggle` anchor of a block, if it has one.
  static JwglMenuEntry? _parentAnchor(String block) {
    final m = RegExp(
      r'<a\b[^>]*class\s*=\s*"[^"]*dropdown-toggle[^"]*"[^>]*>(.*?)</a>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(block);
    if (m == null) return null;
    final label = _labelOf(m.group(1) ?? '');
    if (label.isEmpty) return null;
    return JwglMenuEntry(name: label, url: '', gnmkdm: '');
  }

  /// Every leaf entry in a block: those carrying a `clickMenu` call or a
  /// `data-dyym` destination.
  static List<JwglMenuEntry> _leafAnchors(String block) {
    final out = <JwglMenuEntry>[];
    for (final m
        in RegExp(r'<a\b[^>]*>(.*?)</a>', caseSensitive: false, dotAll: true)
            .allMatches(block)) {
      final tag = m.group(0)!;
      // Skip the grouping anchor itself; it opens a dropdown rather than a page.
      if (RegExp(r'class\s*=\s*"[^"]*dropdown-toggle', caseSensitive: false)
          .hasMatch(tag)) {
        continue;
      }

      final label = _labelOf(m.group(1) ?? '');
      if (label.isEmpty) continue;

      final click = _clickMenu(tag);
      if (click != null) {
        out.add(JwglMenuEntry(
          name: click.label.isEmpty ? label : click.label,
          gnmkdm: click.code,
          url: click.url,
        ));
        continue;
      }

      final dyym = _attr(tag, 'data-dyym');
      if (dyym != null && dyym.isNotEmpty) {
        out.add(JwglMenuEntry(
          name: label,
          gnmkdm: _attr(tag, 'data-gnmkdm') ?? '',
          // The destination is a shim on this host that forwards elsewhere, so
          // the useful part is the `url=` it carries.
          url: _forwardTarget(dyym),
          raw: {'data-dyym': dyym},
        ));
        continue;
      }

      // Last resort: a plain `href`. Not how this deployment's entries are
      // written — they use the two forms above — but it costs nothing and keeps a
      // menu that spells its destinations out literally readable.
      final href = (_attr(tag, 'href') ?? '').trim();
      if (href.isEmpty ||
          href.startsWith('#') ||
          href.startsWith('javascript:')) {
        continue;
      }
      out.add(JwglMenuEntry(name: label, url: href));
    }
    return out;
  }

  /// The visible text of an anchor, with any `<b class="caret">` taken out.
  static String _labelOf(String inner) => inner
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// `clickMenu('N305005','/cjcx/cjcx_cxDgXscj.html','学生成绩查询','null')`.
  static ({String code, String url, String label})? _clickMenu(String tag) {
    final m = RegExp(
      r"""clickMenu\s*\(\s*'([^']*)'\s*,\s*'([^']*)'\s*,\s*'([^']*)'""",
      caseSensitive: false,
    ).firstMatch(tag);
    if (m == null) return null;
    return (code: m.group(1)!, url: m.group(2)!, label: m.group(3)!);
  }

  /// The `url=` a forwarding shim carries, decoded.
  ///
  /// `/xtgl/index_cxDddz.html?type=jser&url=https%3A%2F%2Fugsqs.whu.edu.cn%2Fcaslogin`
  /// becomes `https://ugsqs.whu.edu.cn/caslogin`. When the shim carries no
  /// `url=`, the shim itself is returned, because it is still where the entry
  /// points.
  static String _forwardTarget(String dyym) {
    final q = dyym.indexOf('?');
    if (q < 0) return dyym;
    final params = Uri.splitQueryString(dyym.substring(q + 1));
    final target = params['url'];
    if (target != null && target.trim().isNotEmpty) return target;
    return dyym;
  }

  /// Reads `name="value"`, `name='value'` or `name=value` off a tag.
  static String? _attr(String tag, String name) {
    final m = RegExp(
      '$name\\s*=\\s*("([^"]*)"|\'([^\']*)\'|([^\\s>]+))',
      caseSensitive: false,
    ).firstMatch(tag);
    if (m == null) return null;
    final raw = m.group(2) ?? m.group(3) ?? m.group(4) ?? '';
    // Attribute values are HTML-escaped in the served page.
    return raw
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
  }

  static String? _text(Map<dynamic, dynamic> node, List<String> keys) {
    for (final k in keys) {
      final v = node[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }
}
