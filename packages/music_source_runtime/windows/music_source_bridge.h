#ifndef MUSIC_SOURCE_BRIDGE_H_
#define MUSIC_SOURCE_BRIDGE_H_

#include <atomic>
#include <condition_variable>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>

struct JSContext;
struct JSRuntime;
struct JSValue;

namespace muyin {

// A single JS runtime bound to one MethodChannel. The plugin creates two
// instances (main + update check), mirroring the Android/iOS plugins.
class MusicSourceBridge {
 public:
  using MethodResult = flutter::MethodResult<flutter::EncodableValue>;
  using MethodCall = flutter::MethodCall<flutter::EncodableValue>;
  using EncodableValue = flutter::EncodableValue;
  using EncodableMap = flutter::EncodableMap;

  // |ui_task| posts a closure to Flutter's platform/UI thread. It must remain
  // valid for the lifetime of this bridge. If it is empty, callbacks are
  // invoked on the calling thread (the engine messenger is thread-safe).
  MusicSourceBridge(flutter::BinaryMessenger* messenger,
                    const std::string& channel_name,
                    std::function<void(std::function<void()>)> ui_task);
  ~MusicSourceBridge();

  MusicSourceBridge(const MusicSourceBridge&) = delete;
  MusicSourceBridge& operator=(const MusicSourceBridge&) = delete;

 private:
  void HandleMethodCall(const MethodCall& call,
                        std::unique_ptr<MethodResult> result);

  void HandleLoad(const EncodableValue* args, std::unique_ptr<MethodResult> result);
  void HandleResolve(const EncodableValue* args, std::unique_ptr<MethodResult> result);
  void HandleHttpResponse(const EncodableValue* args,
                          std::unique_ptr<MethodResult> result);
  void HandleDispose(std::unique_ptr<MethodResult> result);

  // ---- JS side (runs on script_thread_) ----
  void CreateRuntime(const EncodableMap& args, const std::string& script);
  void CallJs(const std::string& action, const std::string& data);
  void DrainMicrotasks();
  void InstallNativeFunctions();
  void HandleScriptAction(const std::string& action, const std::string& data_json);
  void CompleteResolve(const EncodableMap& payload);
  void CompleteLoad(const EncodableValue& info);
  void FailLoad(const std::string& message);

  // JSValueConst is `#define JSValueConst JSValue` in this QuickJS build.
  // Use JSValue directly to keep this header independent of quickjs.h.
  static JSValue JsNativeCall(JSContext* ctx, JSValue self, int argc,
                              JSValue* argv);
  static JSValue JsMd5(JSContext* ctx, JSValue self, int argc, JSValue* argv);
  static JSValue JsBytesToBase64(JSContext* ctx, JSValue self, int argc,
                                 JSValue* argv);
  static JSValue JsBase64ToBytes(JSContext* ctx, JSValue self, int argc,
                                 JSValue* argv);
  static JSValue JsAesEncrypt(JSContext* ctx, JSValue self, int argc,
                              JSValue* argv);
  static JSValue JsRsaEncrypt(JSContext* ctx, JSValue self, int argc,
                              JSValue* argv);
  static JSValue JsSetTimeout(JSContext* ctx, JSValue self, int argc,
                              JSValue* argv);
  static JSValue JsClearTimeout(JSContext* ctx, JSValue self, int argc,
                                JSValue* argv);

  // ---- Queue helpers ----
  void PostToScript(const std::string& action, const std::string& data);
  void ScriptThreadMain();
  void PostToUi(std::function<void()> task);

  // ---- Main-thread result/event helpers ----
  void PostSuccess(std::unique_ptr<MethodResult> result, const EncodableValue& value);
  void PostError(std::unique_ptr<MethodResult> result, const std::string& code,
                 const std::string& message);
  void SendEvent(const std::string& type, const EncodableValue& payload);
  void SendLog(const std::string& level, const std::string& message);

  void DisposeRuntime(const std::string& reason);

  // ---- JSON bridges ----
  EncodableValue ParseJson(const std::string& json);
  static std::string ToUtf8(JSContext* ctx, JSValue value);
  static std::string JsArgString(JSContext* ctx, JSValue value);

  static std::string ReadFileUtf8(const std::string& path);
  static std::string ResourceDir();

  flutter::MethodChannel<EncodableValue> channel_;
  std::function<void(std::function<void()>)> ui_task_;

  // Guards the queue, JS runtime pointers and result/pending maps.
  std::mutex mutex_;
  std::condition_variable cv_;
  std::queue<std::function<void()>> script_queue_;
  bool script_stop_ = false;
  JSRuntime* runtime_ = nullptr;
  JSContext* context_ = nullptr;

  std::unique_ptr<MethodResult> pending_load_;
  std::unordered_map<std::string, std::unique_ptr<MethodResult>> pending_resolves_;
  // One cancel flag per active JS setTimeout id. Timer threads are detached;
  // DisposeRuntime sets every flag so they no longer touch the bridge.
  std::unordered_map<int, std::shared_ptr<std::atomic<bool>>> timer_cancel_;
  std::vector<std::shared_ptr<std::atomic<bool>>> timer_alive_;

  std::thread script_thread_;
  bool initialized_ = false;
  std::atomic<bool> disposed_{false};
  std::mutex dispose_mutex_;  // serializes DisposeRuntime calls
};

}  // namespace muyin

#endif  // MUSIC_SOURCE_BRIDGE_H_
