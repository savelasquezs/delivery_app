import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/presentation/auth_notifier.dart';
import 'features/notifications/fcm_service.dart';
import 'features/notifications/tracking_review_dialog.dart';
import 'features/tracking/location_tracking_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Registro único aquí (no en FcmService). Tras hot restart (R) FlutterFire puede avisar
  // "duplicate background isolate": para probar FCM usar arranque frío (detener app o `flutter run` de nuevo).
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  // Initialize communication port for foreground task ↔ main isolate
  FlutterForegroundTask.initCommunicationPort();

  await Future.wait([
    dotenv.load(fileName: '.env'),
    initializeDateFormatting('es_CO'),
    Firebase.initializeApp(),
  ]);

  await FcmService.initialize();
  LocationTrackingService.initialize();
  await LocationTrackingService.detectUnexpectedStop();

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

class DeliveryApp extends ConsumerStatefulWidget {
  const DeliveryApp({super.key});

  @override
  ConsumerState<DeliveryApp> createState() => _DeliveryAppState();
}

class _DeliveryAppState extends ConsumerState<DeliveryApp>
    with WidgetsBindingObserver {
  final List<DeliveryTrackingReviewNotice> _pendingReviewNotices = [];
  final Set<int> _queuedReviewAlertIds = {};
  StreamSubscription<DeliveryTrackingReviewNotice>? _reviewSubscription;
  bool _reviewDialogOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reviewSubscription =
        FcmService.trackingReviewNotices.listen(_queueTrackingReviewNotice);
    ref.listenManual<AuthState>(authNotifierProvider, (_, next) {
      if (next.status == AuthStatus.authenticated) {
        _scheduleNextTrackingReview();
      } else if (next.status == AuthStatus.unauthenticated) {
        _pendingReviewNotices.clear();
        _queuedReviewAlertIds.clear();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(FcmService.emitPendingTrackingReviewNotices());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reviewSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(FcmService.emitPendingTrackingReviewNotices());
      unawaited(
        ref
            .read(authNotifierProvider.notifier)
            .refreshSessionIfNeededAfterResume(),
      );
    }
  }

  void _queueTrackingReviewNotice(DeliveryTrackingReviewNotice notice) {
    if (!_queuedReviewAlertIds.add(notice.alertId)) return;
    _pendingReviewNotices.add(notice);
    _scheduleNextTrackingReview();
  }

  void _scheduleNextTrackingReview() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_showNextTrackingReview());
    });
  }

  Future<void> _showNextTrackingReview() async {
    if (!mounted || _reviewDialogOpen || _pendingReviewNotices.isEmpty) return;
    final authState = ref.read(authNotifierProvider);
    if (authState.status != AuthStatus.authenticated ||
        authState.user == null) {
      return;
    }

    final notice = _pendingReviewNotices.first;
    if (notice.deliverymanId != authState.user!.id) {
      _pendingReviewNotices.removeAt(0);
      _queuedReviewAlertIds.remove(notice.alertId);
      await FcmService.dismissTrackingReviewNotice(notice.alertId);
      _scheduleNextTrackingReview();
      return;
    }

    final dialogContext = rootNavigatorKey.currentContext;
    if (dialogContext == null) {
      _scheduleNextTrackingReview();
      return;
    }

    _reviewDialogOpen = true;
    try {
      await showTrackingReviewDialog(dialogContext, notice);
      await FcmService.dismissTrackingReviewNotice(notice.alertId);
      _pendingReviewNotices.removeAt(0);
      _queuedReviewAlertIds.remove(notice.alertId);
    } finally {
      _reviewDialogOpen = false;
      _scheduleNextTrackingReview();
    }
  }

  @override
  Widget build(BuildContext context) {
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
