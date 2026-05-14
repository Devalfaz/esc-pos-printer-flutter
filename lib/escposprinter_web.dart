import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

class EscposprinterWeb {
  JSObject? _selectedDevice;
  int? _selectedEndpointNumber;
  int? _selectedInterfaceNumber;

  static void registerWith(Registrar registrar) {
    final channel = MethodChannel(
      'escposprinter',
      const StandardMethodCodec(),
      registrar,
    );

    final pluginInstance = EscposprinterWeb();
    channel.setMethodCallHandler(pluginInstance.handleMethodCall);
  }

  Future<dynamic> handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'getUSBDeviceList':
        return _getUSBDeviceList();
      case 'connectPrinter':
        final vendor = _readRequiredInt(call.arguments, 'vendor');
        final product = _readRequiredInt(call.arguments, 'product');
        return _connectPrinter(vendor, product);
      case 'closeConn':
        return _closeConn();
      case 'printText':
        final text = (call.arguments as Map?)?['text']?.toString() ?? '';
        return _write(Uint8List.fromList(utf8.encode(text)));
      case 'printRawData':
        final raw = (call.arguments as Map?)?['raw']?.toString() ?? '';
        return _write(base64Decode(raw));
      case 'write':
        final data = (call.arguments as Map?)?['data'];
        if (data is! Uint8List) {
          throw PlatformException(
            code: 'invalid_arguments',
            message: 'write expects a Uint8List in the data argument.',
          );
        }
        return _write(data);
      default:
        throw PlatformException(
          code: 'unimplemented',
          message: 'escposprinter for web does not implement ${call.method}.',
        );
    }
  }

  Future<List<Map<String, String>>> _getUSBDeviceList() async {
    final usb = _usb;
    if (usb == null) {
      throw PlatformException(
        code: 'webusb_unavailable',
        message: 'WebUSB is not available in this browser.',
      );
    }

    final devices = <JSObject>[];
    devices.addAll(await _getGrantedDevices(usb));

    // Browsers only expose devices that the user has already approved. When
    // this method is called from a refresh button, request one device too.
    try {
      final requestedDevice = await _requestDevice(usb);
      if (requestedDevice != null) {
        devices.add(requestedDevice);
      }
    } catch (error) {
      final name = _safeJsProperty(error, 'name')?.toString();
      if (name != 'SecurityError' && name != 'NotFoundError') {
        throw _platformException(error, 'Unable to request a USB device');
      }
    }

    final seen = <String>{};
    return devices
        .map(_deviceToMap)
        .where((device) => seen.add(
            '${device['vendorid']}:${device['productid']}:${device['serialnumber']}'))
        .toList();
  }

  Future<bool> _connectPrinter(int vendorId, int productId) async {
    final usb = _usb;
    if (usb == null) {
      throw PlatformException(
        code: 'webusb_unavailable',
        message: 'WebUSB is not available in this browser.',
      );
    }

    JSObject? device = _selectedDevice;
    if (!_matchesDevice(device, vendorId, productId)) {
      device = await _findGrantedDevice(usb, vendorId, productId);
    }

    if (device == null) {
      device = await _requestDevice(
        usb,
        vendorId: vendorId,
        productId: productId,
      );
    }

    if (device == null) {
      return false;
    }

    final endpoint = await _openDevice(device);
    _selectedDevice = device;
    _selectedInterfaceNumber = endpoint.interfaceNumber;
    _selectedEndpointNumber = endpoint.endpointNumber;
    return true;
  }

  Future<bool> _closeConn() async {
    final device = _selectedDevice;
    final interfaceNumber = _selectedInterfaceNumber;

    _selectedDevice = null;
    _selectedInterfaceNumber = null;
    _selectedEndpointNumber = null;

    if (device == null) {
      return true;
    }

    try {
      if (interfaceNumber != null) {
        await _promiseCall(
          device,
          'releaseInterface',
          <JSAny?>[interfaceNumber.toJS],
        );
      }
    } catch (_) {
      // Some browsers reject releaseInterface when the device was already gone.
    }

    try {
      if (_jsBool(device, 'opened')) {
        await _promiseCall(device, 'close');
      }
    } catch (_) {
      // Closing is best effort; match the native plugin's forgiving behavior.
    }

    return true;
  }

  Future<bool> _write(Uint8List data) async {
    final device = _selectedDevice;
    final endpointNumber = _selectedEndpointNumber;
    if (device == null || endpointNumber == null) {
      throw PlatformException(
        code: 'not_connected',
        message: 'Connect to a USB printer before writing data.',
      );
    }

    try {
      await _promiseCall(
        device,
        'transferOut',
        <JSAny?>[endpointNumber.toJS, data.toJS],
      );
      return true;
    } catch (error) {
      throw _platformException(error, 'Unable to write to the USB printer');
    }
  }

  Future<_UsbEndpointSelection> _openDevice(JSObject device) async {
    try {
      if (!_jsBool(device, 'opened')) {
        await _promiseCall(device, 'open');
      }

      if (_jsProperty(device, 'configuration') == null) {
        await _promiseCall(
          device,
          'selectConfiguration',
          <JSAny?>[(_firstConfigurationValue(device) ?? 1).toJS],
        );
      }

      final endpoint = _findOutputEndpoint(device);
      if (endpoint == null) {
        throw PlatformException(
          code: 'endpoint_not_found',
          message: 'No writable USB endpoint was found for this device.',
        );
      }

      await _promiseCall(
        device,
        'claimInterface',
        <JSAny?>[endpoint.interfaceNumber.toJS],
      );

      if (endpoint.alternateSetting != null &&
          endpoint.alternateSetting != endpoint.currentAlternateSetting) {
        await _promiseCall(
          device,
          'selectAlternateInterface',
          <JSAny?>[
            endpoint.interfaceNumber.toJS,
            endpoint.alternateSetting!.toJS,
          ],
        );
      }

      return endpoint;
    } on PlatformException {
      rethrow;
    } catch (error) {
      throw _platformException(error, 'Unable to connect to the USB printer');
    }
  }

  _UsbEndpointSelection? _findOutputEndpoint(JSObject device) {
    final configuration = _jsObjectProperty(device, 'configuration');
    if (configuration == null) return null;

    final interfaces = _jsProperty(configuration, 'interfaces');
    final interfaceCount = _jsLength(interfaces);

    for (var interfaceIndex = 0;
        interfaceIndex < interfaceCount;
        interfaceIndex++) {
      final usbInterface = _jsObjectIndex(interfaces, interfaceIndex);
      final interfaceNumber = _jsInt(usbInterface, 'interfaceNumber');
      if (interfaceNumber == null) continue;

      final currentAlternate = _jsObjectProperty(usbInterface, 'alternate');
      final currentAlternateSetting = _jsInt(
        currentAlternate,
        'alternateSetting',
      );
      final currentEndpoint = _findEndpointInAlternate(
        currentAlternate,
        interfaceNumber,
        currentAlternateSetting,
        currentAlternateSetting,
      );
      if (currentEndpoint != null) return currentEndpoint;

      final alternates = _jsProperty(usbInterface, 'alternates');
      final alternateCount = _jsLength(alternates);
      for (var alternateIndex = 0;
          alternateIndex < alternateCount;
          alternateIndex++) {
        final alternate = _jsObjectIndex(alternates, alternateIndex);
        final endpoint = _findEndpointInAlternate(
          alternate,
          interfaceNumber,
          _jsInt(alternate, 'alternateSetting'),
          currentAlternateSetting,
        );
        if (endpoint != null) return endpoint;
      }
    }

    return null;
  }

  _UsbEndpointSelection? _findEndpointInAlternate(
    JSObject? alternate,
    int interfaceNumber,
    int? alternateSetting,
    int? currentAlternateSetting,
  ) {
    if (alternate == null) return null;

    final endpoints = _jsProperty(alternate, 'endpoints');
    final endpointCount = _jsLength(endpoints);
    for (var endpointIndex = 0;
        endpointIndex < endpointCount;
        endpointIndex++) {
      final endpoint = _jsObjectIndex(endpoints, endpointIndex);
      if (_jsString(endpoint, 'direction') != 'out') continue;

      final endpointNumber = _jsInt(endpoint, 'endpointNumber');
      if (endpointNumber == null) continue;

      return _UsbEndpointSelection(
        interfaceNumber: interfaceNumber,
        endpointNumber: endpointNumber,
        alternateSetting: alternateSetting,
        currentAlternateSetting: currentAlternateSetting,
      );
    }

    return null;
  }

  Future<List<JSObject>> _getGrantedDevices(JSObject usb) async {
    final jsDevices = await _promiseCall(usb, 'getDevices');
    return _jsList(jsDevices);
  }

  Future<JSObject?> _findGrantedDevice(
    JSObject usb,
    int vendorId,
    int productId,
  ) async {
    final devices = await _getGrantedDevices(usb);
    for (final device in devices) {
      if (_matchesDevice(device, vendorId, productId)) {
        return device;
      }
    }
    return null;
  }

  Future<JSObject?> _requestDevice(
    JSObject usb, {
    int? vendorId,
    int? productId,
  }) async {
    final filter = <String, Object>{};
    if (vendorId != null) filter['vendorId'] = vendorId;
    if (productId != null) filter['productId'] = productId;

    final options = {
      'filters': filter.isEmpty ? <Object>[] : <Object>[filter],
    }.jsify();
    return await _promiseCall(usb, 'requestDevice', <JSAny?>[options])
        as JSObject?;
  }

  Map<String, String> _deviceToMap(JSObject device) {
    final vendorId = _jsInt(device, 'vendorId')?.toString() ?? '';
    final productId = _jsInt(device, 'productId')?.toString() ?? '';
    final product = _jsString(device, 'productName');
    final manufacturer = _jsString(device, 'manufacturerName');
    final serialNumber = _jsString(device, 'serialNumber') ?? '';

    return <String, String>{
      'name': product ?? 'USB Printer $vendorId:$productId',
      'manufacturer': manufacturer ?? '',
      'product': product ?? 'USB Printer',
      'deviceid':
          serialNumber.isNotEmpty ? serialNumber : '$vendorId:$productId',
      'vendorid': vendorId,
      'productid': productId,
      'serialnumber': serialNumber,
    };
  }

  int? _firstConfigurationValue(JSObject device) {
    final configurations = _jsProperty(device, 'configurations');
    final firstConfiguration = _jsObjectIndex(configurations, 0);
    return _jsInt(firstConfiguration, 'configurationValue');
  }

  bool _matchesDevice(JSObject? device, int vendorId, int productId) {
    if (device == null) return false;
    return _jsInt(device, 'vendorId') == vendorId &&
        _jsInt(device, 'productId') == productId;
  }

  JSObject? get _usb {
    final navigator = globalContext.getProperty<JSObject?>('navigator'.toJS);
    if (navigator == null) return null;
    return navigator.getProperty<JSObject?>('usb'.toJS);
  }

  int _readRequiredInt(Object? arguments, String key) {
    final value = (arguments as Map?)?[key];
    if (value is int) return value;
    if (value is num) return value.toInt();

    final parsed = int.tryParse(value?.toString() ?? '');
    if (parsed != null) return parsed;

    throw PlatformException(
      code: 'invalid_arguments',
      message: '$key must be an integer.',
    );
  }

  Future<JSAny?> _promiseCall(
    JSObject target,
    String method, [
    List<JSAny?> args = const <JSAny?>[],
  ]) {
    final promise = target.callMethodVarArgs<JSPromise<JSAny?>>(
      method.toJS,
      args,
    );
    return promise.toDart;
  }

  List<JSObject> _jsList(JSAny? value) {
    final length = _jsLength(value);
    final items = <JSObject>[];
    for (var index = 0; index < length; index++) {
      final item = _jsObjectIndex(value, index);
      if (item != null) items.add(item);
    }
    return items;
  }

  int _jsLength(JSAny? value) {
    if (value == null) return 0;
    final length = _jsProperty(value as JSObject, 'length')?.dartify();
    if (length is int) return length;
    if (length is num) return length.toInt();
    return int.tryParse(length?.toString() ?? '') ?? 0;
  }

  JSAny? _jsIndex(JSAny? value, int index) {
    if (value == null) return null;
    return (value as JSObject).getProperty<JSAny?>(index.toJS);
  }

  JSObject? _jsObjectIndex(JSAny? value, int index) {
    final item = _jsIndex(value, index);
    if (item == null) return null;
    return item as JSObject;
  }

  String? _jsString(JSObject? value, String property) {
    final propertyValue = _jsProperty(value, property)?.dartify();
    if (propertyValue == null) return null;
    final text = propertyValue.toString();
    return text.isEmpty ? null : text;
  }

  int? _jsInt(JSObject? value, String property) {
    final propertyValue = _jsProperty(value, property)?.dartify();
    if (propertyValue is int) return propertyValue;
    if (propertyValue is num) return propertyValue.toInt();
    return int.tryParse(propertyValue?.toString() ?? '');
  }

  bool _jsBool(JSObject? value, String property) {
    return _jsProperty(value, property)?.dartify() == true;
  }

  JSAny? _jsProperty(JSObject? value, String property) {
    if (value == null) return null;
    return value.getProperty<JSAny?>(property.toJS);
  }

  JSObject? _jsObjectProperty(JSObject? value, String property) {
    final propertyValue = _jsProperty(value, property);
    if (propertyValue == null) return null;
    return propertyValue as JSObject;
  }

  PlatformException _platformException(Object error, String fallbackMessage) {
    final name = _safeJsProperty(error, 'name')?.toString();
    final message = _safeJsProperty(error, 'message')?.toString();
    final resolvedMessage =
        message == null ? fallbackMessage : '$fallbackMessage: $message';

    if (name == 'SecurityError' &&
        message != null &&
        message.contains("'open'") &&
        message.toLowerCase().contains('access denied')) {
      return PlatformException(
        code: 'webusb_access_denied',
        message: '$resolvedMessage. On Windows, WebUSB requires the printer '
            'interface to use a WinUSB-compatible driver and it cannot be in '
            'use by the Windows printer spooler, vendor driver, or another app.',
        details: error.toString(),
      );
    }

    return PlatformException(
      code: name ?? 'webusb_error',
      message: resolvedMessage,
      details: error.toString(),
    );
  }

  Object? _safeJsProperty(Object error, String property) {
    try {
      final jsError = JSObject.fromInteropObject(error);
      return _jsProperty(jsError, property)?.dartify();
    } catch (_) {
      return null;
    }
  }
}

class _UsbEndpointSelection {
  const _UsbEndpointSelection({
    required this.interfaceNumber,
    required this.endpointNumber,
    required this.alternateSetting,
    required this.currentAlternateSetting,
  });

  final int interfaceNumber;
  final int endpointNumber;
  final int? alternateSetting;
  final int? currentAlternateSetting;
}
