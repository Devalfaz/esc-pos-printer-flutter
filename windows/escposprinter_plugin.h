#ifndef FLUTTER_PLUGIN_ESCPOSPRINTER_PLUGIN_H_
#define FLUTTER_PLUGIN_ESCPOSPRINTER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <string>
#include <vector>

namespace escposprinter {

class EscposprinterPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  EscposprinterPlugin();
  virtual ~EscposprinterPlugin();

  EscposprinterPlugin(const EscposprinterPlugin&) = delete;
  EscposprinterPlugin& operator=(const EscposprinterPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::string selected_printer_name_;
};

}  // namespace escposprinter

#endif  // FLUTTER_PLUGIN_ESCPOSPRINTER_PLUGIN_H_
