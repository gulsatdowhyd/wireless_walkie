import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wifi_info_flutter/wifi_info_flutter.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:get/get.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      home: WalkieTalkieScreen(),
    );
  }
}

class WalkieTalkieController extends GetxController {
  RxList<WirelessDevice> devices = <WirelessDevice>[].obs;
  RxBool isTalking = false.obs;
  RxBool isConnected = false.obs;
  RxString status = 'Initializing...'.obs;
  RxBool isInitialized = false.obs;
}

class WalkieTalkieScreen extends StatefulWidget {
  @override
  _WalkieTalkieScreenState createState() => _WalkieTalkieScreenState();
}

class _WalkieTalkieScreenState extends State<WalkieTalkieScreen> {
  final controller = Get.put(WalkieTalkieController());
  late final WirelessManager wirelessManager;

  @override
  void initState() {
    super.initState();
    wirelessManager = WirelessManager();
    _initialize();
  }

  Future<void> _initialize() async {
    await wirelessManager.initialize();
    controller.isInitialized.value = true;
    controller.status.value = 'Disconnected';
    wirelessManager.discoveredDevices.listen((device) {
      if (!controller.devices.any((d) => d.address == device.address)) {
        controller.devices.add(device);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Wireless Walkie-Talkie')),
      body: Obx(() => Column(
            children: [
              Padding(
                padding: EdgeInsets.all(8),
                child: Text('Status: ${controller.status.value}'),
              ),
              if (!controller.isInitialized.value)
                Center(child: CircularProgressIndicator())
              else
                Expanded(
                  child: ListView.builder(
                    itemCount: controller.devices.length,
                    itemBuilder: (ctx, i) => ListTile(
                      title: Text(controller.devices[i].name),
                      subtitle: Text(controller.devices[i].address),
                      onTap: () => _connectToDevice(controller.devices[i]),
                    ),
                  ),
                ),
              Padding(
                padding: EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: controller.isInitialized.value
                          ? () => wirelessManager.startDiscovery()
                          : null,
                      child: Text('Scan'),
                    ),
                    ElevatedButton(
                      onPressed: controller.isConnected.value
                          ? () => _toggleTalk()
                          : null,
                      child:
                          Text(controller.isTalking.value ? 'Release' : 'Talk'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            controller.isTalking.value ? Colors.red : null,
                      ),
                    ),
                    ElevatedButton(
                      onPressed: controller.isConnected.value
                          ? wirelessManager.disconnect
                          : null,
                      child: Text('Disconnect'),
                    ),
                  ],
                ),
              ),
            ],
          )),
    );
  }

  void _connectToDevice(WirelessDevice device) async {
    try {
      await wirelessManager.connect(device);
      controller.status.value = 'Connected to ${device.name}';
      controller.isConnected.value = true;
    } catch (e) {
      Get.snackbar('Connection Error', 'Failed to connect: $e');
    }
  }

  void _toggleTalk() {
    if (controller.isTalking.value) {
      wirelessManager.stopAudio();
      controller.isTalking.value = false;
    } else {
      wirelessManager.startAudio();
      controller.isTalking.value = true;
    }
  }

  @override
  void dispose() {
    wirelessManager.dispose();
    super.dispose();
  }
}

class WirelessDevice {
  final String name;
  final String address;
  final int port;

  WirelessDevice(
      {required this.name, required this.address, required this.port});

  factory WirelessDevice.fromJson(Map<String, dynamic> json) {
    return WirelessDevice(
      name: json['name'],
      address: json['address'],
      port: json['port'],
    );
  }
}

class WirelessManager {
  static const int port = 63007;
  RawDatagramSocket? _udpSocket;
  ServerSocket? _tcpServer;
  Socket? _clientSocket;
  final StreamController<WirelessDevice> _discoveryController =
      StreamController.broadcast();
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();
  String? _localAddress;
  Timer? _reconnectTimer;
  final controller = Get.find<WalkieTalkieController>();
  final _audioSinkController = StreamController<Uint8List>.broadcast();

  Stream<WirelessDevice> get discoveredDevices => _discoveryController.stream;

  Future<void> initialize() async {
    try {
      await _requestPermissions();
      await _recorder.openRecorder();
      await _player.openPlayer();
      await _startTcpServer();
      await _startUdpListener();
    } catch (e) {
      print('Error initializing: $e');
      _attemptRecovery();
    }
  }

  Future<void> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,
      Permission.microphone,
      Permission.storage,
    ].request();

    if (statuses.values.any((status) => !status.isGranted)) {
      throw Exception('Required permissions not granted');
    }
  }

  Future<void> _startTcpServer() async {
    try {
      _tcpServer = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      _tcpServer!.listen(_handleConnection);
    } catch (e) {
      print('TCP server error: $e');
      _attemptRecovery();
    }
  }

  void _handleConnection(Socket socket) {
    _clientSocket = socket;
    controller.status.value = 'Connected to ${socket.remoteAddress.address}';
    controller.isConnected.value = true;

    socket.listen(
      (data) => _playAudio(Uint8List.fromList(data)),
      onError: (e) {
        print('Connection error: $e');
        _attemptRecovery();
      },
      onDone: () {
        controller.status.value = 'Disconnected';
        controller.isConnected.value = false;
        _attemptReconnect();
      },
    );
  }

  Future<void> _startUdpListener() async {
    try {
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
      _udpSocket!.joinMulticast(InternetAddress('239.255.255.250'));
      _udpSocket!.listen(_handleUdpEvent);
    } catch (e) {
      print('UDP error: $e');
      _attemptRecovery();
    }
  }

  void _handleUdpEvent(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      final packet = _udpSocket!.receive();
      if (packet != null) {
        try {
          final json = jsonDecode(String.fromCharCodes(packet.data));
          final device = WirelessDevice.fromJson(json);
          _discoveryController.add(device);
        } catch (e) {
          print('Datagram error: $e');
        }
      }
    }
  }

  void startDiscovery() async {
    try {
      final wifiInfo = WifiInfo();
      _localAddress = await wifiInfo.getWifiIP();
      final deviceName = Platform.localHostname ?? 'Unknown Device';
      final message = jsonEncode({
        'type': 1,
        'address': _localAddress,
        'name': deviceName,
        'port': port
      });

      final addresses = await NetworkInterface.list();
      for (final interface in addresses) {
        for (final addr in interface.addresses) {
          final broadcast = InternetAddress(
              '${addr.address.split('.').take(3).join('.')}.255');
          _udpSocket!.send(message.codeUnits, broadcast, port);
        }
      }
    } catch (e) {
      print('Discovery error: $e');
      Get.snackbar('Discovery Error', 'Failed to scan: $e');
      _attemptRecovery();
    }
  }

  Future<void> connect(WirelessDevice device) async {
    try {
      _clientSocket = await Socket.connect(device.address, device.port)
          .timeout(Duration(seconds: 5));
      _handleConnection(_clientSocket!);
    } catch (e) {
      print('Connection error: $e');
      _attemptRecovery();
      rethrow;
    }
  }

  void startAudio() async {
    try {
      await _recorder.startRecorder(
        codec: Codec.pcm16,
        sampleRate: 16000,
        toStream: _audioSinkController.sink, // Use Uint8List sink
      );
      _audioSinkController.stream.listen((buffer) {
        if (_clientSocket != null && buffer != null) {
          _clientSocket!.add(buffer);
        }
      });
    } catch (e) {
      print('Audio start error: $e');
      Get.snackbar('Audio Error', 'Failed to start recording: $e');
      _attemptRecovery();
    }
  }

  void stopAudio() async {
    try {
      await _recorder.stopRecorder();
    } catch (e) {
      print('Audio stop error: $e');
      Get.snackbar('Audio Error', 'Failed to stop recording: $e');
    }
  }

  void _playAudio(Uint8List data) async {
    try {
      await _player.startPlayerFromStream(
        codec: Codec.pcm16,
        whenFinished: () {},
      );
      await _player.feedFromStream(data);
    } catch (e) {
      print('Playback error: $e');
      Get.snackbar('Audio Error', 'Failed to play audio: $e');
    }
  }

  void disconnect() {
    _clientSocket?.destroy();
    controller.status.value = 'Disconnected';
    controller.isConnected.value = false;
    controller.isTalking.value = false;
    stopAudio();
  }

  void _attemptRecovery() {
    controller.status.value = 'Error occurred - Attempting recovery';
    controller.isInitialized.value = false;
    Future.delayed(Duration(seconds: 2), () async {
      await initialize();
      controller.isInitialized.value = true;
      controller.status.value = 'Disconnected';
    });
  }

  void _attemptReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(Duration(seconds: 5), (timer) {
      if (!controller.isConnected.value && controller.devices.isNotEmpty) {
        connect(controller.devices.last);
      } else {
        timer.cancel();
      }
    });
  }

  void dispose() {
    _udpSocket?.close();
    _tcpServer?.close();
    _clientSocket?.destroy();
    _recorder.closeRecorder();
    _player.closePlayer();
    _discoveryController.close();
    _audioSinkController.close();
    _reconnectTimer?.cancel();
  }
}
