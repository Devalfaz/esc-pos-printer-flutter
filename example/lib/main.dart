import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:escposprinter/escposprinter.dart';

void main() => runApp(new MyApp());

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => new _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({Key? key}) : super(key: key);

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  List devices = [];
  bool connected = false;

  @override
  initState() {
    super.initState();
    _list();
  }

  _list() async {
    List returned = [];
    try {
      returned = await Escposprinter.getUSBDeviceList;
    } on PlatformException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text('Failed to get USB device list. PlatformException: $e')));
    } on Exception catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to get USB device list. Exception: $e')));
    }

    setState(() {
      devices = returned;
    });
  }

  _connect(int vendor, int product) async {
    print(
        '🔌 Flutter: Attempting to connect to printer - VendorID: $vendor, ProductID: $product');
    bool returned = false;
    try {
      returned = await Escposprinter.connectPrinter(vendor, product);
      print('🔌 Flutter: Connection result: $returned');
    } on PlatformException catch (e) {
      print('❌ Flutter: PlatformException during connection: $e');
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect. PlatformException: $e')));
    } on Exception catch (e) {
      print('❌ Flutter: Exception during connection: $e');
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect. Exception: $e')));
    }
    if (returned) {
      print('✅ Flutter: Connection successful, updating UI state');
      setState(() {
        connected = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('✅ Connected to printer!'),
          backgroundColor: Colors.green));
    } else {
      print('❌ Flutter: Connection failed');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('❌ Failed to connect to printer'),
          backgroundColor: Colors.red));
    }
  }

  _print() async {
    print('🖨️ Flutter: Starting print operation...');
    try {
      var text = " Hello world Testing ESC POS printer...";
      var data = Uint8List.fromList(utf8.encode(text));
      print('🖨️ Flutter: Sending ${data.length} bytes to printer: "$text"');
      print('🖨️ Flutter: Data bytes: ${data.join(', ')}');

      bool result = await Escposprinter.write(data);
      print('🖨️ Flutter: Print result: $result');

      if (result) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('✅ Print command sent successfully!'),
            backgroundColor: Colors.green));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('❌ Print command failed'),
            backgroundColor: Colors.red));
      }

      // await Escposprinter.printRawData("text");
      // await Escposprinter.printText("Testing ESC POS printer...");
    } on PlatformException catch (e) {
      print('❌ Flutter: PlatformException during print: $e');
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to print. PlatformException: $e')));
    } on Exception catch (e) {
      print('❌ Flutter: Exception during print: $e');
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to print. Exception: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return new Scaffold(
      appBar: new AppBar(
        title: new Text('ESC POS'),
        actions: <Widget>[
          new IconButton(
              icon: new Icon(Icons.refresh),
              onPressed: () {
                _list();
              }),
          connected == true
              ? new IconButton(
                  icon: new Icon(Icons.print),
                  onPressed: () {
                    _print();
                  })
              : new Container(),
        ],
      ),
      body: devices.length > 0
          ? new ListView(
              scrollDirection: Axis.vertical,
              children: _buildList(devices),
            )
          : null,
    );
  }

  List<Widget> _buildList(List devices) {
    return devices
        .map((device) => new ListTile(
              onTap: () {
                _connect(int.parse(device['vendorid']),
                    int.parse(device['productid']));
              },
              leading: new Icon(Icons.usb),
              title: new Text(device['manufacturer'].toString() +
                  " " +
                  device['product'].toString()),
              subtitle: new Text(device['vendorid'].toString() +
                  " " +
                  device['productid'].toString()),
            ))
        .toList();
  }
}
