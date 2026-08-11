enum HomeResumeRefresh { available, route, none }

HomeResumeRefresh homeResumeRefreshForTab(int tabIndex) {
  return switch (tabIndex) {
    0 => HomeResumeRefresh.available,
    1 => HomeResumeRefresh.route,
    _ => HomeResumeRefresh.none,
  };
}
