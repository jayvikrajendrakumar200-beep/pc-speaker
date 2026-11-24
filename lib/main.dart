import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initNotifications();
  await _requestPermissions();
  runApp(ChangeNotifierProvider(create: (_) => AppState(), child: const PCSpeakerApp()));
}

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
final AudioRecorder _audioRecorder = AudioRecorder();

Future<void> _initNotifications() async {
  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings initializationSettingsIOS = DarwinInitializationSettings(
    requestAlertPermission: true, requestBadgePermission: true, requestSoundPermission: true,
  );
  await flutterLocalNotificationsPlugin.initialize(const InitializationSettings(
    android: initializationSettingsAndroid, iOS: initializationSettingsIOS,
  ));
}

Future<void> _requestPermissions() async {
  await Permission.microphone.request();
  await Permission.notification.request();
}

class AppState extends ChangeNotifier {
  String _status = 'Disconnected';
  String _connectionMode = 'WiFi'; // 'WiFi' or 'USB'
  bool _isPlaying = false;
  bool _isRecording = false;
  bool _isBuffering = false;
  double _volume = 1.0;
  double _micGain = 1.0;
  String? _lastError;
  String _pcIp = '';
  String _pcPort = '8080';
  String _wsPort = '8081';
  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSubscription;

  String get status => _status;
  String get connectionMode => _connectionMode;
  bool get isPlaying => _isPlaying;
  bool get isRecording => _isRecording;
  bool get isBuffering => _isBuffering;
  double get volume => _volume;
  double get micGain => _micGain;
  String? get lastError => _lastError;
  String get pcIp => _pcIp;
  String get pcPort => _pcPort;
  String get wsPort => _wsPort;
  String get httpUrl => 'http://$_pcIp:$_pcPort/stream';
  String get wsUrl => 'ws://$_pcIp:$_wsPort/ws';

  bool get isConnected => _status != 'Disconnected' && _status != 'Connection failed';

  void setConnectionMode(String mode) { _connectionMode = mode; notifyListeners(); }
  void setPcIp(String ip) { _pcIp = ip; notifyListeners(); }
  void setPcPort(String port) { _pcPort = port; notifyListeners(); }
  void setWsPort(String port) { _wsPort = port; notifyListeners(); }

  void updateStatus(String status) { _status = status; notifyListeners(); }
  void setPlaying(bool v) { _isPlaying = v; notifyListeners(); }
  void setRecording(bool v) { _isRecording = v; notifyListeners(); }
  void setBuffering(bool v) { _isBuffering = v; notifyListeners(); }
  void setVolume(double v) { _volume = v; notifyListeners(); }
  void setMicGain(double v) { _micGain = v; notifyListeners(); }
  void setError(String? e) { _lastError = e; notifyListeners(); }

  void setWsChannel(WebSocketChannel? channel) {
    _wsChannel?.sink.close();
    _wsSubscription?.cancel();
    _wsChannel = channel;
    if (channel != null) {
      _wsSubscription = channel.stream.listen(
        (msg) => _handleWsMessage(msg),
        onError: (e) => setError('WS error: $e'),
        onDone: () => setError('WebSocket disconnected'),
      );
    }
  }

  void _handleWsMessage(dynamic msg) {
    // Handle PC->phone messages (volume sync, commands, etc)
  }

  void sendWsMessage(Map<String, dynamic> msg) {
    _wsChannel?.sink.add(jsonEncode(msg));
  }

  void disposeWs() {
    _wsSubscription?.cancel();
    _wsChannel?.sink.close();
    _wsChannel = null;
  }
}

class PCSpeakerApp extends StatelessWidget {
  const PCSpeakerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PC Speaker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0066CC))),
      darkTheme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0066CC), brightness: Brightness.dark)),
      themeMode: ThemeMode.system,
      home: const SpeakerHomePage(),
    );
  }
}

class SpeakerHomePage extends StatefulWidget {
  const SpeakerHomePage({super.key});
  @override State<SpeakerHomePage> createState() => _SpeakerHomePageState();
}

class _SpeakerHomePageState extends State<SpeakerHomePage> {
  final AudioPlayer _player = AudioPlayer();
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _httpPortController = TextEditingController(text: '8080');
  final TextEditingController _wsPortController = TextEditingController(text: '8081');

  StreamSubscription? _playerStateSubscription;
  StreamSubscription? _bufferingSubscription;
  StreamSubscription? _recordingStreamSubscription;
  static const String _prefsIpKey = 'server_ip';
  static const String _prefsHttpPortKey = 'server_http_port';
  static const String _prefsWsPortKey = 'server_ws_port';
  static const String _prefsModeKey = 'connection_mode';

  @override void initState() {
    super.initState();
    _loadSavedSettings();
    _initAudioSession();
    _setupPlayerListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<AppState>().setWsPort(_wsPortController.text));
  }

  Future<void> _loadSavedSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _ipController.text = prefs.getString(_prefsIpKey) ?? '';
      _httpPortController.text = prefs.getString(_prefsHttpPortKey) ?? '8080';
      _wsPortController.text = prefs.getString(_prefsWsPortKey) ?? '8081';
    });
    context.read<AppState>().setConnectionMode(prefs.getString(_prefsModeKey) ?? 'WiFi');
    context.read<AppState>().setPcIp(_ipController.text);
    context.read<AppState>().setPcPort(_httpPortController.text);
    context.read<AppState>().setWsPort(_wsPortController.text);
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsIpKey, _ipController.text.trim());
    await prefs.setString(_prefsHttpPortKey, _httpPortController.text.trim());
    await prefs.setString(_prefsWsPortKey, _wsPortController.text.trim());
    await prefs.setString(_prefsModeKey, context.read<AppState>().connectionMode);
  }

  Future<void> _initAudioSession() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.mixWithOthers | AVAudioSessionCategoryOptions.allowBluetooth,
      avAudioSessionMode: AVAudioSessionMode.defaultMode,
    ));
    await session.setActive(true);
  }

  void _setupPlayerListeners() {
    _playerStateSubscription = _player.playerStateStream.listen((state) {
      if (mounted) {
        context.read<AppState>().setPlaying(state.playing);
        context.read<AppState>().setBuffering(state.processingState == ProcessingState.buffering);
        String newStatus;
        switch (state.processingState) {
          case ProcessingState.idle: newStatus = 'Disconnected'; break;
          case ProcessingState.loading: newStatus = 'Connecting...'; break;
          case ProcessingState.buffering: newStatus = 'Buffering...'; break;
          case ProcessingState.ready: newStatus = 'Playing'; break;
          case ProcessingState.completed: newStatus = 'Stream ended'; break;
        }
        context.read<AppState>().updateStatus(newStatus);
      }
    });
  }

  String get _streamUrl => 'http://${_ipController.text.trim()}:${_httpPortController.text.trim()}/stream';

  Future<void> _connect() async {
    if (_ipController.text.trim().isEmpty && context.read<AppState>().connectionMode == 'WiFi') {
      _showError('Enter PC IP address');
      return;
    }
    await _saveSettings();
    context.read<AppState>().setError(null);
    context.read<AppState>().updateStatus('Connecting...');

    try {
      final state = context.read<AppState>();
      state.setPcIp(_ipController.text.trim());
      state.setPcPort(_httpPortController.text.trim());
      state.setWsPort(_wsPortController.text.trim());

      // Connect WebSocket for mic/control
      final wsChannel = WebSocketChannel.connect(Uri.parse(state.wsUrl));
      state.setWsChannel(wsChannel);

      // Start audio playback
      await _player.setUrl(state.httpUrl);
      await _player.setVolume(state.volume);
      await _player.play();

      _showNotification('Connected', 'Streaming from ${state.httpUrl}');
    } catch (e) {
      _showError('Connection failed: $e');
      context.read<AppState>().updateStatus('Connection failed');
    }
  }

  Future<void> _disconnect() async {
    await _player.stop();
    await _player.setUrl('');
    context.read<AppState>().disposeWs();
    context.read<AppState>().updateStatus('Disconnected');
    context.read<AppState>().setPlaying(false);
    _cancelNotification();
    if (context.read<AppState>().isRecording) await _toggleMic();
  }

  Future<void> _togglePlayPause() async {
    if (context.read<AppState>().isPlaying) await _player.pause(); else await _player.play();
  }

  Future<void> _toggleMic() async {
    final state = context.read<AppState>();
    if (state.isRecording) {
      await _audioRecorder.stop();
      state.sendWsMessage({'type': 'mic_stop'});
      state.setRecording(false);
    } else {
      if (!await _audioRecorder.hasPermission()) {
        _showError('Microphone permission denied');
        return;
      }
      try {
        final stream = await _audioRecorder.startStream(const RecordConfig(
          encoder: AudioEncoder.opus, // Low latency, good quality
          sampleRate: 48000,
          bitRate: 64000,
          numChannels: 1,
        ));
        state.sendWsMessage({'type': 'mic_start', 'config': {'sampleRate': 48000, 'channels': 1}});
        _recordingStreamSubscription = stream.listen((chunk) {
          state.sendWsMessage({'type': 'mic_data', 'data': base64Encode(chunk)});
        }, onError: (e) => _showError('Mic error: $e'));
        state.setRecording(true);
      } catch (e) {
        _showError('Failed to start mic: $e');
      }
    }
  }

  void _showError(String msg) {
    context.read<AppState>().setError(msg);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  Future<void> _showNotification(String title, String body) async {
    await flutterLocalNotificationsPlugin.show(1, title, body, const NotificationDetails(
      android: AndroidNotificationDetails('pc_speaker', 'PC Speaker', importance: Importance.low, priority: Priority.low, ongoing: true, autoCancel: false),
      iOS: DarwinNotificationDetails(presentAlert: false, presentBadge: true),
    ));
  }

  Future<void> _cancelNotification() async => await flutterLocalNotificationsPlugin.cancel(1);

  @override void dispose() {
    _playerStateSubscription?.cancel();
    _bufferingSubscription?.cancel();
    _recordingStreamSubscription?.cancel();
    _player.dispose();
    _audioRecorder.dispose();
    context.read<AppState>().disposeWs();
    _ipController.dispose();
    _httpPortController.dispose();
    _wsPortController.dispose();
    _cancelNotification();
    super.dispose();
  }

  @override Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final colorScheme = Theme.of(context).colorScheme;
    final isConnected = state.isConnected;

    return Scaffold(
      appBar: AppBar(title: const Text('PC Speaker'), actions: [
        IconButton(icon: const Icon(Icons.info_outline), onPressed: _showHelpDialog, tooltip: 'Help'),
      ]),
      body: SafeArea(child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Connection Mode Selector
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Connection Mode', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'WiFi', label: Text('WiFi'), icon: Icon(Icons.wifi)),
                  ButtonSegment(value: 'USB', label: Text('USB (usbmuxd)'), icon: Icon(Icons.usb)),
                ],
                selected: {state.connectionMode},
                onSelectionChange: (s) => state.setConnectionMode(s.first),
              ),
            ],
          ))),

          const SizedBox(height: 16),

          // Server Settings
          Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('PC Server', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              if (state.connectionMode == 'WiFi') ...[
                TextField(controller: _ipController, decoration: const InputDecoration(
                  labelText: 'PC IP Address', hintText: '192.168.1.XXX', prefixIcon: Icon(Icons.computer), border: OutlineInputBorder(),
                  helperText: 'Run "ipconfig" on PC',),
                  keyboardType: TextInputType.numberWithOptions(decimal: true),
                  onChanged: (v) => state.setPcIp(v),),
                const SizedBox(height: 12),
              ] else ...[
                // USB mode - IP is fixed via usbmuxd
                InputDecorator(decoration: const InputDecoration(labelText: 'PC IP Address', prefixIcon: Icon(Icons.usb), border: OutlineInputBorder()),
                  child: Text(state.connectionMode == 'USB' ? 'Auto (usbmuxd tunnel)' : '', style: Theme.of(context).textTheme.bodyMedium)),
                const SizedBox(height: 8),
                Text('Connect iPhone via USB. Run on PC: ', style: Theme.of(context).textTheme.bodySmall),
                SelectableText('python -m usbmuxd_tunnel 8080 8080', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
                const SizedBox(height: 8),
                Text('Then iPhone accesses PC at http://localhost:8080', style: Theme.of(context).textTheme.bodySmall),
              ],
              Row(children: [
                Expanded(child: TextField(controller: _httpPortController, decoration: const InputDecoration(labelText: 'HTTP Port', hintText: '8080', border: OutlineInputBorder()),
                  keyboardType: TextInputType.number, onChanged: (v) => state.setPcPort(v),)),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: _wsPortController, decoration: const InputDecoration(labelText: 'WS Port', hintText: '8081', border: OutlineInputBorder()),
                  keyboardType: TextInputType.number, onChanged: (v) => state.setWsPort(v),)),
              ]),
            ],
          ))),

          const SizedBox(height: 16),

          // Status Card
          Card(elevation: 2, child: Padding(padding: const EdgeInsets.all(20), child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(state.isBuffering ? Icons.sync : (isConnected ? Icons.wifi : Icons.wifi_off), size: 40,
                color: state.isBuffering ? Colors.orange : (isConnected ? colorScheme.primary : colorScheme.onSurfaceVariant)),
              if (state.isRecording) ...[const SizedBox(width: 8), const Icon(Icons.mic, size: 28, color: Colors.red)],
            ]),
            const SizedBox(height: 8),
            Text(state.status, style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: state.isBuffering ? Colors.orange : (isConnected ? colorScheme.primary : colorScheme.onSurfaceVariant),
              fontWeight: FontWeight.w600,
            )),
            if (state.isBuffering) ...[const SizedBox(height: 8), const CircularProgressIndicator()],
          ]))),

          const SizedBox(height: 20),

          // Main Controls
          Row(children: [
            Expanded(child: FilledButton.icon(
              icon: Icon(isConnected ? Icons.stop : Icons.play_arrow), label: Text(isConnected ? 'Disconnect' : 'Connect'),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: isConnected ? Colors.red : colorScheme.primary),
              onPressed: isConnected ? _disconnect : _connect,
            )),
            if (isConnected) ...[const SizedBox(width: 12), Expanded(child: OutlinedButton.icon(
              icon: Icon(state.isPlaying ? Icons.pause : Icons.play_arrow),
              label: Text(state.isPlaying ? 'Pause' : 'Resume'),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              onPressed: _togglePlayPause,
            ))],
          ]),

          const SizedBox(height: 16),

          // Microphone Toggle
          if (isConnected) ...[
            FilledButton.icon(
              icon: Icon(state.isRecording ? Icons.mic_off : Icons.mic),
              label: Text(state.isRecording ? 'Stop Mic Streaming' : 'Stream Mic to PC'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: state.isRecording ? Colors.red : colorScheme.secondary,
              ),
              onPressed: _toggleMic,
            ),
            const SizedBox(height: 16),
          ],

          // Volume Controls
          if (isConnected) ...[
            Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Playback Volume', style: Theme.of(context).textTheme.labelLarge),
                Row(children: [
                  Icon(Icons.volume_down, color: colorScheme.onSurfaceVariant),
                  Expanded(child: Slider(value: state.volume, min: 0, max: 1, divisions: 20,
                    label: '${(state.volume*100).round()}%', onChanged: (v) { state.setVolume(v); _player.setVolume(v); })),
                  Icon(Icons.volume_up, color: colorScheme.onSurfaceVariant),
                  Text('${(state.volume*100).round()}%', style: Theme.of(context).textTheme.bodyMedium),
                ]),
              ],
            ))),
            const SizedBox(height: 12),
            Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Mic Gain', style: Theme.of(context).textTheme.labelLarge),
                Row(children: [
                  Icon(Icons.mic_none, color: colorScheme.onSurfaceVariant),
                  Expanded(child: Slider(value: state.micGain, min: 0, max: 2, divisions: 20,
                    label: '${(state.micGain*100).round()}%', onChanged: (v) { state.setMicGain(v); state.sendWsMessage({'type': 'mic_gain', 'gain': v}); })),
                  Icon(Icons.mic, color: colorScheme.onSurfaceVariant),
                  Text('${(state.micGain*100).round()}%', style: Theme.of(context).textTheme.bodyMedium),
                ]),
              ],
            ))),
          ],

          const Spacer(),

          if (isConnected) Card(color: colorScheme.surfaceContainerHighest, child: Padding(padding: const EdgeInsets.all(12), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Stream URLs', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
              SelectableText('Audio: ${state.httpUrl}', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
              SelectableText('WS: ${state.wsUrl}', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
            ],
          ))),

          if (state.lastError != null) ...[const SizedBox(height: 8),
            Text(state.lastError!, style: const TextStyle(color: Colors.red, fontSize: 12), textAlign: TextAlign.center),
          ],
        ],
      ),
      )),
    );
  }

  void _showHelpDialog() => showDialog(context: context, builder: (c) => AlertDialog(
    title: const Text('Setup Guide'), content: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('1. Run Python server on PC:'), const SizedBox(height: 4),
        SelectableText('python pc_audio_server.py', style: const TextStyle(fontFamily: 'monospace')),
        const SizedBox(height: 16), const Text('2. Find PC IP (WiFi mode):'), const SizedBox(height: 4),
        const Text('Run "ipconfig" in Command Prompt. Use IPv4 address (e.g., 192.168.1.42)'),
        const SizedBox(height: 16), const Text('3. USB Mode (no WiFi needed):'), const SizedBox(height: 4),
        const Text('• Install usbmuxd on PC: pip install usbmuxd'), const SizedBox(height: 4),
        const Text('• Run tunnel: python -m usbmuxd_tunnel 8080 8081'), const SizedBox(height: 4),
        const Text('• Select "USB" mode in app, tap Connect'),
        const SizedBox(height: 16), const Text('4. Firewall: Allow Python on Private networks'),
        const SizedBox(height: 16), const Text('5. Mic audio appears as "PC Speaker Mic" input on PC'),
      ],
    )), actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
  ));
}