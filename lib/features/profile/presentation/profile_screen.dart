import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/updates/app_update_prefs.dart';
import '../../../core/updates/app_update_provider.dart';
import '../../../core/updates/app_update_widgets.dart';
import '../../../core/updates/delivery_app_release_manifest.dart';
import '../../auth/data/auth_models.dart';
import '../../auth/presentation/auth_notifier.dart';
import '../data/profile_image_url.dart';
import '../data/user_profile_repository.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _currentPass = TextEditingController();
  final _newPass = TextEditingController();
  final _confirmPass = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _loadingProfile = true;
  bool _saving = false;
  bool _savingPass = false;
  bool _uploading = false;
  int? _dismissedRemoteBuild;

  @override
  void initState() {
    super.initState();
    final u = ref.read(authNotifierProvider).user;
    if (u != null) {
      _emailCtrl.text = u.email;
      _phoneCtrl.text = u.phone ?? '';
    }
    getDismissedUpdateRemoteBuild().then((value) {
      if (mounted) setState(() => _dismissedRemoteBuild = value);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshFromApi());
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _currentPass.dispose();
    _newPass.dispose();
    _confirmPass.dispose();
    super.dispose();
  }

  Future<void> _refreshFromApi() async {
    final user = ref.read(authNotifierProvider).user;
    if (user == null) return;
    setState(() => _loadingProfile = true);
    try {
      final repo = ref.read(userProfileRepositoryProvider);
      final json = await repo.fetchUser(user.id);
      if (!mounted) return;
      final updated = AuthUser.fromUserApi(json, user);
      await ref.read(authNotifierProvider.notifier).updateSessionUser(updated);
      _emailCtrl.text = updated.email;
      _phoneCtrl.text = updated.phone ?? '';
    } catch (_) {
      /* datos locales */
    } finally {
      if (mounted) setState(() => _loadingProfile = false);
    }
  }

  String _initials(AuthUser u) {
    final parts =
        u.name.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty);
    if (parts.isEmpty) return '?';
    final s = parts.take(2).map((e) => e[0]).join();
    return s.toUpperCase();
  }

  Future<void> _pickAndUpload(AuthUser user) async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 2048,
      imageQuality: 88,
    );
    if (file == null || !mounted) return;

    setState(() => _uploading = true);
    try {
      final repo = ref.read(userProfileRepositoryProvider);
      final updated = await repo.uploadProfileImage(
        userId: user.id,
        file: File(file.path),
        current: user,
      );
      await ref.read(authNotifierProvider.notifier).updateSessionUser(updated);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Foto actualizada')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _saveProfile(AuthUser user) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      final repo = ref.read(userProfileRepositoryProvider);
      final updated = await repo.updateProfile(
        userId: user.id,
        email: _emailCtrl.text,
        phone: _phoneCtrl.text,
        current: user,
      );
      await ref.read(authNotifierProvider.notifier).updateSessionUser(updated);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Datos guardados')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _changePassword() async {
    final c = _currentPass.text;
    final n = _newPass.text;
    final cf = _confirmPass.text;
    if (c.isEmpty || n.isEmpty || cf.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Completa los campos de contraseña')),
      );
      return;
    }
    if (n.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('La nueva contraseña debe tener al menos 6 caracteres')),
      );
      return;
    }
    if (n != cf) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Las contraseñas nuevas no coinciden')),
      );
      return;
    }

    setState(() => _savingPass = true);
    try {
      await ref.read(userProfileRepositoryProvider).changePassword(
            currentPassword: c,
            newPassword: n,
            confirmPassword: cf,
          );
      _currentPass.clear();
      _newPass.clear();
      _confirmPass.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contraseña actualizada')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    } finally {
      if (mounted) setState(() => _savingPass = false);
    }
  }

  Future<void> _openUpdate(Uri uri) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No se pudo abrir el enlace')),
    );
  }

  Future<void> _dismissUpdate(AppUpdateCheckResult result) async {
    await setDismissedUpdateRemoteBuild(result.manifest.buildNumber);
    if (mounted) {
      setState(() => _dismissedRemoteBuild = result.manifest.buildNumber);
    }
  }

  Widget _buildUpdateSection() {
    final async = ref.watch(appUpdateCheckProvider);
    return async.when(
      data: (result) {
        if (result == null) return const SizedBox.shrink();
        final canDismiss = _dismissedRemoteBuild != result.manifest.buildNumber;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Aplicacion',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppTheme.spacingMd),
            AppUpdateCard(
              result: result,
              onDownload: () => _openUpdate(result.updateUri),
              onDismiss: canDismiss ? () => _dismissUpdate(result) : null,
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authNotifierProvider).user;
    if (user == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final imageUrl = resolveProfileImageUrl(user.profileImageUrl);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Mi perfil'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: _loadingProfile
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary))
          : ListView(
              padding: const EdgeInsets.all(AppTheme.spacingMd),
              children: [
                Center(
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      GestureDetector(
                        onTap: _uploading ? null : () => _pickAndUpload(user),
                        child: CircleAvatar(
                          radius: 48,
                          backgroundColor: AppColors.cardElevated,
                          child: ClipOval(
                            child: imageUrl != null
                                ? CachedNetworkImage(
                                    imageUrl: imageUrl,
                                    width: 96,
                                    height: 96,
                                    fit: BoxFit.cover,
                                    placeholder: (_, __) => const SizedBox(
                                      width: 32,
                                      height: 32,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    ),
                                    errorWidget: (_, __, ___) => Text(
                                      _initials(user),
                                      style: const TextStyle(
                                        fontSize: 22,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.primaryLight,
                                      ),
                                    ),
                                  )
                                : Text(
                                    _initials(user),
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.primaryLight,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                      if (_uploading)
                        const Positioned.fill(
                          child: Center(
                            child: SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Material(
                          color: AppColors.primary,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap:
                                _uploading ? null : () => _pickAndUpload(user),
                            child: const Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(Icons.camera_alt,
                                  size: 18, color: AppColors.onPrimary),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppTheme.spacingSm),
                Center(
                  child: Text(
                    'Toca la foto para cambiarla',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppColors.hint),
                  ),
                ),
                const SizedBox(height: AppTheme.spacingLg),
                Text(
                  user.name,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: AppTheme.spacingXs),
                Text(
                  'El nombre solo lo puede actualizar un administrador.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppColors.onSurface),
                ),
                const SizedBox(height: AppTheme.spacingLg),
                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _emailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Correo',
                          prefixIcon: Icon(Icons.email_outlined, size: 20),
                        ),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return 'Ingresa un correo';
                          }
                          if (!v.contains('@')) return 'Correo inválido';
                          return null;
                        },
                      ),
                      const SizedBox(height: AppTheme.spacingMd),
                      TextFormField(
                        controller: _phoneCtrl,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Teléfono',
                          prefixIcon: Icon(Icons.phone_outlined, size: 20),
                        ),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return 'Ingresa un teléfono';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: AppTheme.spacingLg),
                      ElevatedButton(
                        style: AppTheme.primaryButton,
                        onPressed: _saving ? null : () => _saveProfile(user),
                        child: _saving
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Guardar datos'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppTheme.spacingXl),
                Text(
                  'Contraseña',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppTheme.spacingMd),
                TextField(
                  controller: _currentPass,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Contraseña actual',
                    prefixIcon: Icon(Icons.lock_outline, size: 20),
                  ),
                ),
                const SizedBox(height: AppTheme.spacingSm),
                TextField(
                  controller: _newPass,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Nueva contraseña',
                    prefixIcon: Icon(Icons.lock_open, size: 20),
                  ),
                ),
                const SizedBox(height: AppTheme.spacingSm),
                TextField(
                  controller: _confirmPass,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirmar nueva',
                    prefixIcon: Icon(Icons.lock_outline, size: 20),
                  ),
                ),
                const SizedBox(height: AppTheme.spacingMd),
                OutlinedButton(
                  style: AppTheme.outlinedPrimary,
                  onPressed: _savingPass ? null : _changePassword,
                  child: _savingPass
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Cambiar contraseña'),
                ),
                const SizedBox(height: AppTheme.spacingXl),
                _buildUpdateSection(),
                const SizedBox(height: AppTheme.spacingXl),
              ],
            ),
    );
  }
}
