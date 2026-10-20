import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../core/theme/app_theme.dart';
import 'employee_leave.dart';

Future<LeaveUpload?> pickLeaveUpload({String evidenceCode = 'additional', int? replacesAttachmentId}) async {
  Uint8List? bytes;
  try {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom,
      allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'], allowMultiple: false, withData: false);
    if (result == null) return null;
    final file = result.files.single;
    if (file.size <= 0 || file.size > leaveMaxBytes) throw const LeaveFailure('Selecciona un archivo de hasta 5 MB.');
    bytes = await file.xFile.readAsBytes();
    return LeaveUpload(const Uuid().v4(), file.name, bytes, evidenceCode: evidenceCode, replacesAttachmentId: replacesAttachmentId);
  } catch (_) { bytes?.fillRange(0, bytes.length, 0); rethrow; }
  finally { try { await FilePicker.platform.clearTemporaryFiles(); } catch (_) { /* Only plugin temporary copies are cleared. */ } }
}

class LeaveSectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;
  const LeaveSectionCard({super.key, required this.title, required this.icon, required this.children});
  @override
  Widget build(BuildContext context) => Card(margin: const EdgeInsets.only(bottom: AppTheme.spacingMd),
    child: Padding(padding: const EdgeInsets.all(AppTheme.spacingMd), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary), const SizedBox(width: 8),
        Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)))]),
      const SizedBox(height: 16),
      for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: 12), children[i]],
    ])));
}

class LeaveStatusChip extends StatelessWidget {
  final String status;
  final String? label;
  const LeaveStatusChip(this.status, {super.key, this.label});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = switch (status) {
      'approved' || 'verified' || 'paid' => dark ? Colors.green.shade300 : Colors.green.shade800,
      'denied' || 'rejected' => dark ? Colors.red.shade300 : Colors.red.shade800,
      'pending' || 'missing' => dark ? Colors.amber.shade200 : Colors.orange.shade800,
      'postponed' || 'submitted' => dark ? Colors.blue.shade200 : Colors.blue.shade800,
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };
    return Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
      child: Text(label ?? leaveStatuses[status] ?? leaveSupportStatuses[status] ?? status,
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)));
  }
}

class LeaveEvidencePicker extends StatelessWidget {
  final List<LeaveUpload> files;
  final List<Map<String, dynamic>> requirements;
  final List<LeaveAttachment> existing;
  final bool disabled;
  final VoidCallback onAdd;
  final void Function(LeaveUpload) onRemove;
  final void Function(LeaveUpload, String) onPurpose;
  const LeaveEvidencePicker({super.key, required this.files, required this.requirements, required this.onAdd,
    required this.onRemove, required this.onPurpose, this.existing = const [], this.disabled = false});
  bool covered(String code) => files.any((x) => x.evidenceCode == code)
    || existing.any((x) => x.evidenceCode == code && x.supersededAt == null && x.reviewStatus != 'rejected');
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme.bodySmall;
    final options = [...requirements, {'code': 'additional', 'label': 'Información adicional'}];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ...requirements.map((rule) => Padding(padding: const EdgeInsets.only(bottom: 10), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(covered(rule['code'] as String) ? Icons.check_circle_outline : Icons.description_outlined, size: 18,
          color: Theme.of(context).colorScheme.primary), const SizedBox(width: 8),
        Expanded(child: Text('${rule['label']}\n${rule['required'] == true ? rule['stage'] == 'before' ? 'Obligatorio antes de enviar' : 'Después del evento; no bloquea el aviso' : 'Opcional'}', style: text)),
      ]))),
      ...files.map((file) => Padding(padding: const EdgeInsets.only(bottom: 12), child: Column(children: [
        Row(children: [const Icon(Icons.insert_drive_file_outlined, size: 20), const SizedBox(width: 8),
          Expanded(child: Text('${file.name}\n${(file.bytes.length / 1024).ceil()} KB', style: text)),
          IconButton(onPressed: disabled ? null : () => onRemove(file), tooltip: 'Retirar ${file.name}', icon: const Icon(Icons.close, size: 18))]),
        DropdownButtonFormField<String>(key: ValueKey('${file.key}:${file.evidenceCode}'), initialValue: file.evidenceCode,
          isExpanded: true, decoration: const InputDecoration(labelText: 'Este documento acredita'),
          items: options.map((rule) => DropdownMenuItem(value: rule['code'] as String, child: Text(rule['label'] as String, overflow: TextOverflow.ellipsis))).toList(),
          onChanged: disabled ? null : (value) { if (value != null) onPurpose(file, value); }),
      ]))),
      if (files.length + existing.where((x) => x.supersededAt == null).length < 5)
        OutlinedButton.icon(onPressed: disabled ? null : onAdd, icon: const Icon(Icons.upload_file_outlined), label: const Text('Adjuntar documento')),
      const SizedBox(height: 8), Text('PDF, JPG o PNG · Hasta 5 MB por archivo. Acceso privado; no adjuntes una historia clínica.', style: text),
    ]);
  }
}
