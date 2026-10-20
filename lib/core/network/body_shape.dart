/// Shape predicates for HTTP response bodies.
///
/// Kept in one place because two features need the same verdict and the answer
/// must not drift between them: the 教务 grade view and the grade/review query
/// both hinge on telling "JSON data" apart from "the sign-in page came back".
///
/// The failure this guards against, in both features, is identical: a campus
/// endpoint answers **HTTP 200 with HTML** when a session has lapsed. A
/// status-code check reports success, the parser finds no rows, and the UI shows
/// an empty list — which reads as "you have no data" rather than "you are signed
/// out". These predicates are what break that chain.
library;

/// Whether a body is JSON *data* — an object or an array.
///
/// Deliberately narrow. A bare JSON scalar (`"x"`, `42`, `null`) is valid JSON
/// but never a payload either feature can use, and treating it as one would push
/// the failure further from its cause.
bool looksLikeJson(String body) {
  final t = body.trimLeft();
  return t.startsWith('{') || t.startsWith('[');
}

/// Whether a body is HTML.
///
/// Deliberately broad — "starts with `<`" — because the sign-in page is not the
/// only shape this takes: an error page, a maintenance notice, or a fragment can
/// each arrive where JSON was expected, and all of them need the same answer.
bool looksLikeHtml(String body) => body.trimLeft().startsWith('<');

/// Whether a body is neither JSON nor HTML — a captive portal, a proxy notice,
/// or plain prose.
bool looksLikeOpaque(String body) {
  final t = body.trimLeft();
  return t.isNotEmpty && !looksLikeJson(t) && !looksLikeHtml(t);
}

/// Whether a body is a campus **sign-in wall** rather than the page asked for.
///
/// [looksLikeHtml] is not enough on its own, and that is the trap this exists
/// for. 正方教务 serves one SPA shell for every route — verified: nine different
/// paths, nine identical 20602-byte documents — so "it is HTML" says nothing
/// about whether a session is alive. What distinguishes an expired session is
/// the presence of the sign-in form's own markers.
///
/// The central service's name is in the list because CAS is where both systems
/// send an unauthenticated caller, which makes it the single clearest signal that
/// the caller is not signed in.
bool looksLikeSignInPage(String body) {
  final h = body.toLowerCase();
  return h.contains('authserver') ||
      h.contains('auth_cxyhloginzt') ||
      h.contains('login_slogin') ||
      (h.contains('<form') && h.contains('password'));
}
