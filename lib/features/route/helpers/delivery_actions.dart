import 'package:flutter/material.dart';
import '../../../core/widgets/error_banner.dart';
import '../../orders/data/order_repository.dart';
import '../../orders/models/order_models.dart';

Future<bool> confirmDelivery(BuildContext context, Order order, Future<void> Function() save) async {
  final confirmed = await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(
    title: const Text('¿Marcar como entregado?'),
    content: Text('Confirma que el pedido #${order.id} fue entregado correctamente.'),
    actions: [TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancelar')),
      FilledButton.icon(onPressed: () => Navigator.pop(dialog, true),
        icon: const Icon(Icons.check_circle_outline), label: const Text('Confirmar'))],
  ));
  if (confirmed != true || !context.mounted) return false;
  try {
    await save();
    if (context.mounted) ErrorBanner.showSuccess(context, 'Entrega registrada, pendiente de sincronizar');
    return true;
  } catch (error) {
    if (context.mounted) ErrorBanner.show(context, error, fallback: 'No pudimos registrar la entrega.');
    return false;
  }
}

Future<void> reprintDelivery(BuildContext context, OrderRepository repository, Order order) async {
  try {
    final result = await repository.enqueueDeliveryPrintJob(branchId: order.branchId, orderIds: [order.id]);
    if (context.mounted) ErrorBanner.showSuccess(context, 'Impresión recibida por la sucursal · solicitud #${result.jobId}');
  } catch (error) {
    if (context.mounted) ErrorBanner.show(context, error, fallback: 'No pudimos solicitar la impresión del pedido.');
  }
}
