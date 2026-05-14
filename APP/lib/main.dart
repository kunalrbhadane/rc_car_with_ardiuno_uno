// (All imports and constants at the top are the same)
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

// --- BLE Configuration ---
const String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
const String characteristicUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
const String bandAName = "CoupleBand-A";
const String bandBName = "CoupleBand-B";

// --- MQTT Configuration ---
const String mqttBroker = 'test.mosquitto.org';
const int mqttPort = 1883;
final String mqttClientIdentifier = 'couple-band-app-${DateTime.now().millisecondsSinceEpoch}';
const String tapTopicA = 'coupleband/A/tap';
const String tapTopicB = 'coupleband/B/tap';

void main() {
  runApp(const CoupleBandsApp());
}

class CoupleBandsApp extends StatelessWidget {
  const CoupleBandsApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Couple Bands Bridge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.pinkAccent),
        useMaterial3: true,
      ),
      home: const ControlScreen(),
    );
  }
}

class BandState {
  final String name;
  BluetoothDevice? device;
  BluetoothCharacteristic? characteristic;
  BluetoothConnectionState connectionState = BluetoothConnectionState.disconnected;
  StreamSubscription? connectionSubscription;
  StreamSubscription? valueSubscription;
  BandState(this.name);
  bool get isConnected => connectionState == BluetoothConnectionState.connected;
}

class ControlScreen extends StatefulWidget {
  const ControlScreen({super.key});
  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  final BandState _bandA = BandState(bandAName);
  final BandState _bandB = BandState(bandBName);
  bool _isScanning = false;
  final List<String> _eventLog = [];
  StreamSubscription<bool>? _isScanningSubscription;

  MqttServerClient? _mqttClient;
  MqttConnectionState _mqttStatus = MqttConnectionState.disconnected;

  @override
  void initState() {
    super.initState();
    // This listener is the key to reliable scanning.
    _isScanningSubscription = FlutterBluePlus.isScanning.listen((isScanning) {
        if (!isScanning) {
          // Scan has finished, now we process the results.
          _processScanResults();
        }
    });

    Future.delayed(const Duration(milliseconds: 500), () {
      _setupMqttClient();
      _connectMqtt();
      _startScan();
    });
  }

  @override
  void dispose() {
    _isScanningSubscription?.cancel();
    FlutterBluePlus.stopScan();
    _disconnect(_bandA);
    _disconnect(_bandB);
    _mqttClient?.disconnect();
    super.dispose();
  }
  
  // --- THIS IS THE NEW, RELIABLE SCAN LOGIC ---
  Future<void> _startScan() async {
    if (FlutterBluePlus.isScanningNow) return;
    _logEvent("BLE: Scan starting...");
    setState(() {
      _isScanning = true;
      _bandA.device = null; // Reset on each scan
      _bandB.device = null;
    });
    // This simply starts the scan. The listener in initState will handle the results.
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
  }

  void _processScanResults() {
      var scanResults = FlutterBluePlus.lastScanResults;
      _logEvent("BLE: Scan finished. Found ${scanResults.length} devices in total.");

      for (ScanResult r in scanResults) {
        String deviceName = r.device.platformName.isEmpty ? "Unnamed" : r.device.platformName;
        if (deviceName == bandAName) {
          _logEvent("--> MATCH! Found Band A!");
          setState(() => _bandA.device = r.device);
        }
        if (deviceName == bandBName) {
          _logEvent("--> MATCH! Found Band B!");
          setState(() => _bandB.device = r.device);
        }
      }
      if (mounted) {
          setState(() => _isScanning = false);
      }
  }


  // --- (THE REST OF THE CODE IS THE SAME, no changes needed below this line) ---
   void _logEvent(String message) {
    developer.log(message, name: 'App');
    if (!mounted) return;
    setState(() {
      _eventLog.insert(0, "[${DateTime.now().toLocal().toString().substring(11, 19)}] $message");
    });
  }
   Future<void> _connect(BandState band) async {
    if (band.device == null) return;
    band.connectionSubscription = band.device!.connectionState.listen((state) {
      if (!mounted) return;
      setState(() => band.connectionState = state);
      _logEvent("BLE: ${band.name} is now ${state.toString().split('.').last}");
      if (state == BluetoothConnectionState.connected) { _discoverServices(band); } 
      else { band.characteristic = null; band.valueSubscription?.cancel(); }
    });
    try { await band.device!.connect(timeout: const Duration(seconds: 15)); } 
    catch (e) { _logEvent("BLE Connection Error for ${band.name}: $e"); }
  }

  Future<void> _disconnect(BandState band) async {
    await band.valueSubscription?.cancel();
    await band.connectionSubscription?.cancel();
    await band.device?.disconnect();
  }
  
  Future<void> _discoverServices(BandState band) async {
    if (band.device == null) return;
    try {
      List<BluetoothService> services = await band.device!.discoverServices();
      for (var s in services) {
        if (s.uuid.toString() == serviceUuid) {
          for (var c in s.characteristics) {
            if (c.uuid.toString() == characteristicUuid) {
              _logEvent("BLE: Found characteristic for ${band.name}");
              setState(() => band.characteristic = c); _subscribeToBleCharacteristic(band); return;
            }
          }
        }
      }
    } catch (e) { _logEvent("BLE Service Discovery Error for ${band.name}: $e"); }
  }

  Future<void> _subscribeToBleCharacteristic(BandState band) async {
    if (band.characteristic == null) return;
    await band.characteristic!.setNotifyValue(true);
    band.valueSubscription = band.characteristic!.onValueReceived.listen((value) {
      String decodedValue = utf8.decode(value);
      _logEvent("BLE Received from ${band.name}: '$decodedValue'");
      if (decodedValue == "TAP") {
        if (band.name == _bandA.name) { _publishMqttMessage(tapTopicA, "TAP"); } 
        else if (band.name == _bandB.name) { _publishMqttMessage(tapTopicB, "TAP"); }
      }
    });
  }

  Future<void> _sendBleCommand(String message, BandState targetBand) async {
    if (!targetBand.isConnected || targetBand.characteristic == null) return;
    try { await targetBand.characteristic!.write(utf8.encode(message), withoutResponse: true); }
     catch (e) { _logEvent("BLE Send Error to ${targetBand.name}: $e"); }
  }

  void _setupMqttClient() {
    _mqttClient = MqttServerClient(mqttBroker, mqttClientIdentifier);
    _mqttClient!.port = mqttPort;
    _mqttClient!.keepAlivePeriod = 60;
    _mqttClient!.onConnected = _onMqttConnected;
    _mqttClient!.onDisconnected = _onMqttDisconnected;
    final connMessage = MqttConnectMessage().withClientIdentifier(mqttClientIdentifier).startClean();
    _mqttClient!.connectionMessage = connMessage;
  }

  Future<void> _connectMqtt() async {
    if (_mqttClient == null) return;
    _logEvent("MQTT: Attempting to connect...");
    try { setState(() => _mqttStatus = MqttConnectionState.connecting); await _mqttClient!.connect(); } 
    catch (e) { _logEvent("MQTT: Connection failed: $e"); setState(() => _mqttStatus = MqttConnectionState.faulted); }
  }

  void _onMqttConnected() {
    setState(() => _mqttStatus = MqttConnectionState.connected);
    _logEvent("MQTT: Client connected!");
    _mqttClient!.subscribe(tapTopicA, MqttQos.atLeastOnce); _mqttClient!.subscribe(tapTopicB, MqttQos.atLeastOnce);
    _mqttClient!.updates!.listen((List<MqttReceivedMessage<MqttMessage>> c) {
      final MqttPublishMessage recMess = c[0].payload as MqttPublishMessage;
      final String payload = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
      _logEvent("MQTT Received: topic='${c[0].topic}', payload='$payload'");
      if (c[0].topic == tapTopicA && payload == "TAP") { _sendBleCommand("PULSE", _bandB); }
      if (c[0].topic == tapTopicB && payload == "TAP") { _sendBleCommand("PULSE", _bandA); }
    });
  }

  void _onMqttDisconnected() {
    setState(() => _mqttStatus = MqttConnectionState.disconnected);
    _logEvent("MQTT: Client disconnected");
  }

  void _publishMqttMessage(String topic, String message) {
    if (_mqttClient?.connectionStatus?.state != MqttConnectionState.connected) return;
    final builder = MqttClientPayloadBuilder();
    builder.addString(message);
    _mqttClient!.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold( appBar: AppBar(title: const Text('Couple Bands Bridge'),),
      body: Column( children: [
          _buildMqttStatusCard(),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16.0), child: Row(children: [
            Expanded(child: _buildBandCard(_bandA)), const SizedBox(width: 16),
            Expanded(child: _buildBandCard(_bandB)), ],),),
          _buildScanButton(),
          const Divider(indent: 16, endIndent: 16),
          Padding(padding: const EdgeInsets.all(16.0), child: Row( mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text("Event Log", style: Theme.of(context).textTheme.titleMedium),
               IconButton( icon: const Icon(Icons.clear_all), tooltip: "Clear Log", onPressed: () => setState(() => _eventLog.clear()),),
            ],),),
          Expanded(child: _buildLogList()), ],),);
  }

  Widget _buildScanButton() {
    return Padding( padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 16.0),
      child: OutlinedButton.icon(
        icon: _isScanning ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.0)) : const Icon(Icons.bluetooth_searching),
        label: Text(_isScanning ? "Scanning..." : "Re-Scan for Bands"),
        onPressed: _isScanning ? null : _startScan,
        style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 40)),),);
  }

  Widget _buildMqttStatusCard() {
    String statusText; Color statusColor;
    switch (_mqttStatus) {
      case MqttConnectionState.connected: statusText = "CONNECTED"; statusColor = Colors.green; break;
      case MqttConnectionState.connecting: statusText = "CONNECTING..."; statusColor = Colors.orange; break;
      default: statusText = "DISCONNECTED"; statusColor = Colors.red;
    }
    return Card(margin: const EdgeInsets.all(16.0), child: Padding(padding: const EdgeInsets.all(16.0), child: Row(children: [
      Icon(Icons.cloud_outlined, color: Theme.of(context).colorScheme.primary), const SizedBox(width: 16),
      const Text("Cloud Status:", style: TextStyle(fontWeight: FontWeight.bold)), const Spacer(),
      Chip(label: Text(statusText), backgroundColor: statusColor.withOpacity(0.2), labelStyle: TextStyle(color: statusColor, fontWeight: FontWeight.bold), side: BorderSide.none,),]),),);
  }

  Widget _buildBandCard(BandState band) {
    bool isFound = band.device != null; bool isConnected = band.isConnected; Color statusColor; IconData icon; String statusText;
    if (isConnected) { statusText = "CONNECTED"; statusColor = Colors.green; icon = Icons.bluetooth_connected; } 
    else if (isFound) { statusText = "FOUND"; statusColor = Colors.orange; icon = Icons.bluetooth_searching; }
    else { statusText = "NOT FOUND"; statusColor = Colors.red; icon = Icons.bluetooth_disabled; }

    return Card(
      elevation: 4, color: isFound ? null : Colors.grey.shade200,
      child: Padding(padding: const EdgeInsets.all(12.0), child: Column(children: [
        Text(band.name, style: Theme.of(context).textTheme.titleLarge), const SizedBox(height: 8),
        Chip( avatar: Icon(icon, color: statusColor, size: 18), label: Text(statusText),
          backgroundColor: statusColor.withOpacity(0.2), labelStyle: TextStyle(color: statusColor, fontWeight: FontWeight.bold), side: BorderSide.none,
        ),
        const SizedBox(height: 12),
        FilledButton( onPressed: !isFound || _isScanning ? null : (isConnected ? () => _disconnect(band) : () => _connect(band)),
          style: FilledButton.styleFrom(backgroundColor: isConnected ? Colors.red.shade300 : null,),
          child: Text(isConnected ? "Disconnect" : "Connect"),), ],),),);
  }

  Widget _buildLogList() {
    if (_eventLog.isEmpty) { return const Center(child: Text("Waiting for events...", style: TextStyle(color: Colors.grey)),); }
    return ListView.builder( reverse: true, itemCount: _eventLog.length,
      itemBuilder: (context, index) { return Padding(padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: Text(_eventLog[index], style: const TextStyle(fontSize: 12)),);},);
  }
}