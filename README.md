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

### Celular conectado por USB

La base de pruebas `senor_arroz_delivery_dev` está en el contenedor
`senorarroz-delivery-postgres`, puerto local `15433`, con volumen persistente.
La API se inicia desde `senorArrozAPI/scripts/start-delivery-local.ps1` y usa
credenciales locales guardadas en .NET User Secrets (`senor-arroz-delivery-local`).

```powershell
adb reverse tcp:5000 tcp:5000
flutter run -d <device-id> --dart-define=API_BASE_URL=http://127.0.0.1:5000/api --dart-define=SIGNALR_HUB_URL=http://127.0.0.1:5000/hubs/orders
```

Los parámetros prevalecen sobre `.env` y no cambian la configuración de publicación.
HTTP está permitido únicamente en el manifest Debug. Mantener USB conectado;
después de reconectarlo puede ser necesario repetir `adb reverse`.

`senorArrozAPI/scripts/seed-delivery-local.sql` crea usuarios de pruebas y seis
pedidos listos más dos en preparación. Exige el parámetro psql `test_password` y
rechaza cualquier otra base. El domiciliario es `domiciliario@pruebas.local`.
Para obtener propuestas necesita iniciar jornada y GPS confiable cerca de la sede;
sin capacidad confirmada se conserva la selección manual. Google está desactivado
en este entorno: distancias y tiempos se estiman con la matriz local.

# Depuración web local

La entrada `lib/main_web.dart` comparte las pantallas, autenticación, API y SignalR
con Android. Solo permite una API en localhost. Usa un domiciliario de pruebas
distinto al del celular para conservar su sesión exclusiva.

```powershell
flutter build web --debug --no-wasm-dry-run -t lib/main_web.dart --dart-define=API_BASE_URL=http://127.0.0.1:5000/api --dart-define=SIGNALR_HUB_URL=http://127.0.0.1:5000/hubs/orders
python -m http.server 8088 --bind 127.0.0.1 --directory build/web
```

Abrir http://127.0.0.1:8088. El script local de la API autoriza ese origen.
La entrada web de desarrollo carga bootstrap y código con una clave por recarga
y no registra service worker, para evitar probar una compilación anterior en caché.
Web permite consultar pedidos, propuestas y warnings; no inicia jornadas, no
publica GPS ni habilita entregas. Los domiciliarios simulados necesitan puntos
GPS recientes en la base local para aportar capacidad al planificador.
`senorArrozAPI/scripts/reset-delivery-local-routing.sql` renueva únicamente los
tiempos de los pedidos de prueba sin asignar y el GPS de los cuatro domiciliarios
de este escenario. Conserva pedidos aceptados e históricos y rechaza otras bases.
Android conserva Firebase, seguimiento y coordinación SQLite entre isolates.

Para mantener la prueba con cuatro domiciliarios, iniciar la API local con
`scripts/start-delivery-local.ps1 -SimulateRouting` desde `senorArrozAPI`.
El simulador dura dos horas y emite GPS cada minuto exclusivamente para los tres
domiciliarios ficticios libres con jornada activa; se detiene para quien tenga
pedidos o ruta asignados. El celular conserva su GPS real. No reinicia los tiempos
de los pedidos; el script de reinicio anterior permite empezar otro escenario.

<!-- Re-dispatch Google Play internal publication after switching repository visibility to public (2026-10-19). -->
