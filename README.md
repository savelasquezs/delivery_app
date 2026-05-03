# delivery_app — domiciliarios (Señor Arroz)

**Versión actual:** ver `pubspec.yaml` (`version: x.y.z+build`). Historial y notas de cada release: [`CHANGELOG.md`](CHANGELOG.md).

## Generar el APK para `senorArrozFront/public`

El front ya sirve el manifiesto `public/delivery-app-release.json` y el archivo `public/senor-arroz-domiciliarios.apk`. Solo hace falta compilar y copiar el APK.

**Opción A — script (desde la raíz del repo):**

```bash
bash Scripts/build_delivery_app_apk.sh
```

**Opción B — manual:**

```bash
cd delivery_app
flutter pub get
flutter build apk --release
```

Luego copia `delivery_app/build/app/outputs/flutter-apk/app-release.apk` a  
`senorArrozFront/public/senor-arroz-domiciliarios.apk` (sobrescribe el anterior).

Antes de desplegar el front, alinea **versión** en `delivery_app/pubspec.yaml` (`x.y.z+build`) con `versionName` / `buildNumber` en `senorArrozFront/public/delivery-app-release.json`.

**Firma:** con `android/key.properties` y keystore para release; sin eso, el APK release usa firma debug (solo pruebas).

## Desarrollo

```bash
cd delivery_app
flutter pub get
flutter run
```

Configura `.env` según `.env.example` (`API_BASE_URL`, `SIGNALR_HUB_URL`, etc.).

**Aviso de actualización APK:** por defecto la app consulta `https://senorarroz.up.railway.app/delivery-app-release.json` (mismo JSON que `senorArrozFront/public/`). Para otro entorno (local, staging), define `DELIVERY_APP_UPDATE_MANIFEST_URL` en `.env`.
