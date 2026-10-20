/// Every constant in this file carries its provenance, because the reimplementation
/// mixes three different evidence classes and pretending otherwise would be worse
/// than useless:
///
///   [V] verified — observed directly by this project (own HTTP probe or own
///       binary-string extraction), reproducible on demand.
///   [D] doc — read out of the WHU 教务 system by the earlier `ham-win` session
///       (the 2026-10-14 capture of that grid is kept outside this repository).
///       Not independently re-verified here.
///   [S] standard — a well-known fixed name from the CAS protocol or the
///       正方 product, not observed per-deployment.
///
/// Anything [D] is called out in the field it affects so a future reader knows
/// which values to re-check against a live page before trusting them.
library;

/// The CAS single-sign-on origin for this university.
class CasOrigin {
  const CasOrigin._();

  /// [V] Login form. Suffix it with `Uri.encodeComponent(service)`.
  static const String login =
      'https://cas.whu.edu.cn/authserver/login?service=';

  /// [V] Where the password form posts. Taken from the form's own `action`
  /// attribute, which is a **bare path with no query string** — the `service`
  /// is remembered server-side from the GET that produced the form and is not
  /// resubmitted. Adding it back is harmless-looking and not what the page does.
  static const String loginPost = 'https://cas.whu.edu.cn/authserver/login';

  /// [V] The CAS **context path**, and the only URL that yields the grant.
  ///
  /// Confirmed against a real sign-in rather than inferred. After one
  /// successful interactive login, WebView2's cookie store held
  ///
  ///     host  cas.whu.edu.cn   name  CASTGC   path  /authserver   HttpOnly
  ///
  /// carrying a real value. (The server's clearing header on an
  /// unauthenticated GET spells the same path with a trailing slash,
  /// `path=/authserver/`; either spelling is matched by this URL.)
  ///
  /// This matters because cookie lookup is **path-matched** — the Windows
  /// plugin maps `getCookies(url:)` onto CDP `Network.getCookies({urls:[url]})`.
  /// Asking for the bare host, `https://cas.whu.edu.cn` (path `/`), does not
  /// match `/authserver`, so the grant is never returned and a perfectly good
  /// sign-in is reported as a missing ticket. That was a real, shipped bug.
  static const String authserverRoot = 'https://cas.whu.edu.cn/authserver/';

  /// [V] Answers `{"isNeed": <bool>}` — the server decides whether an
  /// interactive CAPTCHA is required. There is **no client-side switch**: the
  /// earlier assumption that a `validate=1` parameter would skip the CAPTCHA
  /// is false, and is not derivable from the binary either (the only
  /// `validate=` literal present is `validate=no`).
  static const String checkNeedCaptcha =
      'https://cas.whu.edu.cn/authserver/checkNeedCaptcha.htl';

  /// [V] `{"smallImage": "<base64 png>", ...}` — the slider puzzle, 54573 B
  /// when fetched unauthenticated.
  static const String openSliderCaptcha =
      'https://cas.whu.edu.cn/authserver/common/openSliderCaptcha.htl';

  /// [V] `{"code":"captchaError","message":"验证码错误"}` when called bare.
  static const String dynamicCode =
      'https://cas.whu.edu.cn/authserver/dynamicCode/getDynamicCode.htl';

  /// [V] Credential cookie, name confirmed from the server's own `Set-Cookie`.
  ///
  /// Now observed directly rather than inferred from the binary: a GET to the
  /// sign-in form answers with a clearing header for exactly this name. It is
  /// scoped to [authserverRoot], not to the host.
  static const String tgcCookie = 'CASTGC';

  /// [V] `JSESSIONID=` and `hasJSESSIONID=` both appear in the binary.
  static const String sessionCookie = 'JSESSIONID';
}

/// The 正方教务 (ZFWeb) academic system.
class JwglOrigin {
  const JwglOrigin._();

  static const String root = 'https://jwgl.whu.edu.cn';

  /// [V] The grade query page. **Measured against a live signed-in student
  /// session, not inferred — and the measurement contradicts the page's own
  /// source.**
  ///
  /// | URL, with `?gnmkdm=N305005&layout=default` | answer |
  /// |---|---|
  /// | `cjcx_cxXsgrcj.html` | **404**, document title 系统维护页面 |
  /// | `cjcx_cxDgXscj.html` | title 学生成绩查询, the `xnm`/`xqm` term selects, and `#tabGrid` |
  ///
  /// The signed-in menu's own entry agrees:
  /// `clickMenu('N305005','/cjcx/cjcx_cxDgXscj.html','学生成绩查询','null')`.
  ///
  /// This is worth spelling out because the page's JavaScript says otherwise:
  ///
  /// ```
  /// url: _path + ($("#jsxx").val() == "xs" ? '/cjcx/cjcx_cxXsgrcj.html'
  ///                                       : '/cjcx/cjcx_cxDgXscj.html')
  ///        + '?doType=query'
  /// ```
  ///
  /// Read literally that sends a student (`jsxx == "xs"`) to `cxXsgrcj` — but the
  /// account that was measured **is** a student, and `cxXsgrcj` is the one that
  /// 404s. The ternary is stale for this deployment (版本V-9.0). Believing it once
  /// already cost the user a 404, so do not "restore" it a second time: the probe
  /// and the menu are the authorities here, and both name `cxDgXscj`.
  ///
  /// No role branch is modelled, because only one page answers. If a future
  /// account turns out to need the other name, the 404 above is what to look for.
  static const String gradeQuery = '$root/cjcx/cjcx_cxDgXscj.html';

  /// [V] **[X] Absent on this deployment** — answers 404, documented here only so
  /// that the ternary quoted above does not get believed again.
  static const String missingGradeQueryAlias = '$root/cjcx/cjcx_cxXsgrcj.html';

  /// [V] The function code the grade page is served under, sent as `gnmkdm`.
  static const String gradeGnmkdm = 'N305005';

  /// [V] How the grade query is actually sent: **POST**, with these form fields.
  ///
  /// Taken from a working implementation rather than inferred — the request is
  /// `POST {gradeQuery}?doType=query&gnmkdm=N305005` with
  /// `validate`, `xnm`, `xqm` and a page size. `validate` is a **random string**
  /// (`'sl' + rnd + timestamp`), not a CAPTCHA answer: the client-side panel that
  /// challenges a browser is never loaded by a plain HTTP client.
  static const String gradePageSizeField = 'queryModel.showCount';

  /// [V] The page size a working implementation asks for.
  static const String gradePageSize = '150';

  /// [D] The `zd_fzdm` function discriminator. `-xs` for students, `-gly` for
  /// staff. Passed as a jqGrid `remoteParams` entry, not a query-string flag.
  ///
  /// Retained only because a caller may still pass it. It is **not** what the
  /// live grade page uses: that page is addressed by `gnmkdm`, above.
  static const String studentZdFzdm = 'N305005-xs';
  static const String staffZdFzdm = 'N305005-gly';

  /// [V] Student function menu. `jsdm=xs` selects the student role.
  ///
  /// The discovery point: every route under this host answers the same SPA shell,
  /// so a function cannot be probed into existence. What the account may do is
  /// delivered here, and it is the only authority on it — including on whether an
  /// evaluation entry exists at all.
  static const String menu = '$root/xtgl/index_initMenu.html';

  /// [V] Role code for a student session.
  static const String studentJsdm = 'xs';

  /// [V] Known student pages, transcribed from a live menu rather than inferred.
  ///
  /// Kept as a cross-check against what the menu returns, not as a substitute for
  /// reading it: some of these are reached through a forwarding shim and the
  /// argument they carry is part of the address.
  static const Map<String, String> knownPages = {
    'N305005': '/cjcx/cjcx_cxDgXscj.html', // 学生成绩查询
    'N532560': '/xsbysjgl/cjck_cxCjckIndex.html', // 成绩查看
    'N2151': '/kbcx/xskbcx_cxXskbcxIndex.html', // 个人课表查询
    'N358105': '/kwgl/kscx_cxXsksxxIndex.html', // 考试信息查询
    'N105515': '/xsxy/xsxyqk_cxXsxyqkIndex.html?echarts=1', // 学生学业情况查询
    'N151095': '/kckgl/kcdgcx_cxKcdgcxIndex.html', // 课程大纲查询
    'N253536': '/xsxk/tjxkyzb_cxXsxkjcInfo.html', // 教材查询
    'N253512': '/xsxk/zzxkyzb_cxZzxkYzbIndex.html', // 自主选课
    'N100801': '/xsxxxggl/xsgrxxwh_cxXsgrxx.html', // 查询个人信息
    // 学生评教 — the entry this whole feature exists for. Its destination is the
    // evaluation system, reached through the shim below.
    'N05': '$root/xtgl/index_cxDddz.html',
  };

  /// [V] The forwarding shim a menu entry uses to hand off to another host.
  ///
  /// Transcribed from the evaluation entry:
  /// `/xtgl/index_cxDddz.html?type=jser&url=https%3A%2F%2Fugsqs.whu.edu.cn%2Fcaslogin`.
  /// The host, path and query parameter are all fixed; only the encoded target
  /// varies, so callers assemble it rather than parsing it out of a menu row.
  static const String forwardShim = '$root/xtgl/index_cxDddz.html';

  /// [D] The timetable query's data endpoint (N2151).
  ///
  /// The index page `/kbcx/xskbcx_cxXskbcxIndex.html` is in [knownPages]; this
  /// is the AJAX target it posts to in 正方's published convention, with
  /// `xnm` (year) and `xqm` (term code). **Not captured from this deployment**
  /// — see `docs/grades-and-reviews.md`. Treat a response shape mismatch as a
  /// reason to capture the real one, not as a reason to widen the parser.
  static const String timetableData = '$root/kbcx/xskbcx_cxXsKb.html';

  /// [V] The page that establishes the 教务 session for the timetable module.
  ///
  /// The data endpoint is a POST, so a session first has to walk the CAS hop
  /// and absorb the cookies that page sets. Posting with only a CAS grant and
  /// no service cookie gets an empty JSON list, not a sign-in page.
  static const String timetablePage = '$root/kbcx/xskbcx_cxXskbcxIndex.html';

  /// [D] The function code the timetable page is served under.
  static const String timetableGnmkdm = 'N2151';

  /// [V] `/js/**` is served without a session — confirmed by fetching
  /// `/js/browse/browse-judge.js` (HTTP 200, 6224 B). This is how a contract
  /// should be read: from the page's own script, not by guessing parameters.
  ///
  /// That particular script is also the name of the browsing judge behind the
  /// grade query's CAPTCHA, which is why the file was looked up in the first
  /// place.
  static const String publicScriptRoot = '$root/js/';

  /// [V] The `service` CAS redirects to once the ticket is granted.
  /// Sourced verbatim from the binary as `https://jwgl.whu.edu.cn/sso/jznewsixlogin`.
  static const String casService = 'https://jwgl.whu.edu.cn/sso/jznewsixlogin';
}

/// Teacher evaluation (评教) — a separate system from 教务.
class TeachingEvalOrigin {
  const TeachingEvalOrigin._();

  static const String root = 'https://ugsqs.whu.edu.cn';

  /// [D] Not present anywhere in this project's binary extraction: `ugsqs`
  /// returns **zero** hits across the whole string snapshot. The value comes
  /// from the earlier `ham-win` session, which observed that navigating to
  /// `ugsqs.whu.edu.cn/caslogin/` while a CAS session is still live yields a
  /// 302 with a ticket — no second sign-in, and it does not spend one of the
  /// origin's limited login attempts.
  ///
  /// Treat this as unverified until one real flow confirms it.
  static const String casService = '$root/caslogin/';
}

/// Library seat booking.
class LibrarySeatOrigin {
  const LibrarySeatOrigin._();

  static const String root = 'https://seat.lib.whu.edu.cn';

  /// [V source, ambiguous use] Two strings survive in the binary:
  ///
  ///   `.../rem/static/sso/webOAuthRed`          (truncated)
  ///   `.../rem/static/sso/login?redirectUrl=https://seat.lib.whu.edu.cn/seat`
  ///
  /// The second is complete and is used here, but **it may be the library's
  /// own pre-CAS entry page rather than the CAS service target.** Using it as
  /// a `service` could yield a redirect loop instead of a ticket. Left
  /// nullable at the call site for exactly that reason — establish it with one
  /// observed flow before relying on it.
  static const String casService =
      '$root/rem/static/sso/login?redirectUrl=$root/seat';
}

/// Term codes as the academic system encodes them.
///
/// [V] Both the codes and their **labels** are now read off the grade page's own
/// term selector, which renders every option as `value:label`:
///
///     3  → 第1学期
///     12 → 第2学期
///     16 → 第3学期
///
/// The codes match what the public master-timetable service returns in its
/// `semester` field, which is where they were first seen. What is new is that the
/// **labels are observed rather than assumed**: an earlier version labelled them
/// 秋季/冬季/夏季 and kept [WhuTermXqmResolver] as an explicit placeholder because
/// the mapping was "not established". The selector decides it.
///
/// A lexical sort of the codes is wrong (`"12" < "16" < "3"`), so always compare
/// by [order].
enum WhuTerm {
  first('3', '第1学期'),
  second('12', '第2学期'),
  third('16', '第3学期');

  const WhuTerm(this.code, this.label);

  /// [V] as the grade page's `xqm` selector carries it.
  final String code;

  /// [V] the label that same selector shows for [code].
  final String label;

  /// Position in the academic year.
  ///
  /// Named `order` rather than `index` because `Enum.index` is reserved on
  /// Dart enums. Use this for sorting — the codes sort lexically as
  /// `"12" < "16" < "3"`, which would put the second and third terms first.
  int get order => WhuTerm.values.indexOf(this);

  /// The term a `xqm` value names, or null when it is not one of the three.
  static WhuTerm? fromCode(String code) {
    for (final t in WhuTerm.values) {
      if (t.code == code) return t;
    }
    return null;
  }
}
