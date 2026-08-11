import 'package:flutter/material.dart';

abstract class AppColors {
  // ── Acento primario: Morado ──────────────────────────────────────
  static const Color primary = Color(0xFF8B5CF6); // Violet-500
  static const Color primaryDark = Color(0xFF7C3AED); // Violet-600
  static const Color primaryLight = Color(0xFFA78BFA); // Violet-400
  static const Color primaryContainer =
      Color(0xFF1E1040); // Fondo morado oscuro

  // ── Acento secundario: Verde (delivery / success) ────────────────
  static const Color accent = Color(0xFF2ECC71);
  static const Color accentDark = Color(0xFF27AE60);
  static const Color accentLight = Color(0xFF58D68D);
  static const Color accentContainer = Color(0xFF1A3A27);

  // ── Superficies oscuras ───────────────────────────────────────────
  static const Color background = Color(0xFF0F0F13);
  static const Color surface = Color(0xFF1A1A24);
  static const Color card = Color(0xFF22222E);
  static const Color cardElevated = Color(0xFF2A2A3A);

  // ── Texto ─────────────────────────────────────────────────────────
  static const Color onBackground = Color(0xFFEEEEF5);
  static const Color onSurface = Color(0xFFCCCCD8);
  static const Color onCard = Color(0xFFBBBBC8);
  static const Color onPrimary = Color(0xFFFFFFFF);

  // ── Semánticos ────────────────────────────────────────────────────
  static const Color error = Color(0xFFFF5370);
  static const Color warning = Color(0xFFFFC107);
  static const Color info = Color(0xFF40C4FF);
  static const Color success = Color(0xFF2ECC71);

  // ── UI ────────────────────────────────────────────────────────────
  static const Color divider = Color(0xFF2C2C3E);
  static const Color inputFill = Color(0xFF1E1E2C);
  static const Color hint = Color(0xFF6B6B8A);
  static const Color disabled = Color(0xFF3A3A4A);

  // ── Estados de pedido ─────────────────────────────────────────────
  static const Color statusTaken = Color(0xFF40C4FF);
  static const Color statusPreparation = Color(0xFFFFC107);
  static const Color statusReady = Color(0xFFCE93D8); // lila suave
  static const Color statusOnTheWay = Color(0xFF2ECC71); // verde
  static const Color statusDelivered = Color(0xFF27AE60);
  static const Color statusCancelled = Color(0xFFFF5370);
}
