import 'package:delivery_app/features/home/home_resume_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('solo sincroniza la pestaña operativa activa al reanudar', () {
    expect(homeResumeRefreshForTab(0), HomeResumeRefresh.available);
    expect(homeResumeRefreshForTab(1), HomeResumeRefresh.route);
    expect(homeResumeRefreshForTab(2), HomeResumeRefresh.none);
    expect(homeResumeRefreshForTab(3), HomeResumeRefresh.none);
  });
}
