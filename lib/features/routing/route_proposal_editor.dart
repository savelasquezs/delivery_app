import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/errors/user_facing_error.dart';
import '../available/presentation/available_notifier.dart';
import 'delivery_routing_models.dart';
import 'helpers/route_editor_helpers.dart';
import 'route_timing_summary.dart';

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
  bool _calculating = false;
  bool _saving = false;
  Timer? _debounce;
  int _revision = 0;

  bool get _stale {
    final plan = ref.read(availableNotifierProvider).routingPlan;
    return plan == null || plan.isStale || plan.version != widget.version;
  }

  Map<int, RouteEditorOrder> _choices(AvailableState state) =>
      state.routingPlan == null
          ? {}
          : routeEditorChoices(state.routingPlan!, state.orders);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _change(() {}, immediately: true);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _change(VoidCallback update, {bool immediately = false}) {
    _debounce?.cancel();
    final revision = ++_revision;
    setState(() {
      update();
      _preview = null;
      _error = null;
      _calculating = _selected.isNotEmpty && !_stale;
    });
    if (!_calculating) return;
    final ids = List<int>.of(_selected);
    if (immediately) {
      unawaited(_calculate(revision, ids));
    } else {
      _debounce = Timer(const Duration(milliseconds: 250),
          () => unawaited(_calculate(revision, ids)));
    }
  }

  Future<void> _calculate(int revision, List<int> ids) async {
    if (!mounted || revision != _revision) return;
    if (_stale) {
      setState(() => _calculating = false);
      return;
    }
    try {
      final preview = await ref
          .read(availableNotifierProvider.notifier)
          .previewRouting(ids, widget.version);
      if (!mounted || revision != _revision) return;
      setState(() {
        _preview = _stale ? null : preview;
        _calculating = false;
      });
    } catch (error) {
      if (!mounted || revision != _revision) return;
      setState(() {
        _calculating = false;
        _error = userFacingErrorMessage(error,
            fallback: 'No pudimos calcular esta selección.');
      });
    }
  }

  Future<bool> _confirm(
          {required String title,
          required String message,
          required String action}) async =>
      await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: Text(title),
                content: Text(message),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancelar')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(action)),
                ],
              )) ??
      false;

  Future<void> _remove(RouteEditorOrder order) async {
    final confirmed = await _confirm(
      title: '¿Quitar este pedido?',
      message:
          '${routeEditorAddress(order)}\n${routeEditorOrderDetails(order)}\n\n'
          'Se quitará de tu selección, pero seguirá disponible para otra ruta.',
      action: 'Quitar',
    );
    if (confirmed && mounted && !_stale && !_saving) {
      _change(() => _selected.remove(order.id));
    }
  }

  Future<void> _add() async {
    var query = '';
    final id = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
          builder: (context, updatePicker) =>
              Consumer(builder: (context, pickerRef, _) {
                final state = pickerRef.watch(availableNotifierProvider);
                final stale = state.routingPlan?.isStale != false ||
                    state.routingPlan?.version != widget.version;
                final choices = _choices(state)
                    .values
                    .where((order) => !_selected.contains(order.id))
                    .where((order) =>
                        '${order.address} ${order.neighborhood ?? ''} ${order.id}'
                            .toLowerCase()
                            .contains(query.toLowerCase().trim()))
                    .toList()
                  ..sort((first, second) {
                    final firstGroup = first.proposalId == null
                        ? 0
                        : first.proposalId == widget.proposal.id
                            ? 1
                            : 2;
                    final secondGroup = second.proposalId == null
                        ? 0
                        : second.proposalId == widget.proposal.id
                            ? 1
                            : 2;
                    final group = firstGroup.compareTo(secondGroup);
                    return group != 0 ? group : first.id.compareTo(second.id);
                  });
                final keyboard = MediaQuery.viewInsetsOf(context).bottom;
                return SafeArea(
                    child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + keyboard),
                  child: SizedBox(
                    height: (MediaQuery.sizeOf(context).height * .8 - keyboard)
                        .clamp(120.0, 620.0),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(children: [
                            const Expanded(
                                child: Text('Añadir pedido listo',
                                    style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold))),
                            IconButton(
                                tooltip: 'Cerrar pedidos disponibles',
                                onPressed: () => Navigator.pop(context),
                                icon: const Icon(Icons.close)),
                          ]),
                          TextField(
                              decoration: const InputDecoration(
                                  labelText:
                                      'Buscar dirección, barrio o número',
                                  prefixIcon: Icon(Icons.search)),
                              onChanged: (value) =>
                                  updatePicker(() => query = value)),
                          const SizedBox(height: 8),
                          if (stale)
                            const Text(
                                'El plan cambió. Vuelve a las rutas para actualizarlo.'),
                          Expanded(
                              child: choices.isEmpty
                                  ? const Center(
                                      child: Text(
                                          'No hay otros pedidos listos que coincidan.'))
                                  : ListView.builder(
                                      itemCount: choices.length,
                                      itemBuilder: (context, index) {
                                        final order = choices[index];
                                        final origin = order.proposalId == null
                                            ? 'Sin ruta sugerida'
                                            : order.proposalId ==
                                                    widget.proposal.id
                                                ? 'De esta propuesta'
                                                : 'En Ruta ${order.routeSequence} · requiere confirmación';
                                        return ListTile(
                                          key:
                                              ValueKey('add-order-${order.id}'),
                                          title:
                                              Text(routeEditorAddress(order)),
                                          subtitle: Text(
                                              '${routeEditorOrderDetails(order)}\n$origin'),
                                          isThreeLine: true,
                                          trailing: const Icon(
                                              Icons.add_circle_outline),
                                          onTap: stale
                                              ? null
                                              : () => Navigator.pop(
                                                  context, order.id),
                                        );
                                      })),
                        ]),
                  ),
                ));
              })),
    );
    if (!mounted || id == null || _stale || _saving || _selected.contains(id)) {
      return;
    }
    final order = _choices(ref.read(availableNotifierProvider))[id];
    if (order == null) return;
    if (order.proposalId != null && order.proposalId != widget.proposal.id) {
      final confirmed = await _confirm(
        title: '¿Tomar un pedido de la Ruta ${order.routeSequence}?',
        message:
            '${routeEditorAddress(order)}\n${routeEditorOrderDetails(order)}\n\n'
            'Ya pertenece a otra propuesta. Solo al aceptar tu ruta se retirará de esa propuesta '
            'y se actualizarán las rutas pendientes. ¿Quieres añadirlo?',
        action: 'Añadir a mi ruta',
      );
      if (!confirmed || !mounted || _stale || _saving) return;
    }
    if (!_choices(ref.read(availableNotifierProvider)).containsKey(id)) return;
    _change(() => _selected.add(id));
  }

  Future<void> _accept() async {
    final preview = _preview;
    if (_saving ||
        _calculating ||
        _stale ||
        _selected.isEmpty ||
        preview?.selectionFingerprint == null ||
        !preview!.isClaimable) {
      return;
    }
    setState(() {
      _saving = true;
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
              selectionFingerprint: preview.selectionFingerprint);
      if (mounted) Navigator.pop(context, orders);
    } catch (error) {
      if (mounted) {
        setState(() {
          _preview = null;
          _error = userFacingErrorMessage(error,
              fallback:
                  'No pudimos aceptar la ruta. Revisa los pedidos e inténtalo de nuevo.');
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(availableNotifierProvider);
    final stale = state.routingPlan?.isStale != false ||
        state.routingPlan?.version != widget.version;
    final choices = _choices(state);
    final enabled = !_saving && !stale;
    final canAdd = choices.keys.any((id) => !_selected.contains(id));
    return PopScope(
        canPop: !_saving,
        child: SafeArea(
            child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .9),
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    const Expanded(
                        child: Text('Preparar mi ruta',
                            style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold))),
                    IconButton(
                        tooltip: 'Cerrar preparación de ruta',
                        onPressed:
                            _saving ? null : () => Navigator.pop(context),
                        icon: const Icon(Icons.close)),
                  ]),
                  const Text(
                      'Arrastra para ordenar. La estimación se actualiza automáticamente.'),
                  if (stale)
                    Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                                'El plan cambió o venció. Revisa las rutas actualizadas antes de aceptar.'),
                            TextButton(
                                onPressed: _saving
                                    ? null
                                    : () {
                                        unawaited(ref
                                            .read(availableNotifierProvider
                                                .notifier)
                                            .loadRouting(
                                                silently: true,
                                                ensureFresh: true));
                                        Navigator.pop(context);
                                      },
                                child: const Text('Volver y actualizar rutas')),
                          ],
                        )),
                  Flexible(
                      child: _selected.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: Text(
                                  'Añade al menos un pedido listo para preparar tu ruta.'))
                          : ReorderableListView.builder(
                              shrinkWrap: true,
                              buildDefaultDragHandles: false,
                              itemCount: _selected.length,
                              onReorder: (oldIndex, newIndex) {
                                if (!enabled ||
                                    oldIndex == newIndex ||
                                    oldIndex + 1 == newIndex) {
                                  return;
                                }
                                _change(() {
                                  if (newIndex > oldIndex) newIndex--;
                                  _selected.insert(
                                      newIndex, _selected.removeAt(oldIndex));
                                });
                              },
                              itemBuilder: (context, index) {
                                final id = _selected[index];
                                final order = choices[id] ??
                                    (
                                      id: id,
                                      address: widget.proposal.stops
                                              .where(
                                                  (stop) => stop.orderId == id)
                                              .firstOrNull
                                              ?.address ??
                                          '',
                                      neighborhood: null,
                                      proposalId: widget.proposal.id,
                                      routeSequence: widget.proposal.sequence,
                                    );
                                final arrival = _preview?.stops
                                    .where((stop) => stop.orderId == id)
                                    .firstOrNull
                                    ?.estimatedArrivalAtUtc;
                                return ListTile(
                                  key: ValueKey('selected-order-$id'),
                                  contentPadding: EdgeInsets.zero,
                                  leading: CircleAvatar(
                                      radius: 14, child: Text('${index + 1}')),
                                  title: Text(routeEditorAddress(order)),
                                  subtitle: Text(
                                      '${routeEditorOrderDetails(order)}${arrival == null ? '' : '\nLlegada estimada ${TimeOfDay.fromDateTime(arrival.toLocal()).format(context)}'}'),
                                  trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                            tooltip: 'Quitar pedido',
                                            onPressed: enabled
                                                ? () => _remove(order)
                                                : null,
                                            icon: const Icon(
                                                Icons.remove_circle_outline)),
                                        ReorderableDragStartListener(
                                            index: index,
                                            enabled: enabled,
                                            child: const Padding(
                                                padding: EdgeInsets.all(12),
                                                child:
                                                    Icon(Icons.drag_handle))),
                                      ]),
                                );
                              })),
                  OutlinedButton.icon(
                      onPressed: enabled && canAdd ? _add : null,
                      icon: const Icon(Icons.add_location_alt_outlined),
                      label: const Text('Añadir pedido')),
                  if (!canAdd)
                    const Text('No hay otros pedidos listos disponibles.',
                        style: TextStyle(fontSize: 12)),
                  if (_calculating && !stale)
                    const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Column(children: [
                          LinearProgressIndicator(),
                          SizedBox(height: 6),
                          Text('Recalculando ruta…')
                        ])),
                  if (_preview != null && !stale)
                    Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            RouteTimingSummary(proposal: _preview!),
                            const SizedBox(height: 4),
                            Text(
                                '${_selected.length} pedido(s) listos. Al aceptar, la ruta queda confirmada.'),
                            if (_preview!.warning != null)
                              Text(_preview!.warning!),
                          ],
                        )),
                  if (_error != null) ...[
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                    if (!stale)
                      TextButton(
                          onPressed: _saving || _calculating
                              ? null
                              : () => _change(() {}, immediately: true),
                          child: const Text('Reintentar cálculo')),
                  ],
                  if (_saving) const LinearProgressIndicator(),
                  FilledButton(
                      onPressed: enabled &&
                              !_calculating &&
                              _selected.isNotEmpty &&
                              _preview?.selectionFingerprint != null &&
                              _preview?.isClaimable == true
                          ? _accept
                          : null,
                      child:
                          const Text('Aceptar ruta y salir con estos pedidos')),
                ],
              )),
        )));
  }
}
