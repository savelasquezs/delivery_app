import '../tracking/work_session_models.dart';

enum HomeResumeRefresh { available, route, none }

HomeResumeRefresh homeResumeRefreshForTab(int tabIndex) {
  return switch (tabIndex) {
    0 => HomeResumeRefresh.available,
    1 => HomeResumeRefresh.route,
    _ => HomeResumeRefresh.none,
  };
}

bool shouldConnectOrderHub({
  required bool authenticated,
  required DeliveryWorkSession? workSession,
  DateTime? nowUtc,
}) {
  if (!authenticated || workSession == null || !workSession.isActive) {
    return false;
  }
  return (nowUtc ?? DateTime.now().toUtc()).isBefore(workSession.autoCloseAt);
}
