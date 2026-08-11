# delivery_app — domiciliarios de Señor Arroz

## Distribución de producción

La aplicación se distribuye exclusivamente mediante Google Play con el paquete
`com.senorarroz.delivery_app`. El track actual es `internal`.

Cada push a `main` ejecuta `.github/workflows/publish-play-internal.yml`. El
workflow consulta los códigos ya publicados, elige el siguiente `versionCode`,
genera un App Bundle firmado y lo publica en Google Play Internal. Los celulares
reciben las actualizaciones desde Google Play.

El `versionName` se controla manualmente en `pubspec.yaml`. El valor después de
`+` es una base local; CI decide el build efectivo y no requiere cambios
manuales por commit.

La distribución mediante binarios externos está retirada y bloqueada. No se
generan APK release, no se copian artefactos Android al frontend y no existe un
JSON alterno de releases.

## Publicar cambios

Para un cambio normal, hacer commit y push a `main`. CI administra el build.

Para una nueva versión visible, por ejemplo `1.2.5` a `1.2.6`, cambiar:

```yaml
version: 1.2.6+11
```

Cuando esa versión deba ser obligatoria, actualizar también en Railway:

```text
DeliveryAppVersion__RequiredVersionName=1.2.6
```

Para exigir un hotfix sin cambiar la versión visible, aumentar
`DeliveryAppVersion__MinimumBuildNumber` al menor build permitido.

## Desarrollo

```bash
flutter pub get
flutter run
```

Configura `.env` con `API_BASE_URL` y `SIGNALR_HUB_URL`. La compilación de
producción autorizada es el App Bundle ejecutado por CI. El guard
`scripts/verify_play_only_distribution.sh` evita reintroducir el canal externo.

Historial: [CHANGELOG.md](CHANGELOG.md).
