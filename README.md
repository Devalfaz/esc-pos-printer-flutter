# ESC POS Printer for Flutter

Flutter plugin to connect and print on ESC POS Printers.


## Installation

Use this package as a library
1. Depend on it
Add this to your package's pubspec.yaml file:

```` dart
dependencies:
  escposprinter:
    git:
        url: https://github.com/marcusfelix/esc-pos-printer-flutter.git
        ref: master
````

2. Install it
You can install packages from the command line:

with Flutter:
````
$ flutter packages get
````

Alternatively, your editor might support flutter packages get. Check the docs for your editor to learn more.

3. Import it
Now in your Dart code, you can use:

```` dart
import 'package:flutter_webview_plugin/flutter_webview_plugin.dart';
````


## Example

```` dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:escposprinter/escposprinter.dart';

void main() => runApp(new MyApp());

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => new _MyAppState();
}

class _MyAppState extends State<MyApp> {
  List devices = [];
  bool connected = false;

  @override
  initState() {
    super.initState();
    _list();
  }

  _list() async {
    List returned;
    try {
      returned = await Escposprinter.getUSBDeviceList;
    } on PlatformException {
      //response = 'Failed to get platform version.';
    }
    setState((){
      devices = returned;
    });
  }

  _connect(int vendor, int product) async {
    bool returned;
    try {
      returned = await Escposprinter.connectPrinter(vendor, product);
    } on PlatformException {
      //response = 'Failed to get platform version.';
    }
    if(returned){
      setState((){
        connected = true;
      });
    }
  }

  _print() async {
    try {
      await Escposprinter.printText("Testing ESC POS printer...");
    } on PlatformException {
      //response = 'Failed to get platform version.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return new MaterialApp(
      home: new Scaffold(
        appBar: new AppBar(
          title: new Text('ESC POS'),
          actions: <Widget>[
            new IconButton(
              icon: new Icon(Icons.refresh), 
              onPressed: () {
                _list();
              }
            ),
            connected == true ? new IconButton(
              icon: new Icon(Icons.print), 
              onPressed: () {
                _print();
              }
            ) : new Container(),
          ],
        ),
        body: devices.length > 0 ? new ListView(
          scrollDirection: Axis.vertical,
          children: _buildList(devices),
        ) : null,
      ),
    );
  }

  List<Widget> _buildList(List devices){
    return devices.map((device) => new ListTile(
      onTap: () {
        _connect(int.parse(device['vendorid']), int.parse(device['productid']));
      },
      leading: new Icon(Icons.usb),
      title: new Text(device['manufacturer'] + " " + device['product']),
      subtitle: new Text(device['vendorid'] + " " + device['productid']),
    )).toList();
  }
}

````

## WebUSB on Windows

If Chrome or Edge on Windows shows an error like:

````
PlatformException SecurityError: Failed to execute 'open' on 'USBDevice': Access denied
````

the browser has permission to see the USB printer, but Windows is not allowing
the browser to open the USB interface. Unlike macOS, Windows usually requires
the selected USB interface to be bound to a WinUSB-compatible driver before
WebUSB can open it.

For a client Windows machine, check these items:

1. Use Chrome or Edge on HTTPS, or `localhost` during development.
2. Close any POS app, printer utility, or Windows print queue that may already
   be using the USB printer.
3. In Device Manager, confirm which driver owns the printer's USB interface.
   If it is a normal printer/vendor driver, WebUSB may be denied.
4. Bind the printer interface to WinUSB, for example with the vendor's WebUSB
   driver/INF or a tool such as Zadig. This can make the printer unavailable to
   the normal Windows print queue until the original driver is restored.
5. After changing the driver, unplug/replug the printer and grant browser
   permission again.

This plugin uses the browser WebUSB API on web builds. If the same printer must
also keep working through the Windows print queue, consider using the printer's
network, Bluetooth, vendor SDK, Web Serial, or a small native bridge instead of
WebUSB.

## Windows desktop

Windows desktop builds use the native Windows print spooler instead of WebUSB.
The plugin enumerates installed printer queues, uses VID/PID information when
Windows exposes it, selects the matching queue in `connectPrinter`, and sends
`printText`, `printRawData`, and `write` bytes as a RAW print job.
If Windows does not expose VID/PID for a printer queue, the plugin returns a
stable Windows-only synthetic ID so the existing `connectPrinter(vendor,
product)` flow can still select it from `getUSBDeviceList`.

For Windows desktop clients:

1. Install the receipt printer in Windows first.
2. Prefer a Generic/Text or vendor driver that accepts RAW ESC/POS data.
3. Make sure the printer appears in Windows Printers & scanners before calling
   `Escposprinter.getUSBDeviceList`.
4. If the printer is listed but does not print ESC/POS commands correctly, the
   installed driver may be transforming the data instead of passing RAW bytes.

### Testing without a physical printer

You can emulate a network receipt printer on the Windows test machine by
listening on TCP port 9100 and pointing a Windows printer queue at it.

Start the listener:

```` powershell
powershell -ExecutionPolicy Bypass -File .\scripts\listen_escpos_printer.ps1 -Port 9100
````

Then create a Windows printer queue:

1. Open **Printers & scanners**.
2. Add a printer manually.
3. Choose a local or network printer with manual settings.
4. Create a **Standard TCP/IP Port**.
5. Use host `127.0.0.1` and port `9100`.
6. Choose **Generic > Generic / Text Only**.

Run the Flutter Windows example and print to that queue. The listener writes
each job as `.bin`, `.hex.txt`, and `.text.txt` files under
`scripts\escpos-captures`.
