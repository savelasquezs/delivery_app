import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';

/// Coordenadas resultado del selector.
class MapPickedLocation {
  final double lat;
  final double lng;

  const MapPickedLocation(this.lat, this.lng);
}

/// Widget de selección de coordenadas con mapa OpenStreetMap.
///
/// Equivalente al `GoogleMapsSelector.vue` del front web:
/// - Toca el mapa → mueve el pin
/// - Botón GPS → usa posición actual
/// - Campo pegar URL de Google Maps → extrae coordenadas
/// - Confirmar → devuelve [MapPickedLocation]
class DeliveryMapPicker extends StatefulWidget {
  /// Posición inicial del pin (null = Medellín por defecto).
  final MapPickedLocation? initialLocation;

  /// Dirección textual usada solo como hint; no bloquea el flujo.
  final String? addressHint;

  const DeliveryMapPicker({
    super.key,
    this.initialLocation,
    this.addressHint,
  });

  @override
  State<DeliveryMapPicker> createState() => _DeliveryMapPickerState();
}

class _DeliveryMapPickerState extends State<DeliveryMapPicker> {
  static const _defaultCenter = LatLng(6.2442, -75.5812); // Medellín

  late final MapController _mapCtrl;
  LatLng? _pin;
  bool _gpsLoading = false;
  String? _gpsError;

  final _urlCtrl = TextEditingController();
  String? _urlError;

  @override
  void initState() {
    super.initState();
    _mapCtrl = MapController();
    if (widget.initialLocation != null) {
      _pin = LatLng(widget.initialLocation!.lat, widget.initialLocation!.lng);
    }
  }

  @override
  void dispose() {
    _mapCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  // ── Extraer coords de URL de Google Maps (mismo algoritmo del front) ──
  MapPickedLocation? _parseGoogleMapsUrl(String raw) {
    final url = raw.trim();
    if (url.isEmpty) return null;
    String decoded = url;
    try {
      decoded = Uri.decodeFull(url);
    } catch (_) {}
    // Pin: !3d<lat>!4d<lng>
    final pinMatch = RegExp(r'!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)').firstMatch(decoded);
    if (pinMatch != null) {
      final lat = double.tryParse(pinMatch.group(1)!);
      final lng = double.tryParse(pinMatch.group(2)!);
      if (lat != null && lng != null) return MapPickedLocation(lat, lng);
    }
    // Centro de vista: @lat,lng
    final atMatch = RegExp(r'@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)').firstMatch(decoded);
    if (atMatch != null) {
      final lat = double.tryParse(atMatch.group(1)!);
      final lng = double.tryParse(atMatch.group(2)!);
      if (lat != null && lng != null) return MapPickedLocation(lat, lng);
    }
    return null;
  }

  bool _validCoords(double lat, double lng) =>
      lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;

  void _applyUrl() {
    final text = _urlCtrl.text.trim();
    if (text.isEmpty) {
      setState(() => _urlError = 'Pega un enlace de Google Maps.');
      return;
    }
    final loc = _parseGoogleMapsUrl(text);
    if (loc == null || !_validCoords(loc.lat, loc.lng)) {
      setState(() => _urlError = 'No se encontraron coordenadas válidas. Copia la URL completa del navegador.');
      return;
    }
    setState(() {
      _urlError = null;
      _pin = LatLng(loc.lat, loc.lng);
    });
    _mapCtrl.move(_pin!, 16);
  }

  Future<void> _getGps() async {
    setState(() {
      _gpsLoading = true;
      _gpsError = null;
    });
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        setState(() => _gpsError = 'Permiso de ubicación denegado.');
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      setState(() {
        _pin = LatLng(pos.latitude, pos.longitude);
      });
      _mapCtrl.move(_pin!, 17);
    } catch (e) {
      setState(() => _gpsError = 'No se pudo obtener la ubicación: ${e.toString()}');
    } finally {
      setState(() => _gpsLoading = false);
    }
  }

  void _confirm() {
    if (_pin == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Toca el mapa para seleccionar una ubicación.')),
      );
      return;
    }
    Navigator.pop(context, MapPickedLocation(_pin!.latitude, _pin!.longitude));
  }

  @override
  Widget build(BuildContext context) {
    final initial = _pin ?? _defaultCenter;
    final pinConfirmed = _pin != null;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Seleccionar ubicación'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          TextButton(
            onPressed: pinConfirmed ? _confirm : null,
            style: TextButton.styleFrom(
              foregroundColor: pinConfirmed ? AppColors.primaryLight : AppColors.hint,
            ),
            child: const Text('Confirmar', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // ── Hint de dirección ──────────────────────────────────────
          if (widget.addressHint != null && widget.addressHint!.isNotEmpty)
            Container(
              color: AppColors.primaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.home_outlined, size: 16, color: AppColors.primaryLight),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.addressHint!,
                      style: const TextStyle(color: AppColors.primaryLight, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),

          // ── Mapa ──────────────────────────────────────────────────
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapCtrl,
                  options: MapOptions(
                    initialCenter: initial,
                    initialZoom: _pin != null ? 16.0 : 13.0,
                    onTap: (_, point) {
                      setState(() => _pin = point);
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.senorarroz.delivery_app',
                    ),
                    if (_pin != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _pin!,
                            width: 44,
                            height: 56,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: AppColors.primary,
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: AppColors.primary.withValues(alpha: 0.5),
                                        blurRadius: 12,
                                        spreadRadius: 2,
                                      ),
                                    ],
                                  ),
                                  child: const Icon(Icons.my_location, color: Colors.white, size: 16),
                                ),
                                CustomPaint(
                                  size: const Size(12, 8),
                                  painter: _TrianglePainter(AppColors.primary),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                  ],
                ),

                // ── Instrucción flotante ─────────────────────────────
                if (_pin == null)
                  Positioned(
                    top: 12,
                    left: 16,
                    right: 60,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.surface.withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.touch_app, size: 16, color: AppColors.primaryLight),
                          SizedBox(width: 6),
                          Text(
                            'Toca el mapa para colocar el marcador',
                            style: TextStyle(color: AppColors.onSurface, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),

                // ── Botón GPS ────────────────────────────────────────
                Positioned(
                  top: 12,
                  right: 12,
                  child: Material(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    elevation: 4,
                    shadowColor: Colors.black38,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                      onTap: _gpsLoading ? null : _getGps,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: _gpsLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.primary,
                                ),
                              )
                            : const Icon(Icons.gps_fixed, color: AppColors.primaryLight, size: 22),
                      ),
                    ),
                  ),
                ),

                // ── Coordenadas del pin ──────────────────────────────
                if (_pin != null)
                  Positioned(
                    bottom: 12,
                    left: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.surface.withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                        border: Border.all(color: AppColors.divider),
                      ),
                      child: Text(
                        '${_pin!.latitude.toStringAsFixed(6)}, ${_pin!.longitude.toStringAsFixed(6)}',
                        style: const TextStyle(
                          color: AppColors.primaryLight,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // ── Panel inferior: pegar URL + error GPS ──────────────────
          Container(
            color: AppColors.surface,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_gpsError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _gpsError!,
                      style: const TextStyle(color: AppColors.error, fontSize: 12),
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _urlCtrl,
                        style: const TextStyle(color: AppColors.onSurface, fontSize: 13),
                        decoration: InputDecoration(
                          hintText: 'Pegar enlace de Google Maps…',
                          prefixIcon: const Icon(Icons.link, size: 18),
                          errorText: _urlError,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                            borderSide: const BorderSide(color: AppColors.divider),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                            borderSide: const BorderSide(color: AppColors.divider),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                            borderSide: const BorderSide(color: AppColors.primary, width: 2),
                          ),
                        ),
                        onChanged: (_) {
                          if (_urlError != null) setState(() => _urlError = null);
                        },
                        onSubmitted: (_) => _applyUrl(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _applyUrl,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        side: const BorderSide(color: AppColors.primary),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                        ),
                      ),
                      child: const Text('Usar', style: TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Pequeño triángulo para la cola del marcador.
class _TrianglePainter extends CustomPainter {
  final Color color;
  const _TrianglePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = ui.Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_TrianglePainter old) => old.color != color;
}

/// Abre la pantalla del mapa y retorna la ubicación elegida.
Future<MapPickedLocation?> pushDeliveryMapPicker(
  BuildContext context, {
  MapPickedLocation? initialLocation,
  String? addressHint,
}) async {
  return Navigator.push<MapPickedLocation>(
    context,
    MaterialPageRoute(
      builder: (_) => DeliveryMapPicker(
        initialLocation: initialLocation,
        addressHint: addressHint,
      ),
      fullscreenDialog: true,
    ),
  );
}
