import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../config/assistant_config.dart';
import '../conversation/conversation_controller.dart';
import 'profile_editor.dart';

/// 频道设置页。
///
/// 两种入口：
/// - [ChannelSettingsPage.edit]：编辑配置里已有的频道；
/// - [ChannelSettingsPage.create]：编辑一份**草稿**，点保存才真正创建。
///
/// 新建模式不会在打开页面时落盘。直接返回或放弃时草稿随页面一起丢掉，
/// 不会在网格里留下一个空白频道。
class ChannelSettingsPage extends StatefulWidget {
  /// 编辑现有频道。
  const ChannelSettingsPage.edit({
    super.key,
    required this.controller,
    required this.profileId,
  }) : isNew = false,
       groupId = null;

  /// 新建频道。草稿保存后才创建；[groupId] 为 null 表示未分组。
  const ChannelSettingsPage.create({
    super.key,
    required this.controller,
    this.groupId,
  }) : isNew = true,
       profileId = null;

  final ConversationController controller;

  /// 编辑模式下的频道 id。
  final String? profileId;

  /// 新建模式下的预设分组。
  final String? groupId;

  /// true = 新建草稿；false = 编辑现有频道。
  final bool isNew;

  @override
  State<ChannelSettingsPage> createState() => _ChannelSettingsPageState();
}

class _ChannelSettingsPageState extends State<ChannelSettingsPage> {
  final GlobalKey<ProfileEditorState> _editor = GlobalKey<ProfileEditorState>();

  /// 新建模式下的草稿。id 先分配好，保存时原样落盘 —— 不保存就永远不出现
  /// 在配置里。
  Profile? _draft;

  /// 保存中。除了禁用按钮，还要挡住连点：`ProfileEditor.commit` 在忙时会
  /// 直接返回 true，第二次点击若继续走 pop 会把宿主页面也弹掉。
  bool _saving = false;

  AppLocalizations get _l10n => AppLocalizations.of(context);

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 拿到当前这一屏要编辑的档案；编辑模式下找不到（已被删）返回 null。
  Profile? _profile(AppLocalizations l10n) {
    if (widget.isNew) {
      return _draft ??= Profile(
        id: Profile.newId(),
        name: l10n.newChannelName,
        // 未到同时打开上限时，草稿默认开着；到上限时先关着，避免"新建"
        // 绕过上限。用户仍可在表单里手动打开，保存时会被上限拦住。
        enabled:
            widget.controller.openProfileCount <
            widget.controller.maxOpenProfiles,
      );
    }
    final id = widget.profileId;
    if (id == null) return null;
    final index = widget.controller.config.profiles.indexWhere(
      (profile) => profile.id == id,
    );
    return index < 0 ? null : widget.controller.config.profiles[index];
  }

  Future<void> _save() async {
    if (_saving) return;
    final editor = _editor.currentState;
    if (editor == null || editor.busy) return;
    final l10n = _l10n;
    final atCapacity =
        widget.controller.openProfileCount >= widget.controller.maxOpenProfiles;
    final wantsEnabled = editor.enabled;

    setState(() => _saving = true);
    try {
      final written = await editor.commit();
      if (!written) {
        _toast(l10n.profileGoneUnsaved);
        return;
      }
      if (!mounted) return;
      // 到上限时新频道只能以关闭状态创建，得说清楚原因，否则用户会以为
      // 保存没生效。
      if (widget.isNew && atCapacity && !wantsEnabled) {
        _toast(l10n.profileAtCapacity(widget.controller.maxOpenProfiles));
      }
      Navigator.of(context).pop();
    } on ProfileAtCapacityException {
      _toast(l10n.profileAtCapacity(widget.controller.maxOpenProfiles));
    } catch (e) {
      _toast(l10n.saveFailed('$e'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 返回：有未保存的修改才拦下来确认。
  Future<void> _handleBack() async {
    if (!mounted || _saving || (_editor.currentState?.busy ?? false)) return;
    final dirty = _editor.currentState?.isDirty ?? false;
    if (!dirty) {
      Navigator.of(context).pop();
      return;
    }

    final l10n = _l10n;
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.discardChangesTitle),
        content: Text(l10n.discardChangesBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.discard),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  void _onDeleted() {
    if (!mounted) return;
    // 删除写盘期间用户可能已经手动返回了一页；只在当前路由仍是最上层时
    // 再 pop，避免把宿主页面也弹掉。
    if (ModalRoute.of(context)?.isCurrent != true) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return PopScope(
      // 永远先走 [_handleBack]，自己判断有没有未保存的修改。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_handleBack());
      },
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final profile = _profile(l10n);
          return Scaffold(
            appBar: AppBar(
              title: Text(l10n.channelSettingsTitle),
              actions: [
                TextButton(
                  onPressed: profile == null || _saving ? null : _save,
                  child: Text(l10n.save),
                ),
              ],
            ),
            body: profile == null
                // 页面打开期间频道被删了。没有可编辑的对象，也不该假装保存成功。
                ? Center(child: Text(l10n.profileGoneUnsaved))
                : ProfileEditor(
                    key: _editor,
                    controller: widget.controller,
                    profile: profile,
                    isNew: widget.isNew,
                    initialGroupId: widget.isNew ? widget.groupId : null,
                    onDeleted: _onDeleted,
                  ),
          );
        },
      ),
    );
  }
}
