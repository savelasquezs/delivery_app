{{flutter_js}}
{{flutter_build_config}}
for (const build of _flutter.buildConfig.builds) {
  build.mainJsPath += `?local=${Date.now()}`;
}
_flutter.loader.load();
