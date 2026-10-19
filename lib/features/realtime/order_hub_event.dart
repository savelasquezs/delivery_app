import '../orders/models/order_models.dart';

const orderReadyHubEvent = 'OrderReady';
const orderAssignedHubEvent = 'OrderAssigned';
const orderModifiedHubEvent = 'OrderModified';
const deliveryRoutingPlanChangedHubEvent = 'DeliveryRoutingPlanChanged';
const routeProposalClaimedHubEvent = 'RouteProposalClaimed';

enum OrderHubEventKind { ready, assigned, modified, routing, ignored }

int? routingPlanVersionFromHubEvent(String event, List<Object?>? args) {
  if (event != deliveryRoutingPlanChangedHubEvent) return null;
  final payload = _firstMap(args);
  final value = payload?['version'] ?? payload?['Version'];
  if (value is int && value > 0) return value;
  return null;
}

OrderHubEventKind classifyOrderHubEvent(String event) {
  return switch (event) {
    orderReadyHubEvent => OrderHubEventKind.ready,
    orderAssignedHubEvent => OrderHubEventKind.assigned,
    orderModifiedHubEvent => OrderHubEventKind.modified,
    deliveryRoutingPlanChangedHubEvent ||
    routeProposalClaimedHubEvent =>
      OrderHubEventKind.routing,
    _ => OrderHubEventKind.ignored,
  };
}

Order? orderFromHubEvent(String event, List<Object?>? args) {
  if (event != orderReadyHubEvent &&
      event != orderAssignedHubEvent &&
      event != orderModifiedHubEvent) {
    return null;
  }
  final payload = _firstMap(args);
  if (payload == null) return null;
  final rawOrder = event == orderModifiedHubEvent
      ? payload['order'] ?? payload['Order']
      : payload;
  if (rawOrder is! Map) return null;
  try {
    return Order.fromJson(Map<String, dynamic>.from(rawOrder));
  } catch (_) {
    return null;
  }
}

Map<String, dynamic>? _firstMap(List<Object?>? args) {
  if (args == null || args.isEmpty || args.first is! Map) return null;
  return Map<String, dynamic>.from(args.first! as Map);
}
