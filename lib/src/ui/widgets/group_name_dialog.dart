import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

/// 新建/重命名分组时用的输入框。
///
/// 它只是 `showDialog`，不是新页面；网格和设置页共用同一套输入/校验，
/// 免得两处对"空名字算不算有效"判断不一致。
Future<String?> showGroupNameDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String? initialValue,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _GroupNameDialog(
      title: title,
      confirmLabel: confirmLabel,
      initialValue: initialValue,
    ),
  );
}

class _GroupNameDialog extends StatefulWidget {
  const _GroupNameDialog({
    required this.title,
    required this.confirmLabel,
    this.initialValue,
  });

  final String title;
  final String confirmLabel;
  final String? initialValue;

  @override
  State<_GroupNameDialog> createState() => _GroupNameDialogState();
}

class _GroupNameDialogState extends State<_GroupNameDialog> {
  late final TextEditingController _name;
  bool _canSubmit = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialValue ?? '');
    _canSubmit = _name.text.trim().isNotEmpty;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _name,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onChanged: (value) {
          final can = value.trim().isNotEmpty;
          if (can != _canSubmit) setState(() => _canSubmit = can);
        },
        onSubmitted: (_) {
          if (_canSubmit) _submit();
        },
        decoration: InputDecoration(
          labelText: l10n.profileGroupNameLabel,
          hintText: l10n.profileGroupNameHint,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
