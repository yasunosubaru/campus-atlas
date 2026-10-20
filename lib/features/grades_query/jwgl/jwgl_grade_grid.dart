/// Reading the grade grid out of the page the browser has already rendered.
///
/// ## Why the reading happens in the page
///
/// The academic system's grade query is gated by an anti-bot puzzle that this app
/// does not solve — measured, not assumed: with a freshly signed-in student
/// session, pressing 查询 answers with `请拖动左侧滑块还原图片`. So a person clears
/// the puzzle, and once the grid is on screen the data is **already in the
/// document**. Copying it from the DOM therefore touches no verification at all:
/// it reads what the person can see.
///
/// ## The grid is a jqGrid, and it is two tables
///
/// Read off a live 学生成绩查询 page rather than guessed:
///
/// | element | what it holds |
/// |---|---|
/// | `table.ui-jqgrid-htable thead th` | the **header**; each `th.id` is `<grid>_<field>` |
/// | `table.ui-jqgrid-btable` (`#tabGrid`) | the **body**; each `td[aria-describedby]` names its own column |
///
/// That pairing is the reliable part: header id and cell attribute are the *same*
/// string, which is how jqGrid addresses a column. It is far better than matching
/// on label text, where `学分` is a substring of `学分绩点` and the wrong column
/// would win silently.
///
/// Two rows are not data and are skipped: `jqgfirstrow` (jqGrid's empty spacer,
/// one cell per column) and `emptyrow` (the "nothing to show" row, whose text —
/// `请选择筛选条件!` or `无数据显示` — is reported back as [JwglGradeGrid.notice]).
library;

/// The window variable the script leaves its answer in.
///
/// The answer is **read back in a second call**, not taken from the first call's
/// return value. `ExecuteScript` reports a script that produced no completion
/// value as the four characters `null`, which is indistinguishable from a script
/// that legitimately answered `null` — and that ambiguity cost a real debugging
/// round here: the app reported "the script returned nothing" for a script that
/// was never at fault.
///
/// An assignment is a plain statement whose effect can be observed afterwards,
/// so reading the variable says which of the two actually happened.
const String gradeGridVariable = '__campusAtlasGradeGrid';

/// The script handed to the browser.
///
/// Stores its answer in [gradeGridVariable] and clears it first, so a failure
/// leaves `null` rather than the previous run's answer. The `try` is inside the
/// script on purpose: whatever goes wrong, the variable ends up holding a JSON
/// string that says so, and the caller never has to interpret an empty result.
final String gradeGridRunScript = 'window.$gradeGridVariable = null;'
    'try { window.$gradeGridVariable = $gradeGridScript; } '
    'catch (e) { window.$gradeGridVariable = JSON.stringify({'
    'error: "the script threw: " + (e && e.message ? e.message : String(e))'
    '}); }';

/// The script handed to the browser. Returns a JSON string.
///
/// Kept as one expression so WebView2 returns its value rather than `undefined`.
///
/// ## Only plain loops, no `Array.prototype` helpers
///
/// Deliberate, and not premature caution. The first version used `map`, `filter`
/// and `some`, and threw `cells.some is not a function` on the real grade page.
/// The page is an old 正方 deployment that ships its own compatibility scripts,
/// so the built-in array methods are **not** guaranteed to be the ones this
/// project expects. Ordinary `for` loops and `push` cannot be shadowed that way.
const String gradeGridScript = r'''
(function () {
  var text = function (el) { return (el.innerText || '').replace(/\s+/g, ' ').trim(); };

  var each = function (list, fn) {
    for (var i = 0; i < list.length; i++) fn(list[i]);
  };
  var collect = function (list) {
    var out = [];
    each(list, function (item) { out.push(item); });
    return out;
  };
  var truthyKey = function (obj) {
    for (var key in obj) {
      if (Object.prototype.hasOwnProperty.call(obj, key)) return true;
    }
    return false;
  };
  var anyNonEmpty = function (list) {
    for (var i = 0; i < list.length; i++) {
      if (list[i].length > 0) return true;
    }
    return false;
  };

  var header = document.querySelector('table.ui-jqgrid-htable');
  var body = document.querySelector('table.ui-jqgrid-btable');

  if (!body && !header) {
    // No jqGrid on the page. Fall back to the table with the most rows, so an
    // unfamiliar layout reports something visible rather than nothing.
    var tables = document.querySelectorAll('table');
    var best = null;
    var bestCount = 0;
    for (var ti = 0; ti < tables.length; ti++) {
      var t = tables[ti];
      var n = t.querySelectorAll('tbody tr').length || t.querySelectorAll('tr').length;
      if (n > bestCount) { bestCount = n; best = t; }
    }
    if (best === null) {
      // Reported rather than thrown: the counts are what say whether this is the
      // grade page at all, or a login or maintenance page that merely has the
      // right address.
      return JSON.stringify({
        error: 'no table with rows',
        url: location.href,
        title: document.title,
        tables: document.querySelectorAll('table').length,
        rows: document.querySelectorAll('tr').length,
        iframes: document.querySelectorAll('iframe').length,
        readyState: document.readyState
      });
    }
    body = best;
  }

  var gridId = (body && body.id) || '';
  var prefix = gridId ? gridId + '_' : '';
  // jqGrid writes the same "<grid>_<field>" string into `th.id` and into each
  // cell's `aria-describedby`; stripping the prefix leaves the field name.
  var fieldOf = function (raw) {
    if (!raw) return '';
    return prefix && raw.indexOf(prefix) === 0 ? raw.slice(prefix.length) : raw;
  };

  var columns = [];
  if (header) {
    each(header.querySelectorAll('thead th'), function (th) {
      var label = text(th);
      var field = fieldOf(th.id || '');
      var hidden = th.style.display === 'none' || th.offsetParent === null;
      // A technical column carries its own field name where a label would be
      // (`ksxzdm`, `bfzcj`, ...). It is not shown to a person, so it is not
      // reported; it stays addressable by field either way.
      if (!field) return;
      if (!label || label === field) return;
      columns.push({ field: field, label: label, hidden: hidden });
    });
  }

  var visible = [];
  for (var ci = 0; ci < columns.length; ci++) {
    if (!columns[ci].hidden) visible.push(columns[ci]);
  }
  if (!visible.length) visible = columns;

  var notice = '';
  var rows = [];

  if (body) {
    each(body.querySelectorAll('tbody tr'), function (tr) {
      var cls = String(tr.className);
      if (cls.indexOf('jqgfirstrow') >= 0) return;
      if (cls.indexOf('emptyrow') >= 0) {
        notice = text(tr);
        return;
      }

      var byField = {};
      var fallback = [];
      each(tr.children, function (td) {
        var field = fieldOf(td.getAttribute('aria-describedby') || '');
        var value = text(td);
        if (field) byField[field] = value;
        fallback.push(value);
      });

      // Column order comes from the header, so a row whose cells arrive in a
      // different order is still lined up with its own labels.
      //
      // The `byField` guard matters: a jqGrid that does not write
      // `aria-describedby` would otherwise produce rows of blanks, which reads as
      // "the data is empty" rather than "the mapping failed" - the worse of the
      // two. With no cell naming its column, positions are the honest fallback.
      var cells = fallback;
      if (visible.length && truthyKey(byField)) {
        cells = [];
        for (var vi = 0; vi < visible.length; vi++) {
          var val = byField[visible[vi].field];
          cells.push(val === undefined ? '' : val);
        }
      }
      if (anyNonEmpty(cells)) rows.push(cells);
    });
  }

  var fields = [];
  var heads = [];
  for (var wi = 0; wi < visible.length; wi++) {
    fields.push(visible[wi].field);
    heads.push(visible[wi].label);
  }

  return JSON.stringify({
    url: location.href,
    title: document.title,
    gridId: gridId,
    notice: notice,
    fields: fields,
    head: heads,
    rows: rows
  });
})()
''';

/// The jqGrid field names of the columns worth reading first.
///
/// These come from the live grid — `th.id` was `tabGrid_kcmc`, `tabGrid_cj`, and
/// so on — and are offered as a **preference, not a requirement**: [JwglGradeGrid.indexOfField]
/// answers -1 for a field that is not there, and callers fall back to
/// matching labels. A renamed grid column then degrades to a label lookup
/// instead of silently returning nothing.
class JwglGradeFields {
  const JwglGradeFields._();

  static const String courseName = 'kcmc';
  static const String courseCode = 'kch';
  static const String instructor = 'jsxm';
  static const String credits = 'xf';
  static const String score = 'cj';
  static const String gradePoint = 'jd';
  static const String gradePointCredits = 'xfjd';
  static const String courseKind = 'kcxzmc';
  static const String year = 'xnmmc';
  static const String term = 'xqmmc';

  /// Field then label, in the order a person wants to read a grade row.
  static const List<(String, String)> ordered = [
    (courseName, '课程名称'),
    (instructor, '任课教师'),
    (credits, '学分'),
    (score, '成绩'),
    (gradePoint, '绩点'),
    (gradePointCredits, '学分绩点'),
    (courseKind, '课程性质'),
    (year, '学年'),
    (term, '学期'),
    (courseCode, '课程代码'),
  ];
}

/// What the script found.
class JwglGradeGrid {
  const JwglGradeGrid({
    required this.head,
    required this.rows,
    this.fields = const [],
    this.notice = '',
    this.gridId = '',
    this.url = '',
    this.title = '',
  });

  /// Column labels, in the order the rows carry their cells.
  final List<String> head;

  /// The jqGrid field name of each column, parallel to [head] when present.
  final List<String> fields;

  /// Cell text, aligned to [head].
  final List<List<String>> rows;

  /// The grid's own "nothing to show" text — `请选择筛选条件!` or `无数据显示`.
  ///
  /// Worth surfacing verbatim: it distinguishes "the query ran and found nothing"
  /// from "the query has not been run yet", which a bare row count cannot.
  final String notice;

  final String gridId;
  final String url;
  final String title;

  bool get isEmpty => rows.isEmpty;

  /// The label for column [index], falling back to a positional name.
  ///
  /// A grid whose header did not survive the extraction still yields usable rows:
  /// the caller then shows them positionally rather than dropping them.
  String labelAt(int index) {
    if (index < head.length && head[index].isNotEmpty) return head[index];
    return '第${index + 1}列';
  }

  /// The jqGrid field for column [index], or `''` when unknown.
  String fieldAt(int index) => index < fields.length ? fields[index] : '';

  /// Column indices whose label contains any of [needles].
  List<int> columnsLike(List<String> needles) {
    final out = <int>[];
    for (var i = 0; i < head.length; i++) {
      final h = head[i];
      if (needles.any((n) => h.contains(n))) out.add(i);
    }
    return out;
  }

  /// The column carrying [field], or -1.
  ///
  /// This is the exact lookup; [columnsLike] is the tolerant one. Prefer this and
  /// fall back, so a label that happens to contain another (`学分` inside
  /// `学分绩点`) cannot win by accident while the field is still available.
  int indexOfField(String field) => fields.indexOf(field);

  /// Column [index] for [field], preferring the field and falling back to a label.
  int columnFor(String field, String labelNeedle) {
    final exact = indexOfField(field);
    if (exact >= 0) return exact;
    final like = columnsLike([labelNeedle]);
    return like.isEmpty ? -1 : like.first;
  }

  /// The value of [field] in [row] (a member of [rows]).
  String valueOf(String field, List<String> row, {String? labelNeedle}) {
    final index = columnFor(field, labelNeedle ?? field);
    if (index < 0 || index >= row.length) return '';
    return row[index];
  }

  /// Rows as field→value maps, for callers that want the grid's own names.
  List<Map<String, String>> get asFieldMaps => [
        for (final row in rows)
          {
            for (var i = 0; i < row.length; i++)
              (fieldAt(i).isEmpty ? labelAt(i) : fieldAt(i)): row[i],
          },
      ];

  /// Rows as label→value maps.
  List<Map<String, String>> get asMaps => [
        for (final row in rows)
          {
            for (var i = 0; i < row.length; i++) labelAt(i): row[i],
          },
      ];

  static JwglGradeGrid? tryParse(Object? payload) {
    if (payload is! Map) return null;
    final rows = payload['rows'];
    if (rows is! List) return null;
    // `head` is missing only when the payload is the script's error envelope
    // (`{error: 'no table with rows'}`). Inventing an empty grid there would hide
    // the failure, so it is refused.
    final head = payload['head'];
    if (head is! List) return null;

    return JwglGradeGrid(
      head: head.map((h) => '$h').toList(),
      fields: (payload['fields'] is List)
          ? (payload['fields'] as List).map((f) => '$f').toList()
          : const [],
      rows: [
        for (final row in rows)
          if (row is List) row.map((c) => '$c').toList(),
      ],
      notice: '${payload['notice'] ?? ''}',
      gridId: '${payload['gridId'] ?? ''}',
      url: '${payload['url'] ?? ''}',
      title: '${payload['title'] ?? ''}',
    );
  }

  /// A short human summary: how many rows, and what the columns are.
  ///
  /// The column list is the useful part when the numbers look wrong — it says
  /// immediately whether the extraction found the grade grid or some other table
  /// on the page.
  String get summary {
    final columns = head.isEmpty ? '(表头未读到)' : head.join(' / ');
    final extra = notice.isEmpty ? '' : ' · $notice';
    return '${rows.length} 行 · 列：$columns$extra';
  }
}
