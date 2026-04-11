import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/notifications/fcm_service.dart';
import 'features/tracking/location_tracking_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize communication port for foreground task ↔ main isolate
  FlutterForegroundTask.initCommunicationPort();

  await Future.wait([
    dotenv.load(fileName: '.env'),
    initializeDateFormatting('es_CO'),
    Firebase.initializeApp(),
  ]);

  await FcmService.initialize();
  LocationTrackingService.initialize();

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF1E1E1E),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  runApp(const ProviderScope(child: WithForegroundTask(child: DeliveryApp())));
}

class DeliveryApp extends ConsumerWidget {
  const DeliveryApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'Señor Arroz',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      routerConfig: router,
      locale: const Locale('es', 'CO'),
      supportedLocales: const [
        Locale('es', 'CO'),
        Locale('es'),
        Locale('en'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
