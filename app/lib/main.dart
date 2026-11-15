import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'app_controller.dart';
import 'data/realtime.dart';
import 'location.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  tzdata.initializeTimeZones();
  final client = http.Client();
  final controller = AppController(
    client,
    await getApplicationSupportDirectory(),
    RealtimeClient(client),
    GeolocatorLocationSource(),
    await SharedPreferences.getInstance(),
  );
  runApp(ProximoTrenApp(controller: controller));
}

class ProximoTrenApp extends StatefulWidget {
  const ProximoTrenApp({super.key, required this.controller});
  final AppController controller;

  @override
  State<ProximoTrenApp> createState() => _ProximoTrenAppState();
}

class _ProximoTrenAppState extends State<ProximoTrenApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.controller.onResume();
    if (state == AppLifecycleState.paused) widget.controller.onPause();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF7AB3DE);
    return MaterialApp(
      title: 'Próximo Tren',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: HomeScreen(controller: widget.controller),
    );
  }
}
