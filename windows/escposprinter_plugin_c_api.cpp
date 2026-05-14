#include "include/escposprinter/escposprinter_plugin_c_api.h"

#include "escposprinter_plugin.h"

#include <flutter/plugin_registrar_windows.h>

void EscposprinterPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  escposprinter::EscposprinterPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
