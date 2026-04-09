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

  // Mapeo al valor que espera el backend .NET
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
        street: json['street'] as String?,
        neighborhood: json['neighborhood'] as String?,
        city: json['city'] as String?,
        notes: json['notes'] as String?,
      );

  String get fullAddress {
    final parts = [street, neighborhood, city]
        .where((p) => p != null && p.isNotEmpty)
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
        subtotal: (json['subtotal'] as num).toDouble(),
        notes: json['notes'] as String?,
      );
}

class Order {
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
  });

  factory Order.fromJson(Map<String, dynamic> json) => Order(
        id: json['id'] as int,
        status: OrderStatus.fromApi(json['status'] as String? ?? 'taken'),
        type: json['type'] as String? ?? 'delivery',
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
        total: (json['total'] as num?)?.toDouble() ?? 0,
        deliveryFee: (json['deliveryFee'] as num?)?.toDouble(),
        notes: json['notes'] as String?,
        customer: json['customer'] != null
            ? OrderCustomer.fromJson(
                json['customer'] as Map<String, dynamic>)
            : null,
        address: json['address'] != null
            ? OrderAddress.fromJson(json['address'] as Map<String, dynamic>)
            : null,
        items: (json['orderDetails'] as List<dynamic>? ?? [])
            .map((e) => OrderItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        branchId: json['branchId'] as int? ?? 0,
        branchName: json['branchName'] as String?,
        deliveryManId: json['deliveryManId'] as int?,
        deliveryManName: json['deliveryManName'] as String?,
      );
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
  final double totalAmount;

  const BranchSummary({
    required this.branchId,
    required this.branchName,
    required this.deliveredCount,
    required this.totalAmount,
  });

  factory BranchSummary.fromJson(Map<String, dynamic> json) => BranchSummary(
        branchId: json['branchId'] as int? ?? 0,
        branchName: json['branchName'] as String? ?? '',
        deliveredCount: json['deliveredCount'] as int? ?? 0,
        totalAmount: (json['totalAmount'] as num?)?.toDouble() ?? 0,
      );
}
