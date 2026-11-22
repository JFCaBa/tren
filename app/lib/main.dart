import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'app_controller.dart';
import 'data/alerts.dart';
import 'data/positions.dart';
import 'data/realtime.dart';
import 'data/train_client.dart';
import 'follow/follow_service.dart';
import 'follow/follow_tracker.dart';
import 'follow/follower.dart';
import 'follow/live_activity.dart';
import 'follow/push_follower.dart';
import 'follow/push_token.dart';
import 'location.dart';
import 'ui/home_screen.dart';
import 'widget/next_trains_widget.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  tzdata.initializeTimeZones();
  final client = http.Client();
  final prefs = await SharedPreferences.getInstance();
  final controller = AppController(
    client,
    await getApplicationSupportDirectory(),
    RealtimeClient(client),
    GeolocatorLocationSource(),
    prefs,
    positions: PositionsClient(client),
    alerts: AlertsClient(client),
  );
  // Android follows in a foreground service; iOS asks our server to follow and push.
  final Follower? follower = kIsWeb
      ? null
      : Platform.isAndroid
          ? await FollowService.create()
          : Platform.isIOS
              ? await PushFollower.create(
                  client: client, prefs: prefs, push: const ChannelPushToken(), activity: ChannelLiveActivity())
              : null;
  final tracker = follower == null ? null : FollowTracker(follower: follower, fetch: TrainClient(client).fetch);
  if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
    if (Platform.isIOS) await HomeWidget.setAppGroupId(widgetAppGroup);
    final publisher = WidgetPublisher();
    // The home screen widget shows the board of the last station opened.
    controller.addListener(() => publisher.publish(controller.station?.name, controller.widgetBoard, controller.now(),
        via: controller.via == null ? null : (controller.viaName ?? controller.via), rtAt: controller.rt?.fetchedAt));
  }
  runApp(ProximoTrenApp(controller: controller, follower: follower, tracker: tracker));
}

class ProximoTrenApp extends StatefulWidget {
  const ProximoTrenApp({super.key, required this.controller, this.follower, this.tracker});
  final AppController controller;
  final Follower? follower;
  final FollowTracker? tracker;

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
    if (state == AppLifecycleState.resumed) {
      widget.controller.onResume();
      widget.follower?.sync();
      widget.tracker?.onForeground();
    }
    if (state == AppLifecycleState.paused) {
      widget.controller.onPause();
      widget.tracker?.onBackground();
    }
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0F766E); // the icon's teal
    return MaterialApp(
      title: 'Andén',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: HomeScreen(controller: widget.controller, follower: widget.follower, tracker: widget.tracker),
    );
  }
}
