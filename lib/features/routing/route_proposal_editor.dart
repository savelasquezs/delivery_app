import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/errors/user_facing_error.dart';
import '../available/presentation/available_notifier.dart';
import 'delivery_routing_models.dart';

class RouteProposalEditor extends ConsumerStatefulWidget {
  final DeliveryRouteProposal proposal;
  final int version;
  const RouteProposalEditor(
      {super.key, required this.proposal, required this.version});

  @override
  ConsumerState<RouteProposalEditor> createState() =>
      _RouteProposalEditorState();
}

class _RouteProposalEditorState extends ConsumerState<RouteProposalEditor> {
  late final List<int> _selected = [...widget.proposal.claimableReadyOrderIds];
  DeliveryRouteProposal? _preview;
  String? _error;
  bool _busy = false;

  void _change(VoidCallback update) => setState(() {
        update();
        _preview = null;
        _error = null;
      });

  Future<void> _calculate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final preview = await ref
          .read(availableNotifierProvider.notifier)
          .previewRouting([..._selected], widget.version);
      if (mounted) setState(() => _preview = preview);
    } catch (error) {
      if (mounted) {
        setState(() => _error = userFacingErrorMessage(error,
            fallback: 'No pudimos calcular esta selección.'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept() async {
    final preview = _preview;
    if (preview?.selectionFingerprint == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final orders = await ref
          .read(availableNotifierProvider.notifier)
          .selfAssign(
              orderIds: [..._selected],
              proposalId: widget.proposal.id,
              expectedPlanVersion: widget.version,
              modifiedProposal: true,
              selectionFingerprint: preview!.selectionFingerprint);
      if (mounted) Navigator.pop(context, orders);
    } catch (error) {
      if (mounted) {
        setState(() {
          _preview = null;
          _error = userFacingErrorMessage(error,
              fallback: 'La selección cambió. Vuelve a calcularla.');
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(availableNotifierProvider);
    final stale = state.routingPlan?.isStale != false ||
        state.routingPlan?.version != widget.version;
    final choices = <int, String>{
      for (final stop in widget.proposal.stops.where((s) => s.isReady))
        stop.orderId: stop.neighborhood ?? stop.address,
      for (final order in state.orders)
        order.id: order.neighborhoodName ?? order.addressDescription ?? '',
    };
    final extra = choices.keys.where((id) => !_selected.contains(id)).toList();
    final enabled = !_busy && !stale;
    return PopScope(
      canPop: !_busy,
      child: SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .85,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    const Expanded(
                        child: Text('Preparar mi ruta',
                            style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold))),
                    IconButton(
                        onPressed: _busy ? null : () => Navigator.pop(context),
                        icon: const Icon(Icons.close)),
                  ]),
                  const Text(
                      'Añade, quita y arrastra pedidos listos. Al aceptar, la ruta queda confirmada.'),
                  if (stale)
                    const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                            'El plan cambió. Cierra y actualiza las rutas antes de aceptar.')),
                  Expanded(
                      child: ReorderableListView.builder(
                    itemCount: _selected.length,
                    buildDefaultDragHandles: enabled,
                    onReorder: (oldIndex, newIndex) {
                      if (!enabled) return;
                      _change(() {
                        if (newIndex > oldIndex) newIndex--;
                        _selected.insert(
                            newIndex, _selected.removeAt(oldIndex));
                      });
                    },
                    itemBuilder: (context, index) {
                      final id = _selected[index];
                      final stops = _preview?.stops
                              .where((s) => s.orderId == id)
                              .toList() ??
                          [];
                      final arrival = stops.isEmpty
                          ? null
                          : stops.first.estimatedArrivalAtUtc;
                      return ListTile(
                          key: ValueKey(id),
                          leading: Text('${index + 1}'),
                          title: Text('#$id · ${choices[id] ?? ''}'),
                          subtitle: arrival == null
                              ? null
                              : Text(
                                  'Llegada estimada ${TimeOfDay.fromDateTime(arrival.toLocal()).format(context)}'),
                          trailing: IconButton(
                              tooltip: 'Quitar pedido',
                              onPressed: enabled
                                  ? () =>
                                      _change(() => _selected.removeAt(index))
                                  : null,
                              icon: const Icon(Icons.remove_circle_outline)));
                    },
                  )),
                  if (extra.isNotEmpty)
                    DropdownButton<int>(
                      hint: const Text('Añadir otro pedido listo'),
                      isExpanded: true,
                      value: null,
                      items: extra
                          .map((id) => DropdownMenuItem(
                              value: id,
                              child: Text('#$id · ${choices[id]}',
                                  overflow: TextOverflow.ellipsis)))
                          .toList(),
                      onChanged: enabled
                          ? (id) {
                              if (id != null) _change(() => _selected.add(id));
                            }
                          : null,
                    ),
                  if (_preview != null)
                    Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                            '${_preview!.timingLabel} · ${(_preview!.distanceMeters / 1000).toStringAsFixed(1)} km\n'
                            'Salida con ${_selected.length} pedido(s) listos.${_preview!.warning == null ? '' : '\n${_preview!.warning}'}')),
                  if (_error != null)
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  if (_busy) const LinearProgressIndicator(),
                  OutlinedButton(
                      onPressed:
                          enabled && _selected.isNotEmpty ? _calculate : null,
                      child: const Text('Actualizar estimación')),
                  FilledButton(
                      onPressed: enabled &&
                              _preview?.selectionFingerprint != null &&
                              _selected.isNotEmpty
                          ? _accept
                          : null,
                      child:
                          const Text('Aceptar ruta y salir con estos pedidos')),
                ]),
          ),
        ),
      ),
    );
  }
}
