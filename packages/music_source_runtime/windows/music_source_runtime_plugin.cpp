#include "include/music_source_runtime/music_source_runtime_plugin.h"

#include <memory>
#include <string>

#include <flutter/plugin_registrar_windows.h>

#include "music_source_bridge.h"

namespace panghu {

class MusicSourceRuntimePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
    auto plugin = std::make_unique<MusicSourceRuntimePlugin>();

    // Main runtime and the update-check runtime are two independent bridges,
    // each with its own JS runtime, mirroring the Android/iOS plugins.
    plugin->main_bridge_ = std::make_unique<MusicSourceBridge>(
        registrar->messenger(), "panghu_music/music_source_runtime",
        nullptr);
    plugin->update_bridge_ = std::make_unique<MusicSourceBridge>(
        registrar->messenger(), "panghu_music/music_source_update_runtime",
        nullptr);

    registrar->AddPlugin(std::move(plugin));
  }

  MusicSourceRuntimePlugin() = default;

  ~MusicSourceRuntimePlugin() override = default;

 private:
  std::unique_ptr<MusicSourceBridge> main_bridge_;
  std::unique_ptr<MusicSourceBridge> update_bridge_;
};

}  // namespace panghu

void MusicSourceRuntimePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  panghu::MusicSourceRuntimePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
