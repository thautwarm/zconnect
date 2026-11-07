import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../l10n/app_localizations.dart';
import '../config/assistant_config.dart';
import '../conversation/conversation_controller.dart';
import 'widgets/group_name_dialog.dart';
import 'widgets/settings_widgets.dart';

/// 一个频道的全部设置。
///
/// 它只负责**表单本身和落盘**，页面外壳（标题、保存按钮、返回确认）由
/// `ChannelSettingsPage` 负责。这样编辑现有频道和新建草稿共用同一份表单。
///
/// `isNew == true` 时 [profile] 是一份**还没写进配置的草稿**：`commit()`
/// 会走 `saveProfile` 把它创建出来，再归入 [initialGroupId]（null = 未分组）。
/// `isNew == false` 时按原来的方式更新配置里现有的那一份。
///
/// 编辑状态（输入框里的字、挑好还没保存的头像）留在本 widget 里，落盘由
/// [ProfileEditorState.commit] 负责。
class ProfileEditor extends StatefulWidget {
  const ProfileEditor({
    super.key,
    required this.controller,
    required this.profile,
    this.isNew = false,
    this.initialGroupId,
    this.onDeleted,
  });

  final ConversationController controller;

  /// 正在编辑的档案。**以父级从配置里现取的那一份为准**，不要缓存。
  ///
  /// 新建模式下这一份是草稿，只用来承载初始值。
  final Profile profile;

  /// 新建草稿：保存前不存在于配置里。
  final bool isNew;

  /// 新建草稿的预设分组。null = 未分组。编辑模式下忽略。
  final String? initialGroupId;

  /// 删除成功后回调（页面用它 pop 回频道网格）。编辑模式才会触发。
  final VoidCallback? onDeleted;

  @override
  State<ProfileEditor> createState() => ProfileEditorState();
}

class ProfileEditorState extends State<ProfileEditor> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _brainId;
  late final TextEditingController _token;

  late int _accent;
  late bool _enabled;

  /// 正在编辑的档案所属分组。null = 未分组。
  ///
  /// 它和名字/brain 一样是**待保存状态**，由 [commit] 写入分组存储。
  String? _groupId;

  /// 下拉框里代表"未分组"的哨兵值。组 id 是 `g_` 开头，不会撞。
  static const String _ungroupedGroup = '__ungrouped__';

  /// 新挑的头像的**临时路径**。保存时才拷进应用目录 —— 取消了直接丢掉，
  /// 不会在应用目录里留一份没人引用的图。
  String? _pickedAvatar;

  /// 用户按了"去掉头像"。
  bool _clearAvatar = false;

  int _historyBytes = 0;
  bool _busy = false;
  bool _deleting = false;

  /// 保存或删除正在进行。页面用它挡住返回键，避免删到一半又 pop 一次。
  bool get busy => _busy || _deleting;

  /// 上一次加载/保存时的值。用来判断有没有未保存的修改 —— 返回时要靠它
  /// 决定弹不弹「放弃修改」的确认框。
  late String _savedName;
  late String _savedBaseUrl;
  late String _savedBrainId;
  late String _savedToken;
  late int _savedAccent;
  late bool _savedEnabled;
  late String? _savedGroupId;

  /// 预设主题色。用色块而不是调色盘：一眼看全、点了就跑。
  /// 第一个和全局种子色一致，默认档案看着不突兀。
  static const List<int> _presetColors = [
    Profile.defaultAccentColor,
    0xFF2E7D6B,
    0xFF9C4B2F,
    0xFF7B4FA8,
    0xFF1F6FB2,
    0xFFB0722B,
    0xFFB03A5B,
    0xFF4A5A66,
  ];

  List<String> _colorNames(AppLocalizations l10n) => [
    l10n.colorIndigo,
    l10n.colorInkGreen,
    l10n.colorTerracotta,
    l10n.colorPurple,
    l10n.colorLakeBlue,
    l10n.colorOchre,
    l10n.colorRose,
    l10n.colorSlate,
  ];

  @override
  void initState() {
    super.initState();
    _name = TextEditingController();
    _baseUrl = TextEditingController();
    _brainId = TextEditingController();
    _token = TextEditingController();
    _load(widget.profile);
  }

  @override
  void didUpdateWidget(covariant ProfileEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只有"换了一个档案"才重填输入框。同一个档案被别处改了配置（比如
    // 主界面切了焦点）不能重填 —— 那样会把你正在敲的字冲掉。
    if (oldWidget.profile.id != widget.profile.id) _load(widget.profile);
  }

  void _load(Profile profile) {
    _name.text = profile.name;
    _baseUrl.text = profile.brain.baseUrl;
    _brainId.text = profile.brain.brainId;
    _token.text = profile.brain.token;
    _accent = profile.accentColor;
    _enabled = profile.enabled;
    // 新建时用来源分组的预设值；编辑时以分组存储里的实际归属为准。
    final preset = widget.isNew
        ? widget.initialGroupId
        : widget.controller.groupIdOf(profile.id);
    // 组可能在打开页面之前被删了，别留一个悬空 id。
    _groupId = widget.controller.profileGroups.any((g) => g.id == preset)
        ? preset
        : null;
    _captureSaved();
    _pickedAvatar = null;
    _clearAvatar = false;
    _historyBytes = 0;
    // 草稿还没有历史，别为它读盘（更没必要为它显示使用量）。
    if (!widget.isNew) unawaited(_loadHistorySize());
  }

  /// 记下此刻的值作为「已保存」基准。
  void _captureSaved() {
    _savedName = _name.text;
    _savedBaseUrl = _baseUrl.text;
    _savedBrainId = _brainId.text;
    _savedToken = _token.text;
    _savedAccent = _accent;
    _savedEnabled = _enabled;
    _savedGroupId = _groupId;
  }

  /// 表单里「启用」开关当前的值。页面用它判断保存后要不要提示上限。
  bool get enabled => _enabled;

  /// 表单里有没有还没落盘的内容。
  ///
  /// 头像只看「挑过/去掉过」的标志：真去读盘比较文件哈希既慢又没必要，
  /// 这两个标志已经覆盖了用户做过的动作。
  bool get isDirty {
    if (_pickedAvatar != null || _clearAvatar) return true;
    return _name.text != _savedName ||
        _baseUrl.text != _savedBaseUrl ||
        _brainId.text != _savedBrainId ||
        _token.text != _savedToken ||
        _accent != _savedAccent ||
        _enabled != _savedEnabled ||
        _groupId != _savedGroupId;
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _brainId.dispose();
    _token.dispose();
    super.dispose();
  }

  /// 配置里此刻的那一份。找不到（已经被删）返回 null。
  Profile? _current() {
    final index = widget.controller.config.profiles.indexWhere(
      (p) => p.id == widget.profile.id,
    );
    return index < 0 ? null : widget.controller.config.profiles[index];
  }

  Future<void> _loadHistorySize() async {
    final bytes = await widget.controller.historyBytes(widget.profile.id);
    if (!mounted) return;
    setState(() => _historyBytes = bytes);
  }

  // ------------------------------------------------------------ 落盘

  /// 把这一屏的改动写进配置。
  ///
  /// 新建模式会在这里真正创建频道（`saveProfile`），并归入
  /// [ProfileEditor.initialGroupId]；保存之前配置里什么都没有。
  ///
  /// 编辑模式**从配置里重新取一次档案再改** —— 拿 widget 里那份快照写回
  /// 会把别处刚存的字段回滚掉。
  ///
  /// 失败会抛（打开数超过上限、头像拷不进去之类），由调用方决定怎么提示。
  ///
  /// 返回**有没有真的写进去**。编辑的档案已经被删掉时返回 false —— 调用方
  /// 这时候不能弹"已保存"：改的名字、填的地址其实一个都没落盘。
  Future<bool> commit() async {
    if (_busy) return true; // 已经在写了，别重复写
    final current = widget.isNew ? widget.profile : _current();
    if (current == null) return false; // 档案已经被删了
    _busy = true;
    var created = false;
    Profile? createdProfile;
    try {
      final next = current.copyWith(
        name: _name.text.trim(),
        brain: BrainConfig(
          baseUrl: _baseUrl.text.trim(),
          brainId: _brainId.text.trim(),
          token: _token.text.trim(),
        ),
        accentColor: _accent,
        enabled: _enabled,
        // 头像**不在这里清**：clearAvatar 一清，就不知道该删哪个文件了。
        // 去掉头像走 setAvatar(id, null)，它读到的还是旧文件名。
      );
      await widget.controller.saveProfile(next);
      created = widget.isNew;
      createdProfile = next;

      // 分组存在独立 key 里，走 controller 的分组接口；组如果已经被删了，
      // 就当未分组写回，不能留一个悬空 id。
      final groups = widget.controller.profileGroups;
      final groupId = groups.any((group) => group.id == _groupId)
          ? _groupId
          : null;
      await widget.controller.assignProfileGroup(next.id, groupId);
      _groupId = groupId;

      final picked = _pickedAvatar;
      if (picked != null) {
        await widget.controller.setAvatar(next.id, picked);
      } else if (_clearAvatar && !widget.isNew) {
        await widget.controller.setAvatar(next.id, null);
      }
      _pickedAvatar = null;
      _clearAvatar = false;
      _captureSaved();
    } on ProfileAtCapacityException {
      // 没写进去，界面上的开关也要退回去 —— 否则用户会看到一个"开着"、
      // 实际没有落盘的档案。
      if (mounted) setState(() => _enabled = current.enabled);
      rethrow;
    } catch (_) {
      // 新建时 `saveProfile` 已经让频道落盘了；后面任一步失败都必须回滚，
      // 否则用户点"放弃"回到网格，会发现凭空多了一个频道。
      if (created && createdProfile != null) {
        try {
          await widget.controller.removeProfile(createdProfile.id);
        } catch (_) {
          // 回滚失败也保留原始错误；至少不要假装保存成功。
        }
      }
      rethrow;
    } finally {
      _busy = false;
    }
    // 草稿刚创建时还没有历史，不需要查盘上大小。
    if (!widget.isNew) await _loadHistorySize();
    return true;
  }

  // ------------------------------------------------------------ 头像

  Future<void> _pickAvatar() async {
    final l10n = _l10n;
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        // 只缩到够用的尺寸，**不裁剪**：头像原样等比铺在说话按钮上，
        // 该不该裁是显示端的事（答案是不裁，透明的地方露出底色）。
        // 缩是因为相册里的原图动辄十几 MB，拷一份进来没必要。
        maxWidth: 512,
        maxHeight: 512,
      );
    } catch (e) {
      _toast(l10n.avatarPickFailed('$e'));
      return;
    }
    if (picked == null) return; // 用户取消了

    final path = picked.path;
    setState(() {
      _pickedAvatar = path;
      _clearAvatar = false;
    });
  }

  void _dropAvatar() {
    setState(() {
      _pickedAvatar = null;
      _clearAvatar = true;
    });
  }

  /// 当前该显示哪张图。新挑的优先（想立刻看到效果），否则读盘上的。
  ImageProvider? _avatarImage() {
    if (_clearAvatar) return null;
    final picked = _pickedAvatar;
    if (picked != null) return FileImage(File(picked));
    final path = widget.controller.avatarPathOf(widget.profile);
    return path == null ? null : FileImage(File(path));
  }

  // ------------------------------------------------------------ 危险动作

  AppLocalizations get _l10n => AppLocalizations.of(context);

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String action,
  }) {
    final cancelText = _l10n.cancel;
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(cancelText),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
  }

  Future<void> _clearHistory() async {
    final l10n = _l10n;
    final ok = await _confirm(
      title: l10n.clearHistoryTitle,
      body: l10n.clearHistoryBody,
      action: l10n.clear,
    );
    if (ok != true) return;
    await widget.controller.clearHistory(widget.profile.id);
    await _loadHistorySize();
    _toast(l10n.historyCleared);
  }

  Future<void> _delete() async {
    if (_deleting) return;
    final l10n = _l10n;
    final ok = await _confirm(
      title: l10n.deleteProfileTitle(widget.profile.displayName),
      body: l10n.deleteProfileBody,
      action: l10n.delete,
    );
    if (ok != true) return;
    setState(() => _deleting = true);
    try {
      await widget.controller.removeProfile(widget.profile.id);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
    if (!mounted) return;
    // 独立页面里由父级 pop 回频道网格；没给回调时保持原行为（不自作主张）。
    widget.onDeleted?.call();
  }

  Future<void> _createGroupAndSelect() async {
    final l10n = _l10n;
    final name = await showGroupNameDialog(
      context,
      title: l10n.profileNewGroup,
      confirmLabel: l10n.profileGroupCreate,
    );
    if (name == null || !mounted) return;
    final group = await widget.controller.createGroup(name);
    if (!mounted) return;
    setState(() => _groupId = group.id);
    _toast(l10n.profileGroupCreated(name));
  }

  // ------------------------------------------------------------ 界面

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final profile = widget.profile;
    final focused = widget.controller.config.focusedProfileId == profile.id;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        SettingsSection(
          title: l10n.profileAppearance,
          children: [
            _avatarRow(theme),
            const SizedBox(height: 14),
            SettingsTextField(
              controller: _name,
              label: l10n.nameLabel,
              hint: l10n.nameHint,
            ),
            const SizedBox(height: 4),
            Text(
              l10n.themeColor,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            _swatches(theme),
          ],
        ),
        const SizedBox(height: 16),
        SettingsSection(
          title: 'Brain',
          children: [
            SettingsTextField(
              controller: _baseUrl,
              label: l10n.baseUrlLabel,
              hint: l10n.baseUrlHint,
            ),
            SettingsTextField(
              controller: _brainId,
              label: l10n.brainIdLabel,
              hint: l10n.brainIdHint,
            ),
            SettingsTextField(
              controller: _token,
              label: l10n.tokenLabel,
              hint: l10n.tokenHint,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _groupSection(theme, l10n),
        const SizedBox(height: 16),
        SettingsSection(
          title: l10n.statusSection,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.enabled),
              subtitle: Text(
                _enabled ? l10n.enabledSubtitleOn : l10n.enabledSubtitleOff,
                style: theme.textTheme.bodySmall,
              ),
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
            ),
            if (!_enabled && focused)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l10n.focusedDisabledWarning,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            // 草稿还没落盘，不能切过去；只有编辑现有频道时才给这个入口。
            if (!widget.isNew && _enabled && !focused) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => widget.controller.switchProfile(profile.id),
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  label: Text(l10n.switchToThisProfile),
                ),
              ),
              Text(
                l10n.switchBySwipeHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
        // 草稿还没有历史：整段都不显示，也不查盘上的大小。
        if (!widget.isNew) ...[
          const SizedBox(height: 16),
          SettingsSection(
            title: l10n.historySection,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.historyUsage(formatBytes(_historyBytes)),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _historyBytes == 0 ? null : _clearHistory,
                    child: Text(l10n.clear),
                  ),
                ],
              ),
            ],
          ),
        ],
        if (!widget.isNew) ...[
          const SizedBox(height: 24),
          Center(
            child: TextButton.icon(
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
              label: Text(l10n.deleteProfileAction),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _groupSection(ThemeData theme, AppLocalizations l10n) {
    final groups = widget.controller.profileGroups;
    final selected = groups.any((group) => group.id == _groupId)
        ? _groupId!
        : _ungroupedGroup;

    return SettingsSection(
      title: l10n.profileGroupSection,
      children: [
        Text(
          l10n.profileGroupLabel,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        DropdownButton<String>(
          key: const ValueKey('profile-group-dropdown'),
          value: selected,
          isExpanded: true,
          items: [
            DropdownMenuItem(
              value: _ungroupedGroup,
              child: Text(l10n.profileUngrouped),
            ),
            for (final group in groups)
              DropdownMenuItem(
                value: group.id,
                child: Text(
                  group.name.trim().isEmpty
                      ? l10n.profileUntitledGroup
                      : group.name,
                ),
              ),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _groupId = value == _ungroupedGroup ? null : value;
            });
          },
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('profile-group-new'),
            onPressed: _createGroupAndSelect,
            icon: const Icon(Icons.add, size: 18),
            label: Text(l10n.profileNewGroup),
          ),
        ),
      ],
    );
  }

  Widget _avatarRow(ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    final image = _avatarImage();

    // 没头像、或者头像读不出来，就用名字的第一个字。比一个通用的小人图标
    // 好认，不同档案一眼能分开。
    Widget letter() => Text(
      widget.profile.displayName.characters.first,
      style: theme.textTheme.headlineSmall?.copyWith(
        color: onAccentColor(Color(_accent)),
      ),
    );

    return Row(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Color(_accent),
          ),
          alignment: Alignment.center,
          clipBehavior: Clip.antiAlias,
          child: image == null
              ? letter()
              : Padding(
                  padding: const EdgeInsets.all(3),
                  child: Image(
                    image: image,
                    fit: BoxFit.contain,
                    // 文件被删了、拷坏了、或者干脆不是图片 —— 退回那个字，
                    // 别把设置页整块变成一个报错框。
                    errorBuilder: (_, _, _) => letter(),
                  ),
                ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: _pickAvatar,
                child: Text(
                  image == null ? l10n.chooseAvatar : l10n.changeAvatar,
                ),
              ),
              if (image != null)
                TextButton(
                  onPressed: _dropAvatar,
                  child: Text(l10n.removeAvatar),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _swatches(ThemeData theme) {
    final names = _colorNames(AppLocalizations.of(context));
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (var i = 0; i < _presetColors.length; i++)
          Semantics(
            label: names[i],
            selected: _presetColors[i] == _accent,
            child: InkWell(
              onTap: () => setState(() => _accent = _presetColors[i]),
              customBorder: const CircleBorder(),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(_presetColors[i]),
                  border: Border.all(
                    color: _presetColors[i] == _accent
                        ? theme.colorScheme.onSurface
                        : Colors.transparent,
                    width: 3,
                  ),
                ),
                child: _presetColors[i] == _accent
                    ? Icon(
                        Icons.check,
                        size: 18,
                        color: onAccentColor(Color(_presetColors[i])),
                      )
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}
