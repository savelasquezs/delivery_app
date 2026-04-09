import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/empty_state_widget.dart';
import '../../../core/widgets/error_banner.dart';
import '../../../core/widgets/order_card.dart';
import '../../../core/widgets/confirm_password_dialog.dart';
import '../../orders/models/order_models.dart';
import 'available_notifier.dart';

class AvailableScreen extends ConsumerStatefulWidget {
  const AvailableScreen({super.key});

  @override
  ConsumerState<AvailableScreen> createState() => _AvailableScreenState();
}

class _AvailableScreenState extends ConsumerState<AvailableScreen> {
  final Set<int> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(availableNotifierProvider.notifier).load();
    });
  }

  void _toggleSelection(int orderId) {
    setState(() {
      if (_selectedIds.contains(orderId)) {
        _selectedIds.remove(orderId);
      } else {
        _selectedIds.add(orderId);
      }
    });
  }

  Future<void> _confirmAssignment() async {
    if (_selectedIds.isEmpty) return;
    final selectedList = List<int>.from(_selectedIds);

    final confirmed = await ConfirmPasswordDialog.show(
      context,
      title: 'Confirmar asignación',
      subtitle:
          'Se asignarán ${selectedList.length} pedido(s) a tu nombre. Ingresa tu contraseña para continuar.',
      onConfirm: (password) async {
        await ref.read(availableNotifierProvider.notifier).selfAssign(
              orderIds: selectedList,
              password: password,
            );
      },
    );

    if (confirmed && mounted) {
      setState(() => _selectedIds.clear());
      ErrorBanner.showSuccess(
          context, 'Pedido(s) asignado(s) exitosamente');
      ref.read(availableNotifierProvider.notifier).load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(availableNotifierProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        onRefresh: () => ref.read(availableNotifierProvider.notifier).load(),
        color: AppColors.primary,
        backgroundColor: AppColors.card,
        child: CustomScrollView(
          slivers: [
            if (state.error != null)
              SliverToBoxAdapter(
                child: ErrorBanner(
                  message: state.error!,
                  onRetry: () =>
                      ref.read(availableNotifierProvider.notifier).load(),
                ),
              ),
            if (state.isLoading && state.orders.isEmpty)
              const SliverFillRemaining(
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                ),
              )
            else if (state.orders.isEmpty && !state.isLoading)
              SliverFillRemaining(
                child: EmptyStateWidget(
                  icon: Icons.inbox_outlined,
                  title: 'Sin pedidos disponibles',
                  subtitle: 'Cuando haya pedidos listos para entrega,\naparecerán aquí',
                  onRefresh: () =>
                      ref.read(availableNotifierProvider.notifier).load(),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.all(AppTheme.spacingMd),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final order = state.orders[index];
                      final isSelected = _selectedIds.contains(order.id);
                      return Padding(
                        padding: const EdgeInsets.only(
                            bottom: AppTheme.spacingSm),
                        child: _SelectableOrderCard(
                          order: order,
                          isSelected: isSelected,
                          onToggle: () => _toggleSelection(order.id),
                        ),
                      );
                    },
                    childCount: state.orders.length,
                  ),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: _selectedIds.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: _confirmAssignment,
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.onPrimary,
              icon: const Icon(Icons.delivery_dining),
              label: Text('Asignarme (${_selectedIds.length})'),
            )
          : null,
    );
  }
}

class _SelectableOrderCard extends StatelessWidget {
  final Order order;
  final bool isSelected;
  final VoidCallback onToggle;

  const _SelectableOrderCard({
    required this.order,
    required this.isSelected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(
          color: isSelected ? AppColors.primary : Colors.transparent,
          width: 2,
        ),
      ),
      child: OrderCard(
        order: order,
        onTap: onToggle,
        trailing: Row(
          children: [
            Checkbox(
              value: isSelected,
              onChanged: (_) => onToggle(),
              activeColor: AppColors.primary,
              checkColor: AppColors.onPrimary,
              side: const BorderSide(color: AppColors.hint),
            ),
            const SizedBox(width: AppTheme.spacingSm),
            Text(
              isSelected ? 'Seleccionado' : 'Seleccionar para asignar',
              style: TextStyle(
                color: isSelected ? AppColors.primary : AppColors.hint,
                fontSize: 12,
                fontWeight:
                    isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
