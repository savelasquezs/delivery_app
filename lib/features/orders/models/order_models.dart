import '../../../core/constants/delivery_payroll.dart';

enum OrderStatus {
  taken,
  inPreparation,
  ready,
  onTheWay,
  delivered,
  cancelled;

  String get displayName => switch (this) {
        OrderStatus.taken => 'Tomado',
        OrderStatus.inPreparation => 'En preparación',
        OrderStatus.ready => 'Listo',
        OrderStatus.onTheWay => 'En camino',
        OrderStatus.delivered => 'Entregado',
        OrderStatus.cancelled => 'Cancelado',
      };

  String get apiValue => switch (this) {
        OrderStatus.taken => 'taken',
        OrderStatus.inPreparation => 'inPreparation',
        OrderStatus.ready => 'ready',
        OrderStatus.onTheWay => 'onTheWay',
        OrderStatus.delivered => 'delivered',
        OrderStatus.cancelled => 'cancelled',
      };

  static OrderStatus fromApi(String value) {
    return switch (value.toLowerCase()) {
      'taken' => OrderStatus.taken,
      'inpreparation' || 'in_preparation' => OrderStatus.inPreparation,
      'ready' => OrderStatus.ready,
      'ontheway' || 'on_the_way' => OrderStatus.onTheWay,
      'delivered' => OrderStatus.delivered,
      'cancelled' => OrderStatus.cancelled,
      _ => OrderStatus.taken,
    };
  }
}

class OrderAddress {
  final int? id;
  final String? street;
  final String? neighborhood;
  final String? city;
  final String? notes;

  const OrderAddress({
    this.id,
    this.street,
    this.neighborhood,
    this.city,
    this.notes,
  });

  factory OrderAddress.fromJson(Map<String, dynamic> json) => OrderAddress(
        id: json['id'] as int?,
        street: json['street'] as String? ?? json['address'] as String?,
        neighborhood: json['neighborhood'] as String?,
        city: json['city'] as String?,
        notes: json['notes'] as String? ?? json['additionalInfo'] as String?,
      );

  String get fullAddress {
    final parts = [street, neighborhood, city]
        .whereType<String>()
        .where((p) => p.isNotEmpty)
        .toList();
    return parts.join(', ');
  }
}

class OrderCustomer {
  final int id;
  final String name;
  final String? phone;

  const OrderCustomer({
    required this.id,
    required this.name,
    this.phone,
  });

  factory OrderCustomer.fromJson(Map<String, dynamic> json) => OrderCustomer(
        id: json['id'] as int,
        name: json['name'] as String? ?? '',
        phone: json['phone'] as String?,
      );
}

class OrderItem {
  final int id;
  final String productName;
  final int quantity;
  final double unitPrice;
  final double subtotal;
  final String? notes;

  const OrderItem({
    required this.id,
    required this.productName,
    required this.quantity,
    required this.unitPrice,
    required this.subtotal,
    this.notes,
  });

  factory OrderItem.fromJson(Map<String, dynamic> json) => OrderItem(
        id: json['id'] as int,
        productName: json['productName'] as String? ?? '',
        quantity: json['quantity'] as int,
        unitPrice: (json['unitPrice'] as num).toDouble(),
        subtotal: (json['subtotal'] as num?)?.toDouble() ??
            ((json['quantity'] as int) * (json['unitPrice'] as num).toDouble()),
        notes: json['notes'] as String?,
      );
}

class OrderLineSummary {
  final String productName;
  final int quantity;
  final String? categoryName;

  const OrderLineSummary({
    required this.productName,
    required this.quantity,
    this.categoryName,
  });

  factory OrderLineSummary.fromJson(Map<String, dynamic> json) =>
      OrderLineSummary(
        productName: json['productName'] as String? ?? '',
        quantity: json['quantity'] as int? ?? 0,
        categoryName: json['categoryName'] as String?,
      );
}

class Order {
  /// Tolerancia COP al comparar total vs pagos (decimales / redondeo).
  static const double kPaymentCoverTolerance = 0.5;

  final int id;
  final OrderStatus status;
  final String type;
  final DateTime createdAt;
  final double total;
  final double? deliveryFee;
  final String? notes;
  final OrderCustomer? customer;
  final OrderAddress? address;
  final List<OrderItem> items;
  final int branchId;
  final String? branchName;
  final int? deliveryManId;
  final String? deliveryManName;

  /// Campos planos del API (OrderDto), alineados con el front web.
  final int? customerId;
  final int? addressId;
  final String? addressDescription;
  final String? addressAdditionalInfo;
  final int? neighborhoodId;
  final String? neighborhoodName;
  final double? latitude;
  final double? longitude;
  final String? deliveryRoutePlanningWarnings;
   final List<OrderLineSummary> summaryLines;

  /// Efectivo ya cobrado en sucursal (API).
  final bool paidInStoreCash;
  /// Monto registrado como cobrado en tienda (API); null = asumir pago completo.
  final double? paidInStoreCashAmount;
  /// Suma pagos banco+app cuando el JSON los trae; si no, 0.
  final double nonCashPaymentsTotal;

  const Order({
    required this.id,
    required this.status,
    required this.type,
    required this.createdAt,
    required this.total,
    this.deliveryFee,
    this.notes,
    this.customer,
    this.address,
    required this.items,
    required this.branchId,
    this.branchName,
    this.deliveryManId,
    this.deliveryManName,
    this.customerId,
    this.addressId,
    this.addressDescription,
    this.addressAdditionalInfo,
    this.neighborhoodId,
    this.neighborhoodName,
    this.latitude,
    this.longitude,
    this.deliveryRoutePlanningWarnings,
    this.summaryLines = const [],
    this.paidInStoreCash = false,
    this.paidInStoreCashAmount,
    this.nonCashPaymentsTotal = 0,
  });

  /// Efectivo a cobrar en entrega (alineado con backend / web).
  double get cashToCollectOnDelivery {
    if (paidInStoreCash) return 0;
    final raw = total - nonCashPaymentsTotal;
    return raw > 0 ? raw : 0;
  }

  /// Banco + app cubren el total del pedido.
  bool get paymentsCoverTotal =>
      total > kPaymentCoverTolerance &&
      nonCashPaymentsTotal >= total - kPaymentCoverTolerance;

  /// Cobro en sucursal cubre el total (`paidInStoreCashAmount` null = completo).
  bool get paidInStoreCoversTotal {
    if (!paidInStoreCash || total <= kPaymentCoverTolerance) return false;
    final amount = paidInStoreCashAmount;
    if (amount == null) return true;
    return amount >= total - kPaymentCoverTolerance;
  }

  /// Mostrar «Ya pagó» (transferencia/app o tienda cubren el total).
  bool get showYaPagoMessage =>
      total > kPaymentCoverTolerance &&
      (paymentsCoverTotal || paidInStoreCoversTotal);

  static double _sumPaymentAmounts(List<dynamic>? list) {
    if (list == null) return 0;
    var s = 0.0;
    for (final e in list) {
      if (e is Map<String, dynamic>) {
        final raw = e['amount'] ?? e['Amount'];
        if (raw is num) s += raw.toDouble();
      }
    }
    return s;
  }

  /// Línea principal de dirección para UI (flat o anidada).
  String? get displayAddressLine {
    final d = addressDescription?.trim();
    if (d != null && d.isNotEmpty) return d;
    final a = address?.fullAddress.trim();
    if (a != null && a.isNotEmpty) return a;
    return null;
  }

  /// Barrio para UI (API plano o dirección anidada).
  String? get displayNeighborhoodLabel {
    final n = neighborhoodName?.trim();
    if (n != null && n.isNotEmpty) return n;
    final a = address?.neighborhood?.trim();
    if (a != null && a.isNotEmpty) return a;
    return null;
  }

  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return null;
  }

  factory Order.fromJson(Map<String, dynamic> json) {
    final nestedCustomer = json['customer'] != null
        ? OrderCustomer.fromJson(json['customer'] as Map<String, dynamic>)
        : null;
    final flatCustomerId = json['customerId'] as int?;
    final flatName = json['customerName'] as String?;
    final flatPhone = json['customerPhone'] as String?;
    final customer = nestedCustomer ??
        ((flatCustomerId != null && flatCustomerId > 0) ||
                (flatName != null && flatName.isNotEmpty)
            ? OrderCustomer(
                id: flatCustomerId ?? 0,
                name: flatName ?? '',
                phone: flatPhone,
              )
            : null);

    final flatAddrDesc = json['addressDescription'] as String? ??
        json['AddressDescription'] as String?;
    final flatAddrInfo = json['addressAdditionalInfo'] as String? ??
        json['AddressAdditionalInfo'] as String?;
    final flatNeighborhoodName = json['neighborhoodName'] as String? ??
        json['NeighborhoodName'] as String?;
    final flatAddressId = json['addressId'] as int?;

    final nestedAddress = json['address'] != null
        ? OrderAddress.fromJson(json['address'] as Map<String, dynamic>)
        : null;

    final address = nestedAddress ??
        ((flatAddrDesc != null && flatAddrDesc.isNotEmpty) ||
                flatAddressId != null
            ? OrderAddress(
                id: flatAddressId,
                street: flatAddrDesc,
                neighborhood: flatNeighborhoodName,
                city: null,
                notes: flatAddrInfo,
              )
            : null);

    final details = json['orderDetails'] as List<dynamic>? ?? [];

    return Order(
      id: json['id'] as int,
      status: OrderStatus.fromApi(json['status'] as String? ?? 'taken'),
      type: json['type'] as String? ?? 'delivery',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      total: (json['total'] as num?)?.toDouble() ?? 0,
      deliveryFee: (json['deliveryFee'] as num?)?.toDouble(),
      notes: json['notes'] as String?,
      customer: customer,
      address: address,
      items: details
          .map((e) => OrderItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      branchId: json['branchId'] as int? ?? json['BranchId'] as int? ?? 0,
      branchName:
          json['branchName'] as String? ?? json['BranchName'] as String?,
      deliveryManId: json['deliveryManId'] as int?,
      deliveryManName: json['deliveryManName'] as String?,
      customerId: flatCustomerId ?? nestedCustomer?.id,
      addressId: flatAddressId ?? nestedAddress?.id,
      addressDescription: flatAddrDesc,
      addressAdditionalInfo: flatAddrInfo,
      neighborhoodId: json['neighborhoodId'] as int? ??
          json['NeighborhoodId'] as int?,
      neighborhoodName: flatNeighborhoodName,
      latitude: _toDouble(json['latitude']),
      longitude: _toDouble(json['longitude']),
      deliveryRoutePlanningWarnings:
          json['deliveryRoutePlanningWarnings'] as String?,
      summaryLines: (json['summaryLines'] as List<dynamic>? ?? [])
          .map((e) => OrderLineSummary.fromJson(e as Map<String, dynamic>))
          .toList(),
      paidInStoreCash: json['paidInStoreCash'] as bool? ?? false,
      paidInStoreCashAmount: _toDouble(json['paidInStoreCashAmount']),
      nonCashPaymentsTotal: _sumPaymentAmounts(json['bankPayments'] as List<dynamic>?) +
          _sumPaymentAmounts(json['appPayments'] as List<dynamic>?),
    );
  }

  Order copyWithAddressFields({
    String? addressDescription,
    String? addressAdditionalInfo,
    double? latitude,
    double? longitude,
    int? neighborhoodId,
    String? neighborhoodName,
  }) {
    final nextDesc = addressDescription ??
        this.addressDescription ??
        address?.street;
    final nextInfo = addressAdditionalInfo ?? this.addressAdditionalInfo;
    final nextNeighborhoodName = neighborhoodName ?? this.neighborhoodName;
    final nextNeighborhoodId = neighborhoodId ?? this.neighborhoodId;
    final nextLat = latitude ?? this.latitude;
    final nextLng = longitude ?? this.longitude;

    OrderAddress? nextAddress;
    if ((nextDesc != null && nextDesc.isNotEmpty) || address != null) {
      nextAddress = OrderAddress(
        id: addressId ?? address?.id,
        street: (nextDesc != null && nextDesc.isNotEmpty) ? nextDesc : address?.street,
        neighborhood: nextNeighborhoodName ?? address?.neighborhood,
        city: address?.city,
        notes: nextInfo ?? address?.notes,
      );
    }

    return Order(
      id: id,
      status: status,
      type: type,
      createdAt: createdAt,
      total: total,
      deliveryFee: deliveryFee,
      notes: notes,
      customer: customer,
      address: nextAddress,
      items: items,
      branchId: branchId,
      branchName: branchName,
      deliveryManId: deliveryManId,
      deliveryManName: deliveryManName,
      customerId: customerId,
      addressId: addressId,
      addressDescription: nextDesc,
      addressAdditionalInfo: nextInfo,
      neighborhoodId: nextNeighborhoodId,
      neighborhoodName: nextNeighborhoodName,
      latitude: nextLat,
      longitude: nextLng,
      deliveryRoutePlanningWarnings: deliveryRoutePlanningWarnings,
      summaryLines: summaryLines,
      paidInStoreCash: paidInStoreCash,
      paidInStoreCashAmount: paidInStoreCashAmount,
      nonCashPaymentsTotal: nonCashPaymentsTotal,
    );
  }
}

class PagedOrders {
  final List<Order> items;
  final int totalCount;
  final int page;
  final int pageSize;

  const PagedOrders({
    required this.items,
    required this.totalCount,
    required this.page,
    required this.pageSize,
  });

  bool get hasMore => (page * pageSize) < totalCount;

  factory PagedOrders.fromJson(Map<String, dynamic> json) => PagedOrders(
        items: (json['items'] as List<dynamic>? ?? [])
            .map((e) => Order.fromJson(e as Map<String, dynamic>))
            .toList(),
        totalCount: json['totalCount'] as int? ?? 0,
        page: json['page'] as int? ?? 1,
        pageSize: json['pageSize'] as int? ?? 10,
      );

  factory PagedOrders.empty() =>
      const PagedOrders(items: [], totalCount: 0, page: 1, pageSize: 10);
}

class BranchSummary {
  final int branchId;
  final String branchName;
  final int deliveredCount;
  /// Suma de fees de envío de los pedidos (100 %).
  final double totalDeliveryFee;
  /// Parte del domiciliario según política de nómina del servidor.
  final double payableDeliveryFee;

  const BranchSummary({
    required this.branchId,
    required this.branchName,
    required this.deliveredCount,
    required this.totalDeliveryFee,
    required this.payableDeliveryFee,
  });

  factory BranchSummary.fromJson(Map<String, dynamic> json) {
    final delivered = (json['deliveredCount'] as num?)?.toInt() ??
        (json['orderCount'] as num?)?.toInt() ??
        0;
    final totalFee = (json['totalDeliveryFee'] as num?)?.toDouble() ?? 0.0;
    final payableExplicit = json['payableDeliveryFee'] as num?;
    final double payableDeliveryFee;
    if (payableExplicit != null) {
      payableDeliveryFee = payableExplicit.toDouble();
    } else if (totalFee > 0) {
      payableDeliveryFee = totalFee * kDeliveryFeeDriverShare;
    } else {
      payableDeliveryFee =
          ((json['totalAmount'] as num?)?.toDouble() ?? 0) * kDeliveryFeeDriverShare;
    }
    return BranchSummary(
      branchId: json['branchId'] as int? ?? 0,
      branchName: json['branchName'] as String? ?? '',
      deliveredCount: delivered,
      totalDeliveryFee: totalFee,
      payableDeliveryFee: payableDeliveryFee,
    );
  }
}
