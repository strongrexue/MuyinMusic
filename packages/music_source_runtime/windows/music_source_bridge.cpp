#include "music_source_bridge.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iterator>
#include <memory>
#include <mutex>
#include <random>
#include <sstream>
#include <thread>
#include <utility>
#include <vector>

#include <windows.h>

#include <flutter/method_call.h>
#include <flutter/standard_method_codec.h>

#include "music_source_crypto.h"
#include "quickjs.h"

namespace muyin {
namespace {

using EncodableValue = flutter::EncodableValue;
using EncodableMap = flutter::EncodableMap;
using EncodableList = flutter::EncodableList;

constexpr size_t kMaxScriptBytes = 2 * 1024 * 1024;

// ---------------- JSON helpers ----------------

std::string JsonEscape(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 8);
  static const char kHex[] = "0123456789abcdef";
  for (unsigned char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          out += "\\u00";
          out.push_back(kHex[(c >> 4) & 0xf]);
          out.push_back(kHex[c & 0xf]);
        } else {
          out.push_back(static_cast<char>(c));
        }
    }
  }
  return out;
}

std::string SerializeJson(const EncodableValue& v);

std::string SerializeMap(const EncodableMap& map) {
  std::string out = "{";
  bool first = true;
  for (const auto& kv : map) {
    if (!first) out += ',';
    first = false;
    std::string key;
    if (std::holds_alternative<std::string>(kv.first)) {
      key = std::get<std::string>(kv.first);
    }
    out += '"' + JsonEscape(key) + "\":" + SerializeJson(kv.second);
  }
  out += '}';
  return out;
}

std::string SerializeJson(const EncodableValue& v) {
  if (v.IsNull()) return "null";
  if (std::holds_alternative<bool>(v)) {
    return std::get<bool>(v) ? "true" : "false";
  }
  if (std::holds_alternative<int32_t>(v)) {
    return std::to_string(std::get<int32_t>(v));
  }
  if (std::holds_alternative<int64_t>(v)) {
    return std::to_string(std::get<int64_t>(v));
  }
  if (std::holds_alternative<double>(v)) {
    std::ostringstream os;
    os << std::setprecision(15) << std::get<double>(v);
    return os.str();
  }
  if (std::holds_alternative<std::string>(v)) {
    return '"' + JsonEscape(std::get<std::string>(v)) + '"';
  }
  if (std::holds_alternative<EncodableList>(v)) {
    std::string out = "[";
    const auto& list = std::get<EncodableList>(v);
    for (size_t i = 0; i < list.size(); ++i) {
      if (i) out += ',';
      out += SerializeJson(list[i]);
    }
    out += ']';
    return out;
  }
  if (std::holds_alternative<EncodableMap>(v)) {
    return SerializeMap(std::get<EncodableMap>(v));
  }
  return "null";
}

std::string MapString(const EncodableMap& map, const std::string& key) {
  auto it = map.find(EncodableValue(key));
  if (it != map.end() && std::holds_alternative<std::string>(it->second)) {
    return std::get<std::string>(it->second);
  }
  return std::string();
}

EncodableMap AsMap(const EncodableValue* args) {
  if (args && std::holds_alternative<EncodableMap>(*args)) {
    return std::get<EncodableMap>(*args);
  }
  return EncodableMap();
}

std::string Trim(const std::string& s) {
  size_t b = 0, e = s.size();
  while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\n' || s[b] == '\r')) b++;
  while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\n' || s[e - 1] == '\r')) e--;
  return s.substr(b, e - b);
}

std::string ToLower(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) {
    return static_cast<char>(::tolower(c));
  });
  return s;
}

std::string NewUuid() {
  static std::mt19937_64 rng(std::random_device{}());
  const uint64_t a = rng();
  const uint64_t b = rng();
  char buf[64];
  std::snprintf(buf, sizeof(buf),
                "%08x-%04x-%04x-%04x-%012llx",
                static_cast<unsigned>(a & 0xffffffffu),
                static_cast<unsigned>((a >> 32) & 0xffffu),
                static_cast<unsigned>((a >> 48) & 0xffffu),
                static_cast<unsigned>(b & 0xffffu),
                static_cast<unsigned long long>((b >> 16) & 0xffffffffffffULL));
  return std::string(buf);
}

}  // namespace

// ===========================================================================
// MusicSourceBridge
// ===========================================================================

MusicSourceBridge::MusicSourceBridge(
    flutter::BinaryMessenger* messenger,
    const std::string& channel_name,
    std::function<void(std::function<void()>)> ui_task)
    : channel_(messenger, channel_name,
               &flutter::StandardMethodCodec::GetInstance()),
      ui_task_(std::move(ui_task)) {
  channel_.SetMethodCallHandler(
      [this](const MethodCall& call, std::unique_ptr<MethodResult> result) {
        HandleMethodCall(call, std::move(result));
      });
}

MusicSourceBridge::~MusicSourceBridge() {
  DisposeRuntime("音源运行时已关闭");
  channel_.SetMethodCallHandler(nullptr);
}

// ---------------- MethodChannel dispatch ----------------

void MusicSourceBridge::HandleMethodCall(const MethodCall& call,
                                         std::unique_ptr<MethodResult> result) {
  const std::string& method = call.method_name();
  if (method == "load") {
    HandleLoad(call.arguments(), std::move(result));
  } else if (method == "resolve") {
    HandleResolve(call.arguments(), std::move(result));
  } else if (method == "httpResponse") {
    HandleHttpResponse(call.arguments(), std::move(result));
  } else if (method == "dispose") {
    HandleDispose(std::move(result));
  } else {
    result->NotImplemented();
  }
}

void MusicSourceBridge::HandleLoad(const EncodableValue* args,
                                   std::unique_ptr<MethodResult> result) {
  EncodableMap map = AsMap(args);
  const std::string script = MapString(map, "script");
  if (script.empty() || script.size() > kMaxScriptBytes) {
    result->Error("INVALID_SCRIPT", "音源脚本为空或超过 2 MB");
    return;
  }

  DisposeRuntime("音源已切换");

  {
    std::lock_guard<std::mutex> lock(mutex_);
    pending_load_ = std::move(result);
    script_stop_ = false;
    disposed_ = false;
  }

  EncodableMap args_copy = map;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    script_queue_.push([this, args_copy, script]() {
      CreateRuntime(args_copy, script);
    });
  }
  script_thread_ = std::thread([this]() { ScriptThreadMain(); });
  cv_.notify_one();
}

void MusicSourceBridge::HandleResolve(const EncodableValue* args,
                                      std::unique_ptr<MethodResult> result) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!initialized_ || context_ == nullptr || script_stop_) {
      result->Error("NO_SOURCE", "请先导入并启用音源");
      return;
    }
  }

  const std::string request_id = NewUuid();
  EncodableMap payload = AsMap(args);
  payload[EncodableValue("requestId")] = EncodableValue(request_id);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    pending_resolves_[request_id] = std::move(result);
  }
  PostToScript("resolve", SerializeJson(EncodableValue(payload)));
}

void MusicSourceBridge::HandleHttpResponse(const EncodableValue* args,
                                           std::unique_ptr<MethodResult> result) {
  EncodableMap payload = AsMap(args);
  PostToScript("httpResponse", SerializeJson(EncodableValue(payload)));
  result->Success();
}

void MusicSourceBridge::HandleDispose(std::unique_ptr<MethodResult> result) {
  DisposeRuntime("音源运行时已关闭");
  result->Success();
}

// ---------------- JS runtime (script thread) ----------------

void MusicSourceBridge::ScriptThreadMain() {
  for (;;) {
    std::function<void()> task;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      cv_.wait(lock, [this]() { return script_stop_ || !script_queue_.empty(); });
      if (script_queue_.empty()) {
        if (script_stop_) break;
        continue;
      }
      task = std::move(script_queue_.front());
      script_queue_.pop();
    }
    task();
  }

  // Tear down JS on the same thread that created it.
  JSContext* ctx = context_;
  JSRuntime* rt = runtime_;
  if (ctx) JS_FreeContext(ctx);
  if (rt) JS_FreeRuntime(rt);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    context_ = nullptr;
    runtime_ = nullptr;
    initialized_ = false;
  }
}

void MusicSourceBridge::CreateRuntime(const EncodableMap& args,
                                      const std::string& script) {
  JSRuntime* rt = JS_NewRuntime();
  if (!rt) {
    FailLoad("无法创建 JS 运行时");
    return;
  }
  JSContext* ctx = JS_NewContext(rt);
  if (!ctx) {
    JS_FreeRuntime(rt);
    FailLoad("无法创建 JS 上下文");
    return;
  }
  JS_SetContextOpaque(ctx, this);

  {
    std::lock_guard<std::mutex> lock(mutex_);
    runtime_ = rt;
    context_ = ctx;
  }

  bool ok = true;
  std::string error;

  auto eval = [&](const std::string& code, const char* filename) {
    JSValue v = JS_Eval(ctx, code.data(), code.size(), filename,
                        JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(v)) {
      JSValue e = JS_GetException(ctx);
      error = ToUtf8(ctx, e);
      JS_FreeValue(ctx, e);
      ok = false;
    }
    JS_FreeValue(ctx, v);
  };

  InstallNativeFunctions();

  const std::string preload = ReadFileUtf8(ResourceDir() + "music_source_preload.js");
  if (preload.empty()) {
    FailLoad("无法读取 music_source_preload.js");
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      context_ = nullptr;
      runtime_ = nullptr;
    }
    return;
  }
  eval(preload, "music_source_preload.js");

  if (ok) {
    EncodableMap metadata;
    const char* fields[] = {"id", "name", "description", "author",
                            "homepage", "version", "sourceKey"};
    for (const char* f : fields) {
      metadata[EncodableValue(std::string(f))] = EncodableValue(MapString(args, f));
    }
    metadata[EncodableValue("rawScript")] = EncodableValue(script);
    const std::string metadata_json = SerializeJson(EncodableValue(metadata));

    JSValue global = JS_GetGlobalObject(ctx);
    JSValue setup = JS_GetPropertyStr(ctx, global, "music_source_setup");
    if (JS_IsFunction(ctx, setup)) {
      JSValue arg = JS_NewStringLen(ctx, metadata_json.data(), metadata_json.size());
      JSValue argv[1] = {arg};
      JSValue ret = JS_Call(ctx, setup, global, 1, argv);
      if (JS_IsException(ret)) {
        JSValue e = JS_GetException(ctx);
        error = ToUtf8(ctx, e);
        JS_FreeValue(ctx, e);
        ok = false;
      }
      JS_FreeValue(ctx, ret);
      JS_FreeValue(ctx, arg);
    } else {
      error = "music_source_setup 未定义";
      ok = false;
    }
    JS_FreeValue(ctx, setup);
    JS_FreeValue(ctx, global);
  }

  if (ok) {
    eval(script, "music_source_script.js");
  }
  DrainMicrotasks();

  if (!ok) {
    FailLoad(error.empty() ? "音源初始化失败" : error);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      context_ = nullptr;
      runtime_ = nullptr;
    }
    return;
  }

  {
    std::lock_guard<std::mutex> lock(mutex_);
    initialized_ = true;
  }
}

void MusicSourceBridge::InstallNativeFunctions() {
  JSContext* ctx = context_;
  if (!ctx) return;
  JSValue global = JS_GetGlobalObject(ctx);
  struct Fn { const char* name; JSCFunction* fn; int arity; };
  const Fn fns[] = {
      {"__music_source_native_call__", JsNativeCall, 2},
      {"__music_source_md5__", JsMd5, 1},
      {"__music_source_bytes_to_b64__", JsBytesToBase64, 1},
      {"__music_source_b64_to_bytes__", JsBase64ToBytes, 1},
      {"__music_source_aes_encrypt__", JsAesEncrypt, 4},
      {"__music_source_rsa_encrypt__", JsRsaEncrypt, 3},
      {"__music_source_set_timeout__", JsSetTimeout, 2},
      {"__music_source_clear_timeout__", JsClearTimeout, 1},
  };
  for (const Fn& f : fns) {
    JS_SetPropertyStr(ctx, global, f.name,
                      JS_NewCFunction(ctx, f.fn, f.name, f.arity));
  }
  JS_FreeValue(ctx, global);
}

void MusicSourceBridge::CallJs(const std::string& action,
                               const std::string& data) {
  JSContext* ctx = context_;
  if (!ctx) return;
  JSValue global = JS_GetGlobalObject(ctx);
  JSValue fn = JS_GetPropertyStr(ctx, global, "__music_source_handle__");
  if (JS_IsFunction(ctx, fn)) {
    JSValue a0 = JS_NewStringLen(ctx, action.data(), action.size());
    JSValue a1 = JS_NewStringLen(ctx, data.data(), data.size());
    JSValue argv[2] = {a0, a1};
    JSValue ret = JS_Call(ctx, fn, global, 2, argv);
    if (JS_IsException(ret)) {
      JSValue e = JS_GetException(ctx);
      SendLog("error", ToUtf8(ctx, e));
      JS_FreeValue(ctx, e);
    }
    JS_FreeValue(ctx, ret);
    JS_FreeValue(ctx, a0);
    JS_FreeValue(ctx, a1);
  }
  JS_FreeValue(ctx, fn);
  JS_FreeValue(ctx, global);
  DrainMicrotasks();
}

void MusicSourceBridge::DrainMicrotasks() {
  JSRuntime* rt = runtime_;
  if (!rt) return;
  JSContext* ctx = nullptr;
  while (JS_ExecutePendingJob(rt, &ctx) > 0) {
  }
}

// ---------------- JS -> native action dispatch ----------------

void MusicSourceBridge::HandleScriptAction(const std::string& action,
                                           const std::string& data_json) {
  EncodableValue parsed = ParseJson(data_json);
  EncodableMap payload;
  if (std::holds_alternative<EncodableMap>(parsed)) {
    payload = std::get<EncodableMap>(parsed);
  }

  if (action == "init") {
    bool status = false;
    auto it = payload.find(EncodableValue("status"));
    if (it != payload.end() && std::holds_alternative<bool>(it->second)) {
      status = std::get<bool>(it->second);
    }
    if (!status) {
      const std::string err = MapString(payload, "error");
      FailLoad(err.empty() ? "音源初始化失败" : err);
      return;
    }
    auto info_it = payload.find(EncodableValue("info"));
    CompleteLoad(info_it != payload.end() ? info_it->second : EncodableValue());
  } else if (action == "resolveResult") {
    CompleteResolve(payload);
  } else if (action == "httpRequest" || action == "httpCancel" ||
             action == "updateAlert" || action == "log") {
    SendEvent(action, EncodableValue(payload));
  } else {
    SendLog("warn", "Unknown source action: " + action);
  }
}

void MusicSourceBridge::CompleteResolve(const EncodableMap& payload) {
  const std::string request_id = MapString(payload, "requestId");
  std::unique_ptr<MethodResult> result;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = pending_resolves_.find(request_id);
    if (it == pending_resolves_.end()) return;
    result = std::move(it->second);
    pending_resolves_.erase(it);
  }

  bool status = false;
  auto sit = payload.find(EncodableValue("status"));
  if (sit != payload.end() && std::holds_alternative<bool>(sit->second)) {
    status = std::get<bool>(sit->second);
  }
  if (!status) {
    const std::string err = MapString(payload, "error");
    PostError(std::move(result), "RESOLVE_FAILED",
              err.empty() ? "音源解析失败" : err);
    return;
  }

  EncodableMap response;
  response[EncodableValue("url")] = EncodableValue(MapString(payload, "url"));
  auto fit = payload.find(EncodableValue("fileName"));
  if (fit != payload.end() && !fit->second.IsNull() &&
      std::holds_alternative<std::string>(fit->second)) {
    const std::string file_name = Trim(std::get<std::string>(fit->second));
    const std::string lower = ToLower(file_name);
    if (!file_name.empty() && lower != "null" && lower != "undefined") {
      response[EncodableValue("fileName")] = EncodableValue(file_name);
    }
  }
  PostSuccess(std::move(result), EncodableValue(response));
}

void MusicSourceBridge::CompleteLoad(const EncodableValue& info) {
  std::unique_ptr<MethodResult> result;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    result = std::move(pending_load_);
    pending_load_.reset();
  }
  if (result) PostSuccess(std::move(result), info);
}

void MusicSourceBridge::FailLoad(const std::string& message) {
  std::unique_ptr<MethodResult> result;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    result = std::move(pending_load_);
    pending_load_.reset();
    initialized_ = false;
  }
  if (result) PostError(std::move(result), "LOAD_FAILED", message);
}

// ---------------- 8 native globals ----------------

JSValue MusicSourceBridge::JsNativeCall(JSContext* ctx, JSValue self,
                                        int argc, JSValue* argv) {
  (void)self;
  auto* bridge = static_cast<MusicSourceBridge*>(JS_GetContextOpaque(ctx));
  if (bridge && argc >= 2) {
    bridge->HandleScriptAction(JsArgString(ctx, argv[0]),
                               JsArgString(ctx, argv[1]));
  }
  return JS_NULL;
}

JSValue MusicSourceBridge::JsMd5(JSContext* ctx, JSValue self,
                                 int argc, JSValue* argv) {
  (void)self;
  const std::string s = argc > 0 ? JsArgString(ctx, argv[0]) : std::string();
  return JS_NewString(ctx, ms_crypto::Md5Hex(s).c_str());
}

JSValue MusicSourceBridge::JsBytesToBase64(JSContext* ctx, JSValue self,
                                           int argc, JSValue* argv) {
  (void)self;
  const std::string s = argc > 0 ? JsArgString(ctx, argv[0]) : std::string();
  std::vector<uint8_t> bytes;
  // Input is a JSON array string like "[1,2,3]"; QuickJS parses it for us.
  JSValue arr = JS_ParseJSON(ctx, s.data(), s.size(), "<bytes>");
  if (!JS_IsException(arr) && JS_IsArray(arr)) {
    int64_t len = 0;
    if (JS_GetLength(ctx, arr, &len) == 0) {
      for (int64_t i = 0; i < len; ++i) {
        JSValue item = JS_GetPropertyUint32(ctx, arr, static_cast<uint32_t>(i));
        int32_t n = 0;
        if (JS_ToInt32(ctx, &n, item) == 0) {
          bytes.push_back(static_cast<uint8_t>(n));
        }
        JS_FreeValue(ctx, item);
      }
    }
  } else if (JS_IsException(arr)) {
    JS_FreeValue(ctx, JS_GetException(ctx));
  }
  JS_FreeValue(ctx, arr);
  return JS_NewString(ctx, ms_crypto::Base64Encode(bytes).c_str());
}

JSValue MusicSourceBridge::JsBase64ToBytes(JSContext* ctx, JSValue self,
                                           int argc, JSValue* argv) {
  (void)self;
  const std::string s = argc > 0 ? JsArgString(ctx, argv[0]) : std::string();
  const std::vector<uint8_t> bytes = ms_crypto::Base64Decode(s);
  // Contract (Android MusicSourceCrypto.java:41 / iOS Crypto.swift:77-84):
  // return a JSON array STRING like "[1,2,3]", not a JS Array. preload.js
  // consumes it via `new Uint8Array(JSON.parse(base64ToBytes(...)))`, so
  // returning a real Array makes JSON.parse stringify to "1,2,3" and throw.
  std::string json = "[";
  for (size_t i = 0; i < bytes.size(); ++i) {
    if (i) json += ",";
    json += std::to_string(static_cast<int>(bytes[i]));
  }
  json += "]";
  return JS_NewString(ctx, json.c_str());
}

JSValue MusicSourceBridge::JsAesEncrypt(JSContext* ctx, JSValue self,
                                        int argc, JSValue* argv) {
  (void)self;
  std::string a, k, iv, t;
  if (argc > 0) a = JsArgString(ctx, argv[0]);
  if (argc > 1) k = JsArgString(ctx, argv[1]);
  if (argc > 2) iv = JsArgString(ctx, argv[2]);
  if (argc > 3) t = JsArgString(ctx, argv[3]);
  return JS_NewString(ctx, ms_crypto::AesEncryptBase64(a, k, iv, t).c_str());
}

JSValue MusicSourceBridge::JsRsaEncrypt(JSContext* ctx, JSValue self,
                                        int argc, JSValue* argv) {
  (void)self;
  std::string a, key, padding;
  if (argc > 0) a = JsArgString(ctx, argv[0]);
  if (argc > 1) key = JsArgString(ctx, argv[1]);
  if (argc > 2) padding = JsArgString(ctx, argv[2]);
  return JS_NewString(ctx, ms_crypto::RsaEncryptBase64(a, key, padding).c_str());
}

JSValue MusicSourceBridge::JsSetTimeout(JSContext* ctx, JSValue self,
                                        int argc, JSValue* argv) {
  (void)self;
  auto* bridge = static_cast<MusicSourceBridge*>(JS_GetContextOpaque(ctx));
  if (bridge && argc >= 2) {
    int32_t id = 0;
    double delay = 0;
    JS_ToInt32(ctx, &id, argv[0]);
    JS_ToFloat64(ctx, &delay, argv[1]);
    if (delay < 0) delay = 0;
    if (delay > 60000) delay = 60000;
    auto cancel = std::make_shared<std::atomic<bool>>(false);
    {
      std::lock_guard<std::mutex> lock(bridge->mutex_);
      bridge->timer_cancel_[id] = cancel;
      bridge->timer_alive_.push_back(cancel);
    }
    std::thread([bridge, id, cancel, delay]() {
      std::this_thread::sleep_for(
          std::chrono::milliseconds(static_cast<int64_t>(delay)));
      if (cancel->load()) return;
      {
        std::lock_guard<std::mutex> lock(bridge->mutex_);
        auto it = bridge->timer_cancel_.find(id);
        if (it != bridge->timer_cancel_.end() && it->second == cancel) {
          bridge->timer_cancel_.erase(it);
        }
      }
      bridge->PostToScript("timeout", std::to_string(id));
    }).detach();
  }
  return JS_NULL;
}

JSValue MusicSourceBridge::JsClearTimeout(JSContext* ctx, JSValue self,
                                          int argc, JSValue* argv) {
  (void)self;
  auto* bridge = static_cast<MusicSourceBridge*>(JS_GetContextOpaque(ctx));
  if (bridge && argc >= 1) {
    int32_t id = 0;
    JS_ToInt32(ctx, &id, argv[0]);
    std::lock_guard<std::mutex> lock(bridge->mutex_);
    auto it = bridge->timer_cancel_.find(id);
    if (it != bridge->timer_cancel_.end()) {
      it->second->store(true);
      bridge->timer_cancel_.erase(it);
    }
  }
  return JS_NULL;
}

// ---------------- Queue helpers ----------------

void MusicSourceBridge::PostToScript(const std::string& action,
                                     const std::string& data) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (script_stop_ || script_thread_.get_id() == std::thread::id()) return;
    script_queue_.push([this, action, data]() { CallJs(action, data); });
  }
  cv_.notify_one();
}

void MusicSourceBridge::PostToUi(std::function<void()> task) {
  if (ui_task_) {
    ui_task_(std::move(task));
  } else {
    task();
  }
}

// ---------------- Main-thread result/event helpers ----------------

void MusicSourceBridge::PostSuccess(std::unique_ptr<MethodResult> result,
                                    const EncodableValue& value) {
  if (!result) return;
  std::shared_ptr<MethodResult> shared_result = std::move(result);
  PostToUi([shared_result, value]() {
    shared_result->Success(value);
  });
}

void MusicSourceBridge::PostError(std::unique_ptr<MethodResult> result,
                                  const std::string& code,
                                  const std::string& message) {
  if (!result) return;
  std::shared_ptr<MethodResult> shared_result = std::move(result);
  PostToUi([shared_result, code, message]() {
    shared_result->Error(code, message);
  });
}

void MusicSourceBridge::SendEvent(const std::string& type,
                                  const EncodableValue& payload) {
  EncodableMap event;
  if (std::holds_alternative<EncodableMap>(payload)) {
    event = std::get<EncodableMap>(payload);
  }

  if (type == "log") {
    auto it = event.find(EncodableValue("message"));
    if (it != event.end() && std::holds_alternative<std::string>(it->second)) {
      std::string message = std::get<std::string>(it->second);
      if (message.size() > 2000) message = message.substr(0, 2000);
      event[EncodableValue("message")] = EncodableValue(message);
    }
  }

  event[EncodableValue("type")] = EncodableValue(type);
  PostToUi([this, event]() {
    auto args = std::make_unique<EncodableValue>(event);
    channel_.InvokeMethod("event", std::move(args));
  });
}

void MusicSourceBridge::SendLog(const std::string& level,
                                const std::string& message) {
  EncodableMap payload;
  payload[EncodableValue("level")] = EncodableValue(level);
  payload[EncodableValue("message")] =
      EncodableValue(message.size() > 2000 ? message.substr(0, 2000) : message);
  SendEvent("log", EncodableValue(payload));
}

void MusicSourceBridge::DisposeRuntime(const std::string& reason) {
  std::lock_guard<std::mutex> dispose_lock(dispose_mutex_);

  // Fail a pending load.
  {
    std::unique_ptr<MethodResult> load;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      load = std::move(pending_load_);
      pending_load_.reset();
    }
    if (load) PostError(std::move(load), "LOAD_FAILED", reason);
  }

  // Fail all pending resolves.
  {
    std::unordered_map<std::string, std::unique_ptr<MethodResult>> resolves;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      resolves.swap(pending_resolves_);
    }
    for (auto& kv : resolves) {
      PostError(std::move(kv.second), "RUNTIME_DISPOSED", reason);
    }
  }

  // Cancel active timers.
  {
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto& kv : timer_cancel_) kv.second->store(true);
    timer_cancel_.clear();
    timer_alive_.clear();
  }

  // Stop the script thread; it frees JS runtime/context before exiting.
  std::thread to_join;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    script_stop_ = true;
    initialized_ = false;
    if (script_thread_.joinable()) {
      to_join = std::move(script_thread_);
    }
  }
  cv_.notify_all();
  if (to_join.joinable()) to_join.join();
}

// ---------------- JSON bridges ----------------

EncodableValue MusicSourceBridge::ParseJson(const std::string& json) {
  JSContext* ctx = context_;
  if (!ctx || json.empty()) return EncodableValue();

  JSValue root = JS_ParseJSON(ctx, json.data(), json.size(), "<json>");
  if (JS_IsException(root)) {
    JS_FreeValue(ctx, JS_GetException(ctx));
    return EncodableValue();
  }

  std::function<EncodableValue(JSValue)> convert = [&](JSValue v) -> EncodableValue {
    if (JS_IsNull(v) || JS_IsUndefined(v)) return EncodableValue();
    if (JS_IsBool(v)) return EncodableValue(JS_ToBool(ctx, v) > 0);
    if (JS_IsNumber(v)) {
      double d = 0;
      JS_ToFloat64(ctx, &d, v);
      return EncodableValue(d);
    }
    if (JS_IsString(v)) return EncodableValue(ToUtf8(ctx, v));
    if (JS_IsArray(v)) {
      EncodableList list;
      int64_t len = 0;
      if (JS_GetLength(ctx, v, &len) == 0) {
        for (int64_t i = 0; i < len; ++i) {
          JSValue item = JS_GetPropertyUint32(ctx, v, static_cast<uint32_t>(i));
          list.push_back(convert(item));
          JS_FreeValue(ctx, item);
        }
      }
      return EncodableValue(list);
    }
    if (JS_VALUE_GET_TAG(v) == JS_TAG_OBJECT) {
      EncodableMap map;
      JSPropertyEnum* props = nullptr;
      uint32_t count = 0;
      if (JS_GetOwnPropertyNames(ctx, &props, &count, v,
                                 JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) == 0) {
        for (uint32_t i = 0; i < count; ++i) {
          JSValue key = JS_AtomToString(ctx, props[i].atom);
          JSValue val = JS_GetProperty(ctx, v, props[i].atom);
          map[EncodableValue(ToUtf8(ctx, key))] = convert(val);
          JS_FreeValue(ctx, key);
          JS_FreeValue(ctx, val);
        }
        JS_FreePropertyEnum(ctx, props, static_cast<int>(count));
      }
      return EncodableValue(map);
    }
    return EncodableValue();
  };

  EncodableValue result = convert(root);
  JS_FreeValue(ctx, root);
  return result;
}

std::string MusicSourceBridge::ToUtf8(JSContext* ctx, JSValue value) {
  size_t len = 0;
  const char* s = JS_ToCStringLen(ctx, &len, value);
  if (!s) return std::string();
  std::string out(s, len);
  JS_FreeCString(ctx, s);
  return out;
}

std::string MusicSourceBridge::JsArgString(JSContext* ctx, JSValue value) {
  return ToUtf8(ctx, value);
}

std::string MusicSourceBridge::ReadFileUtf8(const std::string& path) {
  std::ifstream file(path, std::ios::binary);
  if (!file) return std::string();
  return std::string(std::istreambuf_iterator<char>(file),
                     std::istreambuf_iterator<char>());
}

std::string MusicSourceBridge::ResourceDir() {
  char path[MAX_PATH] = {0};
  HMODULE module = nullptr;
  GetModuleHandleExA(
      GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
          GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
      reinterpret_cast<LPCSTR>(&ResourceDir), &module);
  DWORD n = module ? GetModuleFileNameA(module, path, MAX_PATH) : 0;
  std::string full(path, n);
  const size_t slash = full.find_last_of("\\/");
  return slash == std::string::npos ? std::string()
                                    : full.substr(0, slash + 1);
}

}  // namespace muyin
