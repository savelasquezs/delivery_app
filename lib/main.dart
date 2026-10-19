import 'dart:async';
import 'features/lunch/employee_lunch_control.dart';
import 'package:flutter/foundation.dart';

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
import 'core/auth/auth_session_bridge.dart';
import 'core/storage/secure_storage.dart';
import 'core/version/delivery_app_version.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/presentation/auth_notifier.dart';
import 'features/notifications/fcm_service.dart';
import 'features/notifications/tracking_review_dialog.dart';
import 'features/tracking/location_tracking_service.dart';
import 'features/orders/data/order_repository.dart';
import 'features/route/presentation/route_notifier.dart';
import 'features/route/presentation/return_delivery_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Remove the obsolete stored assignment password without blocking startup.
  unawaited(SecureStorage().deleteObsoleteSelfAssignPassword().catchError(
    (Object error) {
      debugPrint('Could not clear obsolete assignment credential: $error');
    },
  ));

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
  Map<String, dynamic>? _pendingReturnReview;
  final Set<String> _dismissedReturnReviews = {};

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
        _pendingReturnReview = null;
        _dismissedReturnReviews.clear();
        _pendingReviewNotices.clear();
        _queuedReviewAlertIds.clear();
      } else if (next.status == AuthStatus.updateRequired) {
        _pendingReturnReview = null;
        _dismissedReturnReviews.clear();
        _pendingReviewNotices.clear();
        _queuedReviewAlertIds.clear();
        if (_reviewDialogOpen) rootNavigatorKey.currentState?.pop();
      }
    });
    if (!kIsWeb) FlutterForegroundTask.addTaskDataCallback(_onTrackingTaskData);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(FcmService.emitPendingTrackingReviewNotices());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reviewSubscription?.cancel();
    if (!kIsWeb)
      FlutterForegroundTask.removeTaskDataCallback(_onTrackingTaskData);
    super.dispose();
  }

  void _onTrackingTaskData(Object data) {
    if (data is! Map) return;
    final json = Map<String, dynamic>.from(data);
    if (json['type'] == 'route_return_review') {
      unawaited(_queueReturnReview(json));
      return;
    }
    if (json['type'] == 'tracking_session_ended') {
      unawaited(_onTrackingSessionEnded(json['sessionId']?.toString()));
      return;
    }
    if (json['type'] != deliveryAppUpdateRequiredCode) return;
    notifyDeliveryAppUpdateRequired(
      DeliveryAppVersionPolicy.fromJson(json),
    );
  }

  Future<void> _queueReturnReview(Map<String, dynamic> json) async {
    final session = await SecureStorage().readSession();
    if (!mounted || session == null || session.id != json['sessionId']) return;
    final raw = json['review'];
    if (raw is! Map) return;
    final review = Map<String, dynamic>.from(raw);
    final ids = (review['pendingOrderIds'] as List? ?? [])
        .whereType<int>()
        .where((id) => id > 0)
        .toSet()
        .toList()
      ..sort();
    if (ids.isEmpty ||
        review['routeId'] is! int ||
        review['returnLocationId'] is! int) return;

    final key = "${review['routeId']}:${ids.join(',')}";
    if (_dismissedReturnReviews.contains(key)) return;
    _pendingReturnReview = {
      ...review,
      'pendingOrderIds': ids,
      'key': key,
      'sessionId': session.id,
    };
    _scheduleNextTrackingReview();
  }

  Future<void> _showPendingReturnReview() async {
    final review = _pendingReturnReview;
    if (review == null ||
        _reviewDialogOpen ||
        _dismissedReturnReviews.contains(review['key'])) return;
    if (ref.read(authNotifierProvider).status != AuthStatus.authenticated)
      return;
    final context = rootNavigatorKey.currentContext;
    if (context == null ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed)
      return;
    final session = await SecureStorage().readSession();
    if (!mounted ||
        !context.mounted ||
        session?.id != review['sessionId'] ||
        _reviewDialogOpen) return;

    _reviewDialogOpen = true;
    try {
      await showReturnDeliveryDialog(
        context,
        orderIds: List<int>.from(review['pendingOrderIds'] as List),
        onConfirm: (ids) async {
          final latestSession = await SecureStorage().readSession();
          if (!mounted || latestSession?.id != review['sessionId']) {
            throw StateError('La sesión cambió.');
          }
          await ref.read(orderRepositoryProvider).confirmReturnedOrders(
                routeId: review['routeId'] as int,
                returnLocationId: review['returnLocationId'] as int,
                orderIds: ids,
              );
          if (mounted) {
            await ref
                .read(routeNotifierProvider.notifier)
                .load(silently: true, ensureFresh: true);
          }
        },
      );
      _dismissedReturnReviews.add(review['key'] as String);
      if (_pendingReturnReview?['key'] == review['key']) {
        _pendingReturnReview = null;
      }
    } finally {
      _reviewDialogOpen = false;
      if (mounted) _scheduleNextTrackingReview();
    }
  }

  Future<void> _onTrackingSessionEnded(String? oldSessionId) async {
    try {
      final current = await SecureStorage().readSession();
      if (!mounted || (current != null && current.id != oldSessionId)) return;
      notifyAuthSessionInvalidatedByApi(
          'Tu sesión requiere autenticación. Inicia sesión nuevamente.');
    } catch (_) {
      // Do not sign out a newer session because a storage read failed.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleNextTrackingReview();
      unawaited(FcmService.emitPendingTrackingReviewNotices());
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
    if (!mounted || _reviewDialogOpen) return;
    if (_pendingReviewNotices.isEmpty) {
      await _showPendingReturnReview();
      return;
    }
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
      builder: (context, child) => EmployeeLunchGate(child: child ?? const SizedBox.shrink()),
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
