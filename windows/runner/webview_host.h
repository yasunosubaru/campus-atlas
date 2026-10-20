#ifndef RUNNER_WEBVIEW_HOST_H_
#define RUNNER_WEBVIEW_HOST_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <wrl.h>

#include <memory>
#include <string>
#include <vector>

#include "webview2/WebView2.h"

// Hosts a WebView2 as a real child window of the Flutter host window.
//
// ## Why this exists instead of a Flutter platform view
//
// The app previously embedded a browser through `flutter_inappwebview`, which
// routes WebView2 through Flutter's platform-view compositing. In a **release**
// build that path failed: the WebView2 process loaded the page (its own cache
// directory proved it) and nothing reached the screen; the window went uniformly
// dark and no Dart exception was raised. Disabling Impeller made the page load
// and left the screen dark anyway, so the fault was in the compositing, not in
// the page.
//
// Here WebView2 is given an HWND that belongs to this process's window and draws
// itself with its own child window. Flutter never sees it, so that whole failure
// mode is out of the picture.
//
// ## What it is used for
//
// The academic-system grade query is gated by an anti-bot puzzle that only a
// person can solve. This host is how the person gets to solve it: the real page
// runs in the real engine, they interact with it, and the reply is read back as
// text. Nothing here solves, predicts, or synthesises a challenge.
class WebViewHost {
 public:
  WebViewHost();
  ~WebViewHost();

  // Binds to the window that will own the WebView and to the engine's messenger.
  void Attach(HWND parent, flutter::BinaryMessenger* messenger);

  // Releases the controller and the environment. Safe to call twice.
  void Shutdown();

  // Re-lays the WebView over the client area, e.g. after a resize.
  void Resize();

  // Raises the WebView above the Flutter view in the child z-order.
  void RaiseWebView();

  // Whether a page is currently being shown.
  bool IsShowing() const { return visible_; }

 private:
  void HandleMethod(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Creates the environment on first use, then the controller, then navigates.
  void EnsureStarted(const std::wstring& url);
  void Navigate(const std::wstring& url);
  void Show();
  void Hide();
  void RunScript(const std::wstring& script, int request_id);
  void Report(const std::string& method, flutter::EncodableValue value);

  // Reads the cookies the browser currently holds for each of [urls].
  //
  // This is how a sign-in done in the browser becomes the app's own session: the
  // person clears whatever the page asks for, the page's cookies are handed to
  // the Dart side, and every other feature is driven from them. It is also the
  // only way, because the anti-bot puzzle the grade query sits behind cannot be
  // answered here.
  //
  // Every origin involved has to be asked for by its own URL: WebView2 matches
  // cookies on **path** as well as host, so asking for `https://cas.whu.edu.cn/`
  // never returns the grant, which lives at `/authserver`.
  void CollectCookies(
      const std::vector<std::wstring>& urls,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // State for one in-flight CollectCookies call.
  //
  // Held by `shared_ptr` because the WebView2 callbacks outlive the call that
  // started them: each URL answers separately. `result` is nulled by Shutdown
  // rather than left dangling, so a reply is never attempted against a channel
  // that is being torn down.
  struct CookieHarvest {
    size_t pending = 0;
    flutter::EncodableList cookies;
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  };

  HWND parent_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  Microsoft::WRL::ComPtr<ICoreWebView2Environment> environment_;
  Microsoft::WRL::ComPtr<ICoreWebView2Controller> controller_;
  Microsoft::WRL::ComPtr<ICoreWebView2> webview_;

  std::shared_ptr<CookieHarvest> harvest_;

  std::wstring pending_url_;
  bool environment_ready_ = false;
  bool visible_ = false;
};

#endif  // RUNNER_WEBVIEW_HOST_H_
