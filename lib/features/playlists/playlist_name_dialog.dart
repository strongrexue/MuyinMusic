import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

Future<String?> showPlaylistNameDialog(
  BuildContext context, {
  required String title,
  required String actionLabel,
  String initialValue = '',
}) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) => _PlaylistNameDialog(
      title: title,
      actionLabel: actionLabel,
      initialValue: initialValue,
    ),
  );
  return result == null || result.trim().isEmpty ? null : result.trim();
}

class _PlaylistNameDialog extends StatefulWidget {
  const _PlaylistNameDialog({
    required this.title,
    required this.actionLabel,
    required this.initialValue,
  });

  final String title;
  final String actionLabel;
  final String initialValue;

  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.initialValue.length,
      );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit([String? value]) {
    Navigator.of(context).pop((value ?? _controller.text).trim());
  }

  @override
  Widget build(BuildContext context) {
    // 玻璃确认框：输入框交给 AlertDialog 的 hasFields 统一样式（去掉 Material icon）。
    return prism.AlertDialog(
      title: widget.title,
      hasFields: true,
      actions: [
        prism.TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        prism.FilledButton(onPressed: _submit, child: Text(widget.actionLabel)),
      ],
      child: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 40,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: '歌单名称',
          hintText: '例如：夜晚循环',
        ),
        onSubmitted: _submit,
      ),
    );
  }
}
