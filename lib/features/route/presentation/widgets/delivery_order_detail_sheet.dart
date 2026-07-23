import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/api/api_exception.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/error_banner.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../../customers/data/customer_repository.dart';
import '../../../customers/models/neighborhood.dart';
import '../../../customers/presentation/widgets/delivery_map_picker.dart';
import '../../../orders/data/order_repository.dart';
import '../../../orders/models/order_models.dart';

final _money = NumberFormat.currency(locale: 'es_CO', symbol: '\$', decimalDigits: 0);

// ─────────────────────────────────────────────────────────────────────────────
// Payload de salida cuando se actualiza la dirección
// ─────────────────────────────────────────────────────────────────────────────
class DeliveryAddressUpdatedPayload {
  final int orderId;
  final String? addressDescription;
  final String? addressAdditionalInfo;
  final double? lat;
  final double? lng;
  final int? neighborhoodId;
  final String? neighborhoodName;

  const DeliveryAddressUpdatedPayload({
    required this.orderId,
    this.addressDescription,
    this.addressAdditionalInfo,
    this.lat,
    this.lng,
    this.neighborhoodId,
    this.neighborhoodName,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Punto de entrada público
// ─────────────────────────────────────────────────────────────────────────────
Future<void> showDeliveryOrderDetailSheet({
  required BuildContext context,
  required WidgetRef ref,
  required Order initialOrder,
  void Function(DeliveryAddressUpdatedPayload)? onAddressUpdated,
  Future<void> Function()? onAfterDelivered,
  bool allowMarkDelivered = true,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppTheme.radiusXl)),
    ),
    builder: (ctx) => _DeliveryOrderDetailBody(
      initialOrder: initialOrder,
      onAddressUpdated: onAddressUpdated,
      onAfterDelivered: onAfterDelivered,
      allowMarkDelivered: allowMarkDelivered,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Cuerpo del sheet
// ─────────────────────────────────────────────────────────────────────────────
class _DeliveryOrderDetailBody extends ConsumerStatefulWidget {
  final Order initialOrder;
  final void Function(DeliveryAddressUpdatedPayload)? onAddressUpdated;
  final Future<void> Function()? onAfterDelivered;
  final bool allowMarkDelivered;

  const _DeliveryOrderDetailBody({
    required this.initialOrder,
    this.onAddressUpdated,
    this.onAfterDelivered,
    required this.allowMarkDelivered,
  });

  @override
  ConsumerState<_DeliveryOrderDetailBody> createState() =>
      _DeliveryOrderDetailBodyState();
}

class _DeliveryOrderDetailBodyState
    extends ConsumerState<_DeliveryOrderDetailBody> {
  late Order _order;
  bool _loading = true;
  bool _reprintLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _order = widget.initialOrder;
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final full = await ref
          .read(orderRepositoryProvider)
          .getOrderWithDetails(widget.initialOrder.id);
      if (mounted) setState(() => _order = full);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _isDelivery => _order.type.toLowerCase() == 'delivery';

  bool get _hasCoords =>
      _isDelivery &&
      _order.latitude != null &&
      _order.longitude != null &&
      _order.latitude != 0 &&
      _order.longitude != 0;

  Future<void> _confirmDelivered() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Marcar como entregado?'),
        content: Text(
          'Confirma que el pedido #${_order.id} fue entregado correctamente.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
            ),
            icon: const Icon(Icons.check_circle_outline, size: 18),
            label: const Text('Confirmar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      await ref
          .read(orderRepositoryProvider)
          .updateOrderStatus(_order.id, OrderStatus.delivered);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.pop(context);
      await widget.onAfterDelivered?.call();
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Pedido #${_order.id} marcado como entregado ✓'),
          backgroundColor: AppColors.accentContainer,
        ),
      );
    } catch (e) {
      if (mounted) ErrorBanner.show(context, e.toString());
    }
  }

  Future<void> _reprintTicket() async {
    if (_reprintLoading) return;
    setState(() => _reprintLoading = true);
    try {
      final result =
          await ref.read(orderRepositoryProvider).enqueueDeliveryPrintJob(
        branchId: _order.branchId,
        orderIds: [_order.id],
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Impresión recibida por la sucursal · solicitud #${result.jobId}',
          ),
          backgroundColor: AppColors.accentContainer,
        ),
      );
    } catch (e) {
      if (mounted) {
        final msg = e is ApiException
            ? e.message
            : e is DioException && e.error is ApiException
                ? (e.error! as ApiException).message
                : e.toString();
        ErrorBanner.show(context, msg);
      }
    } finally {
      if (mounted) setState(() => _reprintLoading = false);
    }
  }

  Future<void> _editAddress() async {
    final cid = _order.customerId;
    final aid = _order.addressId;
    if (cid == null || aid == null) {
      ErrorBanner.show(
          context, 'Este pedido no tiene cliente o dirección para actualizar.');
      return;
    }

    // Abre la pantalla completa de edición de dirección
    final result = await Navigator.push<_AddressEditResult>(
      context,
      MaterialPageRoute(
        builder: (_) => _EditAddressPage(
          order: _order,
          customerId: cid,
          addressId: aid,
        ),
        fullscreenDialog: true,
      ),
    );
    if (result == null || !mounted) return;

    // Actualiza estado local
    setState(() {
      _order = _order.copyWithAddressFields(
        addressDescription: result.address,
        addressAdditionalInfo: result.additionalInfo.isEmpty ? null : result.additionalInfo,
        latitude: result.latitude,
        longitude: result.longitude,
        neighborhoodId: result.neighborhoodId,
        neighborhoodName: result.neighborhoodName,
      );
    });

    widget.onAddressUpdated?.call(
      DeliveryAddressUpdatedPayload(
        orderId: _order.id,
        addressDescription: result.address,
        addressAdditionalInfo:
            result.additionalInfo.isEmpty ? null : result.additionalInfo,
        lat: result.latitude,
        lng: result.longitude,
        neighborhoodId: result.neighborhoodId,
        neighborhoodName: result.neighborhoodName,
      ),
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Dirección actualizada correctamente ✓'),
          backgroundColor: AppColors.accentContainer,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.92,
      minChildSize: 0.45,
      maxChildSize: 0.97,
      builder: (ctx, scrollCtrl) => Column(
        children: [
          // ── Drag handle ──────────────────────────────────────────
          const SizedBox(height: 12),
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 4),

          // ── Header ───────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Pedido #${_order.id}',
                        style: const TextStyle(
                          color: AppColors.onBackground,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          StatusBadge(status: _order.status),
                          if (_order.displayNeighborhoodLabel != null) ...[
                            const SizedBox(width: 8),
                            _Chip(
                              label: _order.displayNeighborhoodLabel!,
                              icon: Icons.location_city_outlined,
                            ),
                          ],
                          if (_order.branchName != null) ...[
                            const SizedBox(width: 8),
                            _Chip(
                              label: _order.branchName!,
                              icon: Icons.store_outlined,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  color: AppColors.hint,
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          if (_loading)
            const Expanded(
              child: Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              ),
            )
          else
            Expanded(
              child: ListView(
                controller: scrollCtrl,
                padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + bottom),
                children: [
                  // ── Error de carga ─────────────────────────────
                  if (_error != null)
                    _InfoCard(
                      child: Text(_error!,
                          style: const TextStyle(color: AppColors.error)),
                    ),

                  // ── Advertencia de ruta ────────────────────────
                  if (_order.deliveryRoutePlanningWarnings != null &&
                      _order.deliveryRoutePlanningWarnings!.trim().isNotEmpty)
                    _WarningCard(text: _order.deliveryRoutePlanningWarnings!),

                  // ── Cliente ────────────────────────────────────
                  if (_order.customer != null) ...[
                    _SectionHeader('CLIENTE'),
                    _InfoCard(
                      child: _IconRow(
                        icon: Icons.person_outline,
                        iconColor: AppColors.primaryLight,
                        children: [
                          Text(
                            _order.customer!.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                          if (_order.customer!.phone != null) ...[
                            Text(
                              _order.customer!.phone!,
                              style: const TextStyle(
                                  color: AppColors.hint, fontSize: 13),
                            ),
                            const SizedBox(height: 8),
                            _PhoneActions(phone: _order.customer!.phone!),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // ── Dirección ──────────────────────────────────
                  if (_isDelivery) ...[
                    _SectionHeader('DIRECCIÓN DE ENTREGA'),
                    _InfoCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _IconRow(
                            icon: Icons.location_on_outlined,
                            iconColor: AppColors.primaryLight,
                            children: [
                              Text(
                                _order.displayAddressLine ?? 'Sin dirección registrada',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                              if (_order.addressAdditionalInfo != null &&
                                  _order.addressAdditionalInfo!.trim().isNotEmpty)
                                Text(
                                  _order.addressAdditionalInfo!,
                                  style: const TextStyle(
                                      color: AppColors.hint, fontSize: 12),
                                ),
                              if (_order.neighborhoodName != null)
                                Text(
                                  _order.neighborhoodName!,
                                  style: const TextStyle(
                                    color: AppColors.primaryLight,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                            ],
                          ),
                          if (_hasCoords) ...[
                            const SizedBox(height: 6),
                            Text(
                              '${_order.latitude!.toStringAsFixed(6)}, ${_order.longitude!.toStringAsFixed(6)}',
                              style: const TextStyle(
                                color: AppColors.hint,
                                fontSize: 11,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                          const SizedBox(height: 10),
                          // ── Botón editar dirección ───────────────
                          _ActionChip(
                            icon: Icons.edit_location_alt_outlined,
                            label: 'Editar dirección',
                            onTap: _editAddress,
                            color: AppColors.primary,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // ── Productos ──────────────────────────────────
                  _SectionHeader('PRODUCTOS'),
                  _ProductList(order: _order, money: _money),
                  const SizedBox(height: 12),

                  // ── Totales ────────────────────────────────────
                  _InfoCard(
                    child: Column(
                      children: [
                        if (_order.deliveryFee != null && _order.deliveryFee != 0)
                          _TotalRow(
                            label: 'Domicilio',
                            value: _money.format(_order.deliveryFee),
                            subtle: true,
                          ),
                        _TotalRow(
                          label: 'TOTAL',
                          value: _money.format(_order.total),
                          highlight: true,
                        ),
                        if (_order.total > Order.kPaymentCoverTolerance) ...[
                          if (_order.showYaPagoMessage) ...[
                            const SizedBox(height: 12),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                vertical: 18,
                                horizontal: 16,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.accentContainer,
                                borderRadius:
                                    BorderRadius.circular(AppTheme.radiusMd),
                                border: Border.all(
                                  color: AppColors.accent.withValues(alpha: 0.45),
                                  width: 1.5,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.verified_rounded,
                                    size: 36,
                                    color: AppColors.accentLight
                                        .withValues(alpha: 0.95),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Text(
                                      'Ya pagó',
                                      style: TextStyle(
                                        color: AppColors.accentLight
                                            .withValues(alpha: 0.98),
                                        fontSize: 26,
                                        fontWeight: FontWeight.w800,
                                        height: 1.1,
                                        letterSpacing: -0.5,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ] else if (_order.cashToCollectOnDelivery >
                              Order.kPaymentCoverTolerance) ...[
                            const SizedBox(height: 12),
                            _TotalRow(
                              label: 'A cobrar (efectivo)',
                              value:
                                  _money.format(_order.cashToCollectOnDelivery),
                              highlight: true,
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),

                  // ── Notas ──────────────────────────────────────
                  if (_order.notes != null && _order.notes!.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _SectionHeader('NOTAS'),
                    _InfoCard(
                      child: Text(
                        _order.notes!,
                        style: const TextStyle(
                            color: AppColors.onSurface, fontSize: 14),
                      ),
                    ),
                  ],

                  // ── CTA: Reimprimir / Marcar entregado ───────
                  if (_isDelivery && _order.status == OrderStatus.onTheWay) ...[
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _reprintLoading ? null : _reprintTicket,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.onSurface,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusMd),
                          ),
                        ),
                        icon: _reprintLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.print_outlined, size: 20),
                        label: Text(
                          _reprintLoading ? 'Enviando…' : 'Reimprimir ticket',
                        ),
                      ),
                    ),
                  ],
                  if (widget.allowMarkDelivered &&
                      _order.status == OrderStatus.onTheWay) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _confirmDelivered,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusMd),
                          ),
                          textStyle: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                        icon: const Icon(Icons.check_circle_outline, size: 20),
                        label: const Text('Marcar como entregado'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pantalla completa de edición de dirección
// ─────────────────────────────────────────────────────────────────────────────
class _AddressEditResult {
  final int neighborhoodId;
  final String neighborhoodName;
  final String address;
  final String additionalInfo;
  final double? latitude;
  final double? longitude;

  const _AddressEditResult({
    required this.neighborhoodId,
    required this.neighborhoodName,
    required this.address,
    required this.additionalInfo,
    this.latitude,
    this.longitude,
  });
}

class _EditAddressPage extends ConsumerStatefulWidget {
  final Order order;
  final int customerId;
  final int addressId;

  const _EditAddressPage({
    required this.order,
    required this.customerId,
    required this.addressId,
  });

  @override
  ConsumerState<_EditAddressPage> createState() => _EditAddressPageState();
}

class _EditAddressPageState extends ConsumerState<_EditAddressPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _addressCtrl;
  late final TextEditingController _infoCtrl;

  List<Neighborhood> _neighborhoods = [];
  int? _neighborhoodId;
  double? _latitude;
  double? _longitude;

  bool _loadingNeighborhoods = true;
  bool _saving = false;
  bool _gpsLoading = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _addressCtrl = TextEditingController(
        text: widget.order.displayAddressLine ?? '');
    _infoCtrl =
        TextEditingController(text: widget.order.addressAdditionalInfo ?? '');
    _neighborhoodId = widget.order.neighborhoodId;
    _latitude = widget.order.latitude;
    _longitude = widget.order.longitude;
    _loadNeighborhoods();
  }

  @override
  void dispose() {
    _addressCtrl.dispose();
    _infoCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadNeighborhoods() async {
    try {
      final list = await ref.read(customerRepositoryProvider).getNeighborhoods();
      if (!mounted) return;
      setState(() {
        _neighborhoods = list;
        _loadingNeighborhoods = false;
        // Si el barrio actual no está en la lista, selecciona el primero
        if (list.isNotEmpty &&
            (_neighborhoodId == null ||
                !list.any((n) => n.id == _neighborhoodId))) {
          _neighborhoodId = list.first.id;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = e.toString();
          _loadingNeighborhoods = false;
        });
      }
    }
  }

  String _nameForId(int id) {
    try {
      return _neighborhoods.firstWhere((n) => n.id == id).name;
    } catch (_) {
      return widget.order.neighborhoodName ?? '';
    }
  }

  Future<void> _openMapPicker() async {
    final address = _addressCtrl.text.trim();
    final loc = await pushDeliveryMapPicker(
      context,
      initialLocation: (_latitude != null && _longitude != null)
          ? MapPickedLocation(_latitude!, _longitude!)
          : null,
      addressHint: address.isNotEmpty ? address : null,
    );
    if (loc == null || !mounted) return;
    setState(() {
      _latitude = loc.lat;
      _longitude = loc.lng;
    });
  }

  /// GPS del dispositivo → actualiza lat/lng de la dirección (sin abrir el mapa).
  Future<void> _useCurrentLocation() async {
    if (_gpsLoading) return;
    setState(() => _gpsLoading = true);
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Activa el permiso de ubicación para usar la posición actual.',
            ),
          ),
        );
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (!mounted) return;
      setState(() {
        _latitude = pos.latitude;
        _longitude = pos.longitude;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Ubicación actual aplicada. Comprueba en el mapa y guarda si es correcta.',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ErrorBanner.show(context, 'No se pudo obtener la ubicación: $e');
      }
    } finally {
      if (mounted) setState(() => _gpsLoading = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final nid = _neighborhoodId;
    if (nid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selecciona un barrio.')),
      );
      return;
    }
    if (_latitude == null || _longitude == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Selecciona la ubicación en el mapa antes de guardar.')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await ref.read(customerRepositoryProvider).updateCustomerAddress(
            customerId: widget.customerId,
            addressId: widget.addressId,
            body: {
              'neighborhoodId': nid,
              'address': _addressCtrl.text.trim(),
              'additionalInfo': _infoCtrl.text.trim().isEmpty
                  ? null
                  : _infoCtrl.text.trim(),
              'latitude': _latitude,
              'longitude': _longitude,
              'isPrimary': false,
              'deliveryFee': widget.order.deliveryFee?.round() ?? 0,
            },
          );
      if (!mounted) return;
      Navigator.pop(
        context,
        _AddressEditResult(
          neighborhoodId: nid,
          neighborhoodName: _nameForId(nid),
          address: _addressCtrl.text.trim(),
          additionalInfo: _infoCtrl.text.trim(),
          latitude: _latitude,
          longitude: _longitude,
        ),
      );
    } catch (e) {
      if (mounted) ErrorBanner.show(context, e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasCoords = _latitude != null && _longitude != null;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Editar dirección'),
        leading: BackButton(
          color: AppColors.primaryLight,
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          TextButton(
            onPressed: (_saving || _loadingNeighborhoods) ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.primaryLight),
                  )
                : const Text(
                    'Guardar',
                    style: TextStyle(
                      color: AppColors.primaryLight,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loadingNeighborhoods
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary))
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (_loadError != null)
                    _ErrorBox(message: _loadError!),

                  // ── Barrio ──────────────────────────────────────
                  _FieldLabel('Barrio'),
                  const SizedBox(height: 6),
                  _NeighborhoodDropdown(
                    neighborhoods: _neighborhoods,
                    selectedId: _neighborhoodId,
                    onChanged: (id) => setState(() => _neighborhoodId = id),
                  ),
                  const SizedBox(height: 16),

                  // ── Dirección ───────────────────────────────────
                  _FieldLabel('Dirección'),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _addressCtrl,
                    textCapitalization: TextCapitalization.sentences,
                    maxLength: 200,
                    maxLines: 2,
                    style: const TextStyle(
                        color: AppColors.onBackground, fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: 'Ej: Calle 10 #20-30',
                      prefixIcon: Icon(Icons.home_outlined, size: 20),
                      counterText: '',
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'La dirección es requerida';
                      }
                      if (v.trim().length < 10) {
                        return 'Mínimo 10 caracteres';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // ── Info adicional ──────────────────────────────
                  _FieldLabel('Info adicional (opcional)'),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _infoCtrl,
                    textCapitalization: TextCapitalization.sentences,
                    maxLength: 100,
                    maxLines: 2,
                    style: const TextStyle(
                        color: AppColors.onBackground, fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: 'Ej: Apto 202, Torre A, Frente al parque',
                      prefixIcon:
                          Icon(Icons.info_outline, size: 20),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── Coordenadas / Mapa ──────────────────────────
                  _FieldLabel('Ubicación en el mapa'),
                  const SizedBox(height: 8),
                  _CoordCard(
                    latitude: _latitude,
                    longitude: _longitude,
                    onTapMap: _openMapPicker,
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: (_saving || _loadingNeighborhoods || _gpsLoading)
                          ? null
                          : _useCurrentLocation,
                      icon: _gpsLoading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.primaryLight,
                              ),
                            )
                          : const Icon(Icons.my_location, size: 20),
                      label: Text(
                        _gpsLoading ? 'Obteniendo ubicación…' : 'Usar ubicación actual',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primaryLight,
                        side: const BorderSide(color: AppColors.primary),
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusMd),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // ── Botón guardar ───────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: (_saving || _loadingNeighborhoods || !hasCoords)
                          ? null
                          : _save,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        disabledBackgroundColor:
                            AppColors.primary.withValues(alpha: 0.3),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                        ),
                        textStyle: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                      icon: const Icon(Icons.save_outlined, size: 20),
                      label: const Text('Guardar dirección'),
                    ),
                  ),

                  if (!hasCoords) ...[
                    const SizedBox(height: 8),
                    const Center(
                      child: Text(
                        'Selecciona la ubicación en el mapa para habilitar guardar',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.hint, fontSize: 12),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-widgets reutilizables del sheet y la página
// ─────────────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(
          text,
          style: const TextStyle(
            color: AppColors.hint,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
          ),
        ),
      );
}


class _InfoCard extends StatelessWidget {
  final Widget child;
  const _InfoCard({required this.child});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(color: AppColors.divider),
        ),
        child: child,
      );
}

class _IconRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final List<Widget> children;

  const _IconRow({
    required this.icon,
    required this.iconColor,
    required this.children,
  });

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children
                  .map((w) => Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: w,
                      ))
                  .toList(),
            ),
          ),
        ],
      );
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = AppColors.hint,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                    color: color, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
}

class _Chip extends StatelessWidget {
  final String label;
  final IconData icon;
  const _Chip({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.cardElevated,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: AppColors.hint),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(color: AppColors.hint, fontSize: 11),
            ),
          ],
        ),
      );
}

class _ProductList extends StatelessWidget {
  final Order order;
  final NumberFormat money;
  const _ProductList({required this.order, required this.money});

  @override
  Widget build(BuildContext context) {
    final lines = order.items.isNotEmpty
        ? order.items
            .map((it) => _ProductRow(
                  name: it.productName,
                  quantity: it.quantity,
                  unitPrice: money.format(it.unitPrice),
                  subtotal: money.format(it.subtotal),
                  notes: it.notes,
                ))
            .toList()
        : order.summaryLines
            .map((s) => _ProductRow(
                  name: s.productName,
                  quantity: s.quantity,
                  unitPrice: null,
                  subtotal: null,
                  notes: null,
                ))
            .toList();

    if (lines.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text('Sin líneas registradas',
            style: TextStyle(color: AppColors.hint, fontSize: 13)),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          for (int i = 0; i < lines.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            lines[i],
          ],
        ],
      ),
    );
  }
}

class _ProductRow extends StatelessWidget {
  final String name;
  final int quantity;
  final String? unitPrice;
  final String? subtotal;
  final String? notes;

  const _ProductRow({
    required this.name,
    required this.quantity,
    required this.unitPrice,
    required this.subtotal,
    required this.notes,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.primaryContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$quantity',
                style: const TextStyle(
                  color: AppColors.primaryLight,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w500)),
                  if (notes != null && notes!.isNotEmpty)
                    Text(notes!,
                        style: const TextStyle(
                            color: AppColors.hint, fontSize: 11)),
                ],
              ),
            ),
            if (subtotal != null)
              Text(subtotal!,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13)),
          ],
        ),
      );
}

class _TotalRow extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;
  final bool subtle;

  const _TotalRow({
    required this.label,
    required this.value,
    this.highlight = false,
    this.subtle = false,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(
                color: subtle ? AppColors.hint : AppColors.onSurface,
                fontSize: highlight ? 15 : 13,
                fontWeight:
                    highlight ? FontWeight.w700 : FontWeight.normal,
              ),
            ),
            Text(
              value,
              style: TextStyle(
                color: highlight ? AppColors.primaryLight : AppColors.onSurface,
                fontSize: highlight ? 17 : 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
}

class _WarningCard extends StatelessWidget {
  final String text;
  const _WarningCard({required this.text});

  @override
  Widget build(BuildContext context) {
    final lines = text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_outlined,
                  size: 16, color: AppColors.warning),
              const SizedBox(width: 6),
              const Text(
                'Plan de ruta incompleto',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.warning,
                    fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ...lines.map(
            (l) => Text('• $l',
                style: const TextStyle(
                    color: AppColors.onSurface, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

// ── Subwidgets para _EditAddressPage ────────────────────────────────────────

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          color: AppColors.onSurface,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      );
}

class _ErrorBox extends StatelessWidget {
  final String message;
  const _ErrorBox({required this.message});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.error.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline,
                color: AppColors.error, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message,
                  style: const TextStyle(
                      color: AppColors.error, fontSize: 13)),
            ),
          ],
        ),
      );
}

class _NeighborhoodDropdown extends StatelessWidget {
  final List<Neighborhood> neighborhoods;
  final int? selectedId;
  final ValueChanged<int?> onChanged;

  const _NeighborhoodDropdown({
    required this.neighborhoods,
    required this.selectedId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (neighborhoods.isEmpty) {
      return Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.inputFill,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(color: AppColors.divider),
        ),
        child: const Text('Sin barrios disponibles',
            style: TextStyle(color: AppColors.hint, fontSize: 13)),
      );
    }
    final selectedInList =
        neighborhoods.any((n) => n.id == selectedId) ? selectedId : null;

    return DropdownButtonFormField<int>(
      // ignore: deprecated_member_use
      value: selectedInList,
      isExpanded: true,
      dropdownColor: AppColors.cardElevated,
      style: const TextStyle(color: AppColors.onBackground, fontSize: 14),
      icon: const Icon(Icons.expand_more, color: AppColors.hint, size: 20),
      decoration: InputDecoration(
        prefixIcon:
            const Icon(Icons.location_city_outlined, size: 20),
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
        filled: true,
        fillColor: AppColors.inputFill,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
      ),
      items: neighborhoods
          .map(
            (n) => DropdownMenuItem<int>(
              value: n.id,
              child: Text(n.name, overflow: TextOverflow.ellipsis),
            ),
          )
          .toList(),
      onChanged: onChanged,
      validator: (v) => v == null ? 'Selecciona un barrio' : null,
    );
  }
}

class _CoordCard extends StatelessWidget {
  final double? latitude;
  final double? longitude;
  final VoidCallback onTapMap;

  const _CoordCard({
    required this.latitude,
    required this.longitude,
    required this.onTapMap,
  });

  @override
  Widget build(BuildContext context) {
    final hasCoords = latitude != null && longitude != null;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: hasCoords
            ? AppColors.primaryContainer
            : AppColors.card,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(
          color: hasCoords
              ? AppColors.primary.withValues(alpha: 0.4)
              : AppColors.divider,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: hasCoords
                  ? AppColors.primary.withValues(alpha: 0.2)
                  : AppColors.cardElevated,
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            ),
            child: Icon(
              hasCoords ? Icons.location_on : Icons.add_location_alt_outlined,
              color: hasCoords ? AppColors.primaryLight : AppColors.hint,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: hasCoords
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Ubicación asignada',
                        style: TextStyle(
                          color: AppColors.primaryLight,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${latitude!.toStringAsFixed(6)}, ${longitude!.toStringAsFixed(6)}',
                        style: const TextStyle(
                          color: AppColors.hint,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  )
                : const Text(
                    'Sin coordenadas asignadas.\nToca para abrir el mapa.',
                    style: TextStyle(color: AppColors.hint, fontSize: 13),
                  ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: onTapMap,
            style: OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              side: BorderSide(
                color: hasCoords ? AppColors.primary : AppColors.divider,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              ),
            ),
            child: Text(
              hasCoords ? 'Cambiar' : 'Abrir mapa',
              style: TextStyle(
                  color: hasCoords ? AppColors.primaryLight : AppColors.hint,
                  fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Botones de contacto: Llamar + WhatsApp + Copiar
// ─────────────────────────────────────────────────────────────────────────────

class _PhoneActions extends StatelessWidget {
  final String phone;
  const _PhoneActions({required this.phone});

  String get _cleanPhone => phone.replaceAll(RegExp(r'[\s\-\(\)]'), '');

  bool get _isColombian {
    final n = _cleanPhone.replaceAll('+', '');
    return RegExp(r'^(57)?[36]\d{9}$').hasMatch(n);
  }

  String get _waNumber {
    final n = _cleanPhone;
    if (n.startsWith('+57')) return n.replaceAll('+', '');
    if (n.startsWith('57') && n.length == 12) return n;
    if (n.startsWith('3') && n.length == 10) return '57$n';
    return n.replaceAll('+', '');
  }

  Future<void> _call(BuildContext ctx) async {
    final tel = _cleanPhone.startsWith('+') ? _cleanPhone : '+57$_cleanPhone';
    try {
      await launchUrl(Uri.parse('tel:$tel'),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('No se pudo iniciar la llamada')),
        );
      }
    }
  }

  Future<void> _whatsapp(BuildContext ctx) async {
    try {
      await launchUrl(Uri.parse('https://wa.me/$_waNumber'),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('No se pudo abrir WhatsApp')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _ContactBtn(
          icon: Icons.phone_outlined,
          label: 'Llamar',
          color: AppColors.accent,
          onTap: () => _call(context),
        ),
        if (_isColombian) ...[
          const SizedBox(width: 8),
          _ContactBtn(
            icon: Icons.chat_outlined,
            label: 'WhatsApp',
            color: const Color(0xFF25D366),
            onTap: () => _whatsapp(context),
          ),
        ],
      ],
    );
  }
}

class _ContactBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ContactBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      );
}
