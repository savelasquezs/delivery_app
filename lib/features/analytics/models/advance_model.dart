/// Abono/préstamo del domiciliario — alineado con DeliverymanAdvance del front web.
class DeliverymanAdvance {
  final int id;
  final double amount;
  final String? notes;
  final String createdAt;
  final String? branchName;
  final String? createdByName;

  const DeliverymanAdvance({
    required this.id,
    required this.amount,
    this.notes,
    required this.createdAt,
    this.branchName,
    this.createdByName,
  });

  factory DeliverymanAdvance.fromJson(Map<String, dynamic> json) =>
      DeliverymanAdvance(
        id: json['id'] as int? ?? 0,
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        notes: json['notes'] as String?,
        createdAt: json['createdAt'] as String? ?? '',
        branchName: json['branchName'] as String?,
        createdByName: json['createdByName'] as String?,
      );
}
