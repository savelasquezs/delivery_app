import 'package:shared_preferences/shared_preferences.dart';

const _kDismissedRemoteBuild = 'delivery_app_dismissed_update_build';

Future<int?> getDismissedUpdateRemoteBuild() async {
  final p = await SharedPreferences.getInstance();
  if (!p.containsKey(_kDismissedRemoteBuild)) return null;
  return p.getInt(_kDismissedRemoteBuild);
}

Future<void> setDismissedUpdateRemoteBuild(int remoteBuildNumber) async {
  final p = await SharedPreferences.getInstance();
  await p.setInt(_kDismissedRemoteBuild, remoteBuildNumber);
}
