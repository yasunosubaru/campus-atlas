#include "webview_host.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

using Microsoft::WRL::Callback;

namespace {

// Kept in one place so the folder is easy to find when a stale profile has to be
// cleared. It lives beside the executable, not in the user's roaming profile:
// this data is a cache, not a setting.
std::wstring UserDataFolder() {
  wchar_t exe[MAX_PATH];
  DWORD n = GetModuleFileNameW(nullptr, exe, MAX_PATH);
  std::wstring path(exe, n);
  auto slash = path.find_last_of(L'\\');
  if (slash != std::wstring::npos) path = path.substr(0, slash + 1);
  return path + L"webview2_profile";
}

// The strip at the top of the client area left to Flutter.
//
// The browser covers the client area, which would hide the app's own back button
// and trap the person inside it. Reserving the height of a standard toolbar keeps
// a way out. In logical pixels, scaled by the window's DPI.
constexpr double kReservedTopLogical = 56.0;

RECT BoundsWithTopStrip(HWND window) {
  RECT area{};
  GetClientRect(window, &area);
  const UINT dpi = GetDpiForWindow(window);
  const double scale = dpi == 0 ? 1.0 : static_cast<double>(dpi) / 96.0;
  area.top += static_cast<LONG>(kReservedTopLogical * scale);
  return area;
}

// WebView2's child window, found among the host's children.
//
// The controller does not expose its HWND, and `put_Bounds`/`put_IsVisible` do not
// affect stacking. So the window has to be located by class name and raised
// explicitly; see RaiseWebView for why that is not optional.
BOOL CALLBACK FindWebViewProc(HWND child, LPARAM param) {
  wchar_t cls[128] = {};
  if (GetClassNameW(child, cls, 128) == 0) return TRUE;
  if (wcsstr(cls, L"Chrome_WidgetWin") == nullptr) return TRUE;
  *reinterpret_cast<HWND*>(param) = child;
  return FALSE;  // stop at the first match
}

std::wstring Utf16(const std::string& s) {
  if (s.empty()) return std::wstring();
  int len = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
  std::wstring out(len, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &out[0], len);
  return out;
}

std::string Utf8(const std::wstring& s) {
  if (s.empty()) return std::string();
  int len = WideCharToMultiByte(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0,
                                nullptr, nullptr);
  std::string out(len, '\0');
  WideCharToMultiByte(CP_UTF8, 0, s.c_str(), (int)s.size(), &out[0], len, nullptr,
                      nullptr);
  return out;
}

}  // namespace

// One cookie as a map, carrying only what the Dart side needs.
//
// The values are sign-in credentials. They are passed along and never logged,
// never written to disk by this file, and never placed in error text.
flutter::EncodableValue CookieToValue(ICoreWebView2Cookie* cookie) {
  LPWSTR name = nullptr;
  LPWSTR value = nullptr;
  LPWSTR domain = nullptr;
  LPWSTR path = nullptr;
  cookie->get_Name(&name);
  cookie->get_Value(&value);
  cookie->get_Domain(&domain);
  cookie->get_Path(&path);

  // The accessors hand back CoTaskMem-allocated wide strings; each has to be
  // taken and freed, in that order.
  auto take = [](LPWSTR raw) -> std::string {
    if (raw == nullptr) return std::string();
    std::string out = Utf8(std::wstring(raw));
    CoTaskMemFree(raw);
    return out;
  };

  const std::string name_text = take(name);
  const std::string value_text = take(value);
  const std::string domain_text = take(domain);
  const std::string path_text = take(path);

  flutter::EncodableMap map;
  map[flutter::EncodableValue("name")] = flutter::EncodableValue(name_text);
  map[flutter::EncodableValue("value")] = flutter::EncodableValue(value_text);
  map[flutter::EncodableValue("domain")] = flutter::EncodableValue(domain_text);
  map[flutter::EncodableValue("path")] = flutter::EncodableValue(path_text);
  return flutter::EncodableValue(map);
}

// What makes two cookies the same one: its domain, its path and its name.
std::string CookieKey(const flutter::EncodableMap& map) {
  auto field = [&map](const char* key) -> std::string {
    auto it = map.find(flutter::EncodableValue(key));
    if (it == map.end()) return std::string();
    const auto* s = std::get_if<std::string>(&it->second);
    return s == nullptr ? std::string() : *s;
  };
  return field("domain") + "|" + field("path") + "|" + field("name");
}

// A cookie is returned once for every URL that matches it, so a harvest taken
// over several URLs has duplicates. Keep the first of each; a later duplicate
// carries the same value, because it is the same cookie.
flutter::EncodableList DedupeCookies(const flutter::EncodableList& cookies) {
  flutter::EncodableList out;
  std::vector<std::string> seen;
  for (const auto& entry : cookies) {
    const auto* map = std::get_if<flutter::EncodableMap>(&entry);
    if (map == nullptr) continue;
    const std::string key = CookieKey(*map);
    if (std::find(seen.begin(), seen.end(), key) != seen.end()) continue;
    seen.push_back(key);
    out.push_back(entry);
  }
  return out;
}

WebViewHost::WebViewHost() = default;

WebViewHost::~WebViewHost() { Shutdown(); }

void WebViewHost::Attach(HWND parent, flutter::BinaryMessenger* messenger) {
  parent_ = parent;
  if (messenger == nullptr) return;

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "campus_atlas/webview",
      &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethod(call, std::move(result)); });
}

void WebViewHost::Shutdown() {
  if (harvest_) {
    // Drop the reply rather than answer a channel that is going away. The
    // callbacks still fire and still finish; they find no result to send.
    harvest_->result.reset();
    harvest_.reset();
  }
  if (controller_) {
    controller_->Close();
    controller_.Reset();
  }
  webview_.Reset();
  environment_.Reset();
  environment_ready_ = false;
  visible_ = false;
  channel_.reset();
}

void WebViewHost::HandleMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());

  auto arg_string = [&](const char* key) -> std::string {
    if (args == nullptr) return std::string();
    auto it = args->find(flutter::EncodableValue(key));
    if (it == args->end()) return std::string();
    const auto* s = std::get_if<std::string>(&it->second);
    return s == nullptr ? std::string() : *s;
  };

  if (method == "open") {
    const std::string url = arg_string("url");
    if (url.empty()) {
      result->Error("bad_args", "open needs a url");
      return;
    }
    EnsureStarted(Utf16(url));
    result->Success();
    return;
  }

  if (method == "show") {
    Show();
    result->Success();
    return;
  }

  if (method == "close") {
    Hide();
    result->Success();
    return;
  }

  if (method == "resize") {
    Resize();
    result->Success();
    return;
  }

  if (method == "eval") {
    const std::string script = arg_string("script");
    if (webview_ == nullptr || script.empty()) {
      result->Error("not_ready", "no page is loaded");
      return;
    }
    // The reply comes back asynchronously on the `scriptResult` channel event;
    // the method result only says the call was accepted.
    RunScript(Utf16(script), 0);
    result->Success();
    return;
  }

  if (method == "cookies") {
    std::vector<std::wstring> urls;
    if (args != nullptr) {
      auto it = args->find(flutter::EncodableValue("urls"));
      if (it != args->end()) {
        const auto* list = std::get_if<flutter::EncodableList>(&it->second);
        if (list != nullptr) {
          for (const auto& entry : *list) {
            const auto* s = std::get_if<std::string>(&entry);
            if (s != nullptr && !s->empty()) urls.push_back(Utf16(*s));
          }
        }
      }
    }
    if (urls.empty()) {
      result->Error("bad_args", "cookies needs at least one url");
      return;
    }
    CollectCookies(urls, std::move(result));
    return;
  }

  result->NotImplemented();
}

void WebViewHost::EnsureStarted(const std::wstring& url) {
  pending_url_ = url;

  if (environment_ready_) {
    Navigate(url);
    Show();
    return;
  }

  // A thread-pool apartment is fine here; COM is already initialised by the
  // Flutter host, and re-initialising would change the apartment of the main
  // thread.
  const std::wstring folder = UserDataFolder();

  HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(
      nullptr, folder.c_str(), nullptr,
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [this](HRESULT env_result, ICoreWebView2Environment* env) -> HRESULT {
            if (FAILED(env_result) || env == nullptr) {
              Report("failed", flutter::EncodableValue(
                                   "CreateCoreWebView2Environment failed"));
              return S_OK;
            }
            environment_ = env;
            environment_ready_ = true;

            environment_->CreateCoreWebView2Controller(
                parent_,
                Callback<
                    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                    [this](HRESULT ctl_result,
                           ICoreWebView2Controller* controller) -> HRESULT {
                      if (FAILED(ctl_result) || controller == nullptr) {
                        Report("failed",
                               flutter::EncodableValue(
                                   "CreateCoreWebView2Controller failed"));
                        return S_OK;
                      }
                      controller_ = controller;
                      controller_->get_CoreWebView2(&webview_);

                      // The controller positions its own child window; it is not
                      // a Flutter platform view and never goes through them.
                      Show();

                      if (!pending_url_.empty()) Navigate(pending_url_);
                      return S_OK;
                    })
                    .Get());
            return S_OK;
          })
          .Get());

  if (FAILED(hr)) {
    Report("failed",
           flutter::EncodableValue("WebView2 runtime is not available"));
  }
}

void WebViewHost::Show() {
  if (controller_ == nullptr) return;
  controller_->put_Bounds(BoundsWithTopStrip(parent_));
  controller_->put_IsVisible(TRUE);
  RaiseWebView();
  visible_ = true;
  Report("shown", flutter::EncodableValue(true));
}

// Puts the WebView's window above the Flutter view.
//
// Both are child windows of the host. WebView2 is created *after* Flutter's view,
// so by default it sits below it: the page really loads (its accessibility tree
// is populated, its own cache fills up) while the screen shows nothing but the
// window background. Raising it is what makes the page visible.
void WebViewHost::RaiseWebView() {
  if (parent_ == nullptr) return;
  HWND webview_window = nullptr;
  EnumChildWindows(parent_, FindWebViewProc,
                   reinterpret_cast<LPARAM>(&webview_window));
  if (webview_window == nullptr) return;
  SetWindowPos(webview_window, HWND_TOP, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
}

void WebViewHost::Hide() {
  if (controller_ == nullptr) return;
  controller_->put_IsVisible(FALSE);
  visible_ = false;
  Report("hidden", flutter::EncodableValue(true));
}

void WebViewHost::Resize() {
  if (controller_ == nullptr || !visible_) return;
  controller_->put_Bounds(BoundsWithTopStrip(parent_));
  RaiseWebView();
}

void WebViewHost::Navigate(const std::wstring& url) {
  if (webview_ == nullptr) return;
  webview_->Navigate(url.c_str());
}

void WebViewHost::RunScript(const std::wstring& script, int request_id) {
  if (webview_ == nullptr) return;
  webview_->ExecuteScript(
      script.c_str(),
      Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
          [this, request_id](HRESULT hr, LPCWSTR json) -> HRESULT {
            if (FAILED(hr) || json == nullptr) {
              // A distinguishing answer, not an empty string: "the script
              // produced nothing" and "the call failed" need different fixes, and
              // an empty value makes them look the same from Dart.
              Report("scriptResult",
                     flutter::EncodableValue(std::string(
                         "{\"error\":\"script call failed\"}")));
              return S_OK;
            }
            Report("scriptResult", flutter::EncodableValue(Utf8(json)));
            return S_OK;
          })
          .Get());
}

void WebViewHost::CollectCookies(
    const std::vector<std::wstring>& urls,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // The cookie manager hangs off `ICoreWebView2_2`, not off the base interface,
  // so it has to be queried for rather than called on `webview_` directly.
  Microsoft::WRL::ComPtr<ICoreWebView2_2> webview2;
  Microsoft::WRL::ComPtr<ICoreWebView2CookieManager> manager;
  if (webview_ == nullptr || FAILED(webview_.As(&webview2)) ||
      webview2 == nullptr || FAILED(webview2->get_CookieManager(&manager)) ||
      manager == nullptr) {
    result->Error("no_cookie_manager", "the cookie manager is unavailable");
    return;
  }

  auto harvest = std::make_shared<CookieHarvest>();
  harvest->pending = urls.size();
  harvest->result = std::move(result);
  harvest_ = harvest;

  // One request per URL, all in flight together; the last one to answer replies.
  // The callbacks capture the shared state rather than `this`, so a torn-down
  // host cannot be reached through them.
  for (const auto& url : urls) {
    manager->GetCookies(
        url.c_str(),
        Callback<ICoreWebView2GetCookiesCompletedHandler>(
            [harvest](HRESULT hr, ICoreWebView2CookieList* list) -> HRESULT {
              if (SUCCEEDED(hr) && list != nullptr) {
                UINT count = 0;
                list->get_Count(&count);
                for (UINT i = 0; i < count; ++i) {
                  Microsoft::WRL::ComPtr<ICoreWebView2Cookie> cookie;
                  if (FAILED(list->GetValueAtIndex(i, &cookie)) ||
                      cookie == nullptr) {
                    continue;
                  }
                  harvest->cookies.push_back(CookieToValue(cookie.Get()));
                }
              }
              if (harvest->pending > 0) harvest->pending--;
              if (harvest->pending == 0 && harvest->result != nullptr) {
                harvest->result->Success(
                    flutter::EncodableValue(DedupeCookies(harvest->cookies)));
              }
              return S_OK;
            })
            .Get());
  }
}

void WebViewHost::Report(const std::string& method,
                         flutter::EncodableValue value) {
  if (!channel_) return;
  channel_->InvokeMethod(method,
                         std::make_unique<flutter::EncodableValue>(value));
}
