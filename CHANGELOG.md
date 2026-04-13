# Historial de cambios — app domiciliarios

El número de build (`+N` en `pubspec.yaml`) debe coincidir con `buildNumber` en `senorArrozFront/public/delivery-app-release.json` al publicar un APK.

## [1.1.0] — 2026-04-13

### Añadido

- Script `Scripts/build_delivery_app_apk.sh` para generar el APK release y copiarlo a `senorArrozFront/public/senor-arroz-domiciliarios.apk`.
- Esta guía (`CHANGELOG.md`) y sección de versiones en `README.md`.

### Cambiado

- **SignalR / tiempo real:** reconexión al volver la app al primer plano (`AppLifecycleState.resumed`); segundo `postFrameCallback` tras el arranque para cuando la sesión aún no está lista; `ref.listen` sobre el estado de auth para conectar cuando aparece el usuario; registro único de listeners del hub; `OrderHubService.connect` usa el estado real del transporte (`HubConnectionState`) en lugar de confiar solo en el enum interno.
- **Mapa (elegir ubicación):** control con texto «Usar ubicación actual» además del icono GPS.

### Notas de publicación

- Tras subir de versión, ejecutar el script de APK (o build manual), desplegar el front y verificar que `delivery-app-release.json` expone el mismo `versionName` y `buildNumber`.

## [1.0.1] — build 2

- Cobro en efectivo y «Ya pagó» en historial y detalle; reimprimir desde la ruta; mejoras en edición de dirección / ubicación.
