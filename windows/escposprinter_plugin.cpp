#include "escposprinter_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <winspool.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cwctype>
#include <cstring>
#include <memory>
#include <optional>
#include <string>
#include <variant>
#include <vector>

namespace escposprinter {
namespace {

struct PrinterDevice {
  std::wstring name;
  std::wstring driver_name;
  std::wstring port_name;
  std::optional<int> vendor_id;
  std::optional<int> product_id;
};

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return "";
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                                      static_cast<int>(value.size()), nullptr, 0,
                                      nullptr, nullptr);
  if (size <= 0) {
    return "";
  }
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
                      result.data(), size, nullptr, nullptr);
  return result;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return L"";
  }
  const int size =
      MultiByteToWideChar(CP_UTF8, 0, value.c_str(),
                          static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) {
    return L"";
  }
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
                      result.data(), size);
  return result;
}

std::wstring ToUpper(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(towupper(c)); });
  return value;
}

std::optional<int> ParseHexId(const std::wstring& source,
                              const std::wstring& prefix) {
  const std::wstring upper = ToUpper(source);
  const size_t index = upper.find(prefix);
  if (index == std::wstring::npos) {
    return std::nullopt;
  }

  const size_t start = index + prefix.size();
  size_t end = start;
  while (end < upper.size() && iswxdigit(upper[end])) {
    end++;
  }
  if (end == start) {
    return std::nullopt;
  }

  try {
    return std::stoi(upper.substr(start, end - start), nullptr, 16);
  } catch (...) {
    return std::nullopt;
  }
}

std::wstring QueryPrinterRegistryString(HKEY printer_key,
                                        const wchar_t* value_name) {
  DWORD type = 0;
  DWORD byte_count = 0;
  if (RegQueryValueExW(printer_key, value_name, nullptr, &type, nullptr,
                       &byte_count) != ERROR_SUCCESS ||
      (type != REG_SZ && type != REG_EXPAND_SZ) || byte_count == 0) {
    return L"";
  }

  std::wstring value(byte_count / sizeof(wchar_t), L'\0');
  if (RegQueryValueExW(printer_key, value_name, nullptr, &type,
                       reinterpret_cast<LPBYTE>(value.data()),
                       &byte_count) != ERROR_SUCCESS) {
    return L"";
  }

  while (!value.empty() && value.back() == L'\0') {
    value.pop_back();
  }
  return value;
}

std::wstring QueryPrinterDeviceInstanceId(const std::wstring& printer_name) {
  HKEY printers_key = nullptr;
  if (RegOpenKeyExW(HKEY_LOCAL_MACHINE,
                    L"SYSTEM\\CurrentControlSet\\Control\\Print\\Printers", 0,
                    KEY_READ, &printers_key) != ERROR_SUCCESS) {
    return L"";
  }

  HKEY printer_key = nullptr;
  const LONG open_result =
      RegOpenKeyExW(printers_key, printer_name.c_str(), 0, KEY_READ,
                    &printer_key);
  RegCloseKey(printers_key);
  if (open_result != ERROR_SUCCESS) {
    return L"";
  }

  std::wstring instance_id =
      QueryPrinterRegistryString(printer_key, L"PNPDeviceID");
  if (instance_id.empty()) {
    instance_id = QueryPrinterRegistryString(printer_key, L"DeviceInstanceId");
  }

  RegCloseKey(printer_key);
  return instance_id;
}

std::vector<PrinterDevice> EnumeratePrinters() {
  DWORD needed = 0;
  DWORD returned = 0;
  EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, nullptr, 2,
                nullptr, 0, &needed, &returned);
  if (needed == 0) {
    return {};
  }

  std::vector<BYTE> buffer(needed);
  if (!EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, nullptr, 2,
                     buffer.data(), needed, &needed, &returned)) {
    return {};
  }

  auto* printer_infos = reinterpret_cast<PRINTER_INFO_2W*>(buffer.data());
  std::vector<PrinterDevice> printers;
  printers.reserve(returned);

  for (DWORD index = 0; index < returned; index++) {
    PrinterDevice device;
    device.name = printer_infos[index].pPrinterName != nullptr
                      ? printer_infos[index].pPrinterName
                      : L"";
    device.driver_name = printer_infos[index].pDriverName != nullptr
                             ? printer_infos[index].pDriverName
                             : L"";
    device.port_name = printer_infos[index].pPortName != nullptr
                           ? printer_infos[index].pPortName
                           : L"";

    const std::wstring instance_id =
        QueryPrinterDeviceInstanceId(device.name);
    const std::wstring id_source =
        instance_id + L" " + device.port_name + L" " + device.driver_name;
    device.vendor_id = ParseHexId(id_source, L"VID_");
    device.product_id = ParseHexId(id_source, L"PID_");

    printers.push_back(device);
  }

  return printers;
}

int SyntheticProductId(const PrinterDevice& device) {
  uint32_t hash = 2166136261u;
  const std::wstring source = device.name + L"|" + device.port_name;
  for (const wchar_t character : source) {
    hash ^= static_cast<uint32_t>(character);
    hash *= 16777619u;
  }
  return static_cast<int>((hash % 65534u) + 1u);
}

flutter::EncodableMap DeviceToMap(const PrinterDevice& device) {
  const std::string name = WideToUtf8(device.name);
  const std::string driver_name = WideToUtf8(device.driver_name);
  const std::string port_name = WideToUtf8(device.port_name);
  const int effective_vendor_id = device.vendor_id.value_or(65535);
  const int effective_product_id =
      device.product_id.value_or(SyntheticProductId(device));
  const bool synthetic_id = !device.vendor_id || !device.product_id;

  return flutter::EncodableMap{
      {flutter::EncodableValue("name"), flutter::EncodableValue(name)},
      {flutter::EncodableValue("manufacturer"), flutter::EncodableValue("")},
      {flutter::EncodableValue("product"),
       flutter::EncodableValue(driver_name.empty() ? name : driver_name)},
      {flutter::EncodableValue("deviceid"),
       flutter::EncodableValue(port_name.empty() ? name : port_name)},
      {flutter::EncodableValue("vendorid"),
       flutter::EncodableValue(std::to_string(effective_vendor_id))},
      {flutter::EncodableValue("productid"),
       flutter::EncodableValue(std::to_string(effective_product_id))},
      {flutter::EncodableValue("port"), flutter::EncodableValue(port_name)},
      {flutter::EncodableValue("windowsSyntheticId"),
       flutter::EncodableValue(synthetic_id ? "true" : "false")},
  };
}

bool MatchesPrinterIds(const PrinterDevice& printer,
                       int vendor_id,
                       int product_id) {
  if (printer.vendor_id.has_value() && printer.product_id.has_value() &&
      printer.vendor_id == vendor_id && printer.product_id == product_id) {
    return true;
  }

  if (vendor_id != 65535) {
    return false;
  }

  const int synthetic_product_id = SyntheticProductId(printer);
  return (!printer.vendor_id || !printer.product_id) &&
         product_id == synthetic_product_id;
}

std::optional<std::wstring> FindPrinterNameByUsbIds(int vendor_id,
                                                    int product_id) {
  const std::vector<PrinterDevice> printers = EnumeratePrinters();
  for (const PrinterDevice& printer : printers) {
    if (MatchesPrinterIds(printer, vendor_id, product_id)) {
      return printer.name;
    }
  }
  return std::nullopt;
}

std::string LastErrorMessage(const std::string& fallback) {
  const DWORD error = GetLastError();
  if (error == 0) {
    return fallback;
  }

  LPWSTR message_buffer = nullptr;
  const DWORD size = FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, error, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      reinterpret_cast<LPWSTR>(&message_buffer), 0, nullptr);
  if (size == 0 || message_buffer == nullptr) {
    return fallback + " Windows error " + std::to_string(error) + ".";
  }

  std::wstring message(message_buffer, size);
  LocalFree(message_buffer);
  return fallback + " " + WideToUtf8(message);
}

bool SendRawBytesToPrinter(const std::wstring& printer_name,
                           const std::vector<uint8_t>& bytes,
                           std::string* error_message) {
  if (bytes.empty()) {
    return true;
  }

  HANDLE printer = nullptr;
  if (!OpenPrinterW(const_cast<LPWSTR>(printer_name.c_str()), &printer,
                    nullptr)) {
    *error_message = LastErrorMessage("Unable to open Windows printer queue.");
    return false;
  }

  DOC_INFO_1W doc_info;
  doc_info.pDocName = const_cast<LPWSTR>(L"ESC/POS Print Job");
  doc_info.pOutputFile = nullptr;
  doc_info.pDatatype = const_cast<LPWSTR>(L"RAW");

  if (StartDocPrinterW(printer, 1, reinterpret_cast<LPBYTE>(&doc_info)) == 0) {
    *error_message = LastErrorMessage("Unable to start Windows print job.");
    ClosePrinter(printer);
    return false;
  }

  if (!StartPagePrinter(printer)) {
    *error_message = LastErrorMessage("Unable to start Windows print page.");
    EndDocPrinter(printer);
    ClosePrinter(printer);
    return false;
  }

  DWORD written = 0;
  const BOOL ok =
      WritePrinter(printer, const_cast<uint8_t*>(bytes.data()),
                   static_cast<DWORD>(bytes.size()), &written);

  EndPagePrinter(printer);
  EndDocPrinter(printer);
  ClosePrinter(printer);

  if (!ok || written != bytes.size()) {
    *error_message = LastErrorMessage("Unable to write RAW data to printer.");
    return false;
  }

  return true;
}

const flutter::EncodableMap* ArgumentsMap(
    const flutter::EncodableValue* arguments) {
  if (!arguments || !std::holds_alternative<flutter::EncodableMap>(*arguments)) {
    return nullptr;
  }
  return &std::get<flutter::EncodableMap>(*arguments);
}

std::optional<int> ReadIntArgument(const flutter::EncodableMap& arguments,
                                   const char* key) {
  const auto iterator = arguments.find(flutter::EncodableValue(key));
  if (iterator == arguments.end()) {
    return std::nullopt;
  }
  const flutter::EncodableValue& value = iterator->second;
  if (std::holds_alternative<int32_t>(value)) {
    return std::get<int32_t>(value);
  }
  if (std::holds_alternative<int64_t>(value)) {
    return static_cast<int>(std::get<int64_t>(value));
  }
  return std::nullopt;
}

std::optional<std::string> ReadStringArgument(
    const flutter::EncodableMap& arguments,
    const char* key) {
  const auto iterator = arguments.find(flutter::EncodableValue(key));
  if (iterator == arguments.end() ||
      !std::holds_alternative<std::string>(iterator->second)) {
    return std::nullopt;
  }
  return std::get<std::string>(iterator->second);
}

std::optional<std::vector<uint8_t>> ReadBytesArgument(
    const flutter::EncodableMap& arguments,
    const char* key) {
  const auto iterator = arguments.find(flutter::EncodableValue(key));
  if (iterator == arguments.end()) {
    return std::nullopt;
  }

  const flutter::EncodableValue& value = iterator->second;
  if (std::holds_alternative<std::vector<uint8_t>>(value)) {
    return std::get<std::vector<uint8_t>>(value);
  }
  return std::nullopt;
}

std::vector<uint8_t> Base64Decode(const std::string& encoded) {
  static constexpr unsigned char kInvalid = 255;
  static const std::array<unsigned char, 256> table = [] {
    std::array<unsigned char, 256> result{};
    result.fill(kInvalid);
    const std::string chars =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (size_t index = 0; index < chars.size(); index++) {
      result[static_cast<unsigned char>(chars[index])] =
          static_cast<unsigned char>(index);
    }
    return result;
  }();

  std::vector<uint8_t> decoded;
  int value = 0;
  int bits = -8;
  for (const unsigned char character : encoded) {
    if (character == '=') {
      break;
    }
    if (table[character] == kInvalid) {
      continue;
    }
    value = (value << 6) + table[character];
    bits += 6;
    if (bits >= 0) {
      decoded.push_back(static_cast<uint8_t>((value >> bits) & 0xFF));
      bits -= 8;
    }
  }
  return decoded;
}

}  // namespace

EscposprinterPlugin::EscposprinterPlugin() = default;
EscposprinterPlugin::~EscposprinterPlugin() = default;

void EscposprinterPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "escposprinter",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<EscposprinterPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

void EscposprinterPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();

  if (method == "getUSBDeviceList") {
    flutter::EncodableList devices;
    for (const PrinterDevice& printer : EnumeratePrinters()) {
      devices.push_back(flutter::EncodableValue(DeviceToMap(printer)));
    }
    result->Success(flutter::EncodableValue(devices));
    return;
  }

  if (method == "connectPrinter") {
    const flutter::EncodableMap* arguments =
        ArgumentsMap(method_call.arguments());
    if (!arguments) {
      result->Error("invalid_arguments", "Missing arguments.");
      return;
    }

    const std::optional<int> vendor_id = ReadIntArgument(*arguments, "vendor");
    const std::optional<int> product_id = ReadIntArgument(*arguments, "product");
    if (!vendor_id || !product_id) {
      result->Error("invalid_arguments", "Missing vendor or product ID.");
      return;
    }

    const std::optional<std::wstring> printer_name =
        FindPrinterNameByUsbIds(*vendor_id, *product_id);
    if (!printer_name) {
      result->Success(flutter::EncodableValue(false));
      return;
    }

    selected_printer_name_ = WideToUtf8(*printer_name);
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "closeConn") {
    selected_printer_name_.clear();
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "printText" || method == "printRawData" || method == "write") {
    if (selected_printer_name_.empty()) {
      result->Error("not_connected",
                    "Connect to a Windows printer before writing data.");
      return;
    }

    const flutter::EncodableMap* arguments =
        ArgumentsMap(method_call.arguments());
    if (!arguments) {
      result->Error("invalid_arguments", "Missing arguments.");
      return;
    }

    std::vector<uint8_t> bytes;
    if (method == "printText") {
      const std::optional<std::string> text =
          ReadStringArgument(*arguments, "text");
      if (!text) {
        result->Error("invalid_arguments", "Missing text argument.");
        return;
      }
      bytes.assign(text->begin(), text->end());
    } else if (method == "printRawData") {
      const std::optional<std::string> raw =
          ReadStringArgument(*arguments, "raw");
      if (!raw) {
        result->Error("invalid_arguments", "Missing raw argument.");
        return;
      }
      bytes = Base64Decode(*raw);
    } else {
      const std::optional<std::vector<uint8_t>> data =
          ReadBytesArgument(*arguments, "data");
      if (!data) {
        result->Error("invalid_arguments", "Missing data argument.");
        return;
      }
      bytes = *data;
    }

    std::string error_message;
    if (!SendRawBytesToPrinter(Utf8ToWide(selected_printer_name_), bytes,
                               &error_message)) {
      result->Error("windows_print_error", error_message);
      return;
    }

    result->Success(flutter::EncodableValue(true));
    return;
  }

  result->NotImplemented();
}

}  // namespace escposprinter
