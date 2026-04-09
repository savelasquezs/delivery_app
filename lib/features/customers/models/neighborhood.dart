class Neighborhood {
  final int id;
  final int branchId;
  final String name;
  final int deliveryFee;

  const Neighborhood({
    required this.id,
    required this.branchId,
    required this.name,
    required this.deliveryFee,
  });

  factory Neighborhood.fromJson(Map<String, dynamic> json) => Neighborhood(
        id: json['id'] as int,
        branchId: json['branchId'] as int? ?? 0,
        name: json['name'] as String? ?? '',
        deliveryFee: (json['deliveryFee'] as num?)?.round() ?? 0,
      );
}
