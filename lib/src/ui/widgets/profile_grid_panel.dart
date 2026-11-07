import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../config/profile.dart';
import '../../config/profile_group.dart';
import '../../conversation/conversation_controller.dart';
import '../../conversation/profile_status.dart';
import '../channel_settings_page.dart';
import 'group_name_dialog.dart';
import 'profile_grid_card.dart';

/// 同页展开的档案网格。
///
/// 它不是新页面/新路由：由 `HomePage` 的状态控制显示，关闭后回到对话。
/// 网格用 `SliverGrid` 懒构建，200 个档案也只创建视口里的卡片。
///
/// P3 加入：
/// - 手动分组：顶部 chip 做组间切换；网格按组 section；
/// - 搜索：跨所有组匹配，清空后恢复原来的组筛选；
/// - 组管理：组标题右侧菜单改名/上移/下移/删除。
///
/// **卡片主体的语义没有变**：主体只切 focus，右上角小开关只改 enabled。
class ProfileGridPanel extends StatefulWidget {
  const ProfileGridPanel({
    super.key,
    required this.controller,
    required this.avatarOf,
    required this.onClose,
  });

  final ConversationController controller;
  final ImageProvider? Function(Profile profile) avatarOf;
  final VoidCallback onClose;

  @override
  State<ProfileGridPanel> createState() => _ProfileGridPanelState();
}

/// 组筛选的两个哨兵值。组 id 是 `g_` 开头，不会和它们撞。
const String _allGroups = '__all__';
const String _ungrouped = '__ungrouped__';
const String _newGroup = '__new_group__';

enum _GroupAction { create, rename, moveUp, moveDown, delete }

class _Bucket {
  const _Bucket(this.group, this.statuses);

  /// null 表示"未分组"。
  final ProfileGroup? group;
  final List<ProfileStatus> statuses;
}

/// 网格里的两种拖拽载荷。
///
/// 组和档案都用字符串 id，不能靠裸 String 区分；用一个共同基类让
/// `DragTarget<_DragData>` 能在同一个落点上分派。
sealed class _DragData {
  const _DragData();
}

class _DragGroup extends _DragData {
  const _DragGroup(this.id);
  final String id;
}

class _DragProfile extends _DragData {
  const _DragProfile(this.id, this.groupId);
  final String id;
  final String? groupId;
}

class _ProfileGridPanelState extends State<ProfileGridPanel> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// `_allGroups` / `_ungrouped` / 某个 groupId。
  String _filter = _allGroups;
  String _query = '';

  /// 上次自动定位到哪个聚焦档案、在哪个筛选下。避免每次 fleetRevision
  /// 通知都把人拽回当前卡片。
  String? _lastFocusedScrollId;
  String? _lastFocusedScrollFilter;

  // 与 `_sections` 的布局常量保持一致，用来估算"聚焦卡片在第几屏"。
  static const double _groupHeaderHeight = 44;
  static const double _gridTop = 2;
  static const double _gridBottom = 12;
  static const double _gridSpacing = 10;
  static const double _cardAspect = 1.35;
  static const double _emptyGroupHeight = 32;

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  ConversationController get _controller => widget.controller;

  bool get _searching => _query.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _controller.fleetRevision,
      builder: (context, _, _) {
        final l10n = AppLocalizations.of(context);
        final statuses = _controller.profileStatuses;
        final groups = _controller.profileGroups;
        final filter = _effectiveFilter(groups);
        final buckets = _buckets(statuses, groups, filter);
        final open = _controller.openProfileCount;

        return Column(
          key: const ValueKey('profile-panel'),
          children: [
            _header(context, l10n, open, statuses.length),
            _searchField(context, l10n),
            _groupChips(context, l10n, statuses, groups, filter),
            if (open > _controller.maxOpenProfiles)
              _limitBanner(context, l10n, open, _controller.maxOpenProfiles),
            Expanded(
              // 无搜索时至少会有「未分组」section（即使为空也保留「＋」
              // 新建入口），所以这里只需要处理搜索无结果。
              child: buckets.isEmpty
                  ? _empty(context, l10n, _searching)
                  : _sections(context, buckets, filter),
            ),
            // 手机端屏幕高、单手拇指够不到左上角。给一个固定在底部的
            // 小横条，点一下就回消息流；桌面端不需要，继续用左上角关闭。
            if (_isMobile(context)) _backToMessagesBar(context, l10n),
          ],
        );
      },
    );
  }

  bool _isMobile(BuildContext context) {
    final platform = Theme.of(context).platform;
    return platform == TargetPlatform.android ||
        platform == TargetPlatform.iOS ||
        platform == TargetPlatform.fuchsia;
  }

  Widget _backToMessagesBar(BuildContext context, AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: SizedBox(
        height: 42,
        width: double.infinity,
        child: FilledButton.tonalIcon(
          key: const ValueKey('fleet-back-to-messages'),
          onPressed: widget.onClose,
          icon: const Icon(Icons.chat_bubble_outline, size: 18),
          label: Text(l10n.profileBackToMessages),
          style: FilledButton.styleFrom(
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
        ),
      ),
    );
  }

  Widget _header(
    BuildContext context,
    AppLocalizations l10n,
    int open,
    int total,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('fleet-close'),
            tooltip: l10n.profilePanelClose,
            onPressed: widget.onClose,
            icon: const Icon(Icons.close),
          ),
          Text(
            l10n.profilesTitle,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Text(
            l10n.profilesOpenCount(open, total),
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchField(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.search,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const ValueKey('profile-search'),
                controller: _search,
                onChanged: (value) => setState(() => _query = value),
                textAlignVertical: TextAlignVertical.center,
                style: theme.textTheme.bodyMedium,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: l10n.profileSearchHint,
                  hintStyle: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: l10n.clear,
                          icon: const Icon(Icons.clear, size: 18),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 34,
                            height: 34,
                          ),
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        ),
                  suffixIconConstraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupChips(
    BuildContext context,
    AppLocalizations l10n,
    List<ProfileStatus> statuses,
    List<ProfileGroup> groups,
    String filter,
  ) {
    final counts = <String?, int>{};
    for (final status in statuses) {
      final id = _groupIdOf(status.profile.id, groups);
      counts[id] = (counts[id] ?? 0) + 1;
    }

    final theme = Theme.of(context);

    Widget chip(String key, String label, String value, int? count) {
      final selected = filter == value;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          key: ValueKey('group-chip-$key'),
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label),
              if (count != null) ...[
                const SizedBox(width: 6),
                Container(
                  key: ValueKey('group-chip-count-$key'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$count',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: selected
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
          selected: selected,
          showCheckmark: false,
          // 搜索是跨组的：这期间组筛选不生效，但保留选择，清空后恢复。
          onSelected: _searching
              ? null
              : (_) => setState(() => _filter = value),
        ),
      );
    }

    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          chip(_allGroups, l10n.profileAllGroups, _allGroups, statuses.length),
          for (final group in groups)
            chip(
              group.id,
              _groupName(l10n, group),
              group.id,
              counts[group.id] ?? 0,
            ),
          chip(
            _ungrouped,
            l10n.profileUngrouped,
            _ungrouped,
            counts[null] ?? 0,
          ),
          ActionChip(
            key: const ValueKey('group-new'),
            avatar: const Icon(Icons.add, size: 16),
            label: Text(l10n.profileNewGroup),
            onPressed: () => _createGroup(context, l10n),
          ),
        ],
      ),
    );
  }

  Widget _sections(BuildContext context, List<_Bucket> buckets, String filter) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 840
            ? 4
            : constraints.maxWidth >= 560
            ? 3
            : 2;
        final slivers = <Widget>[];
        final l10n = AppLocalizations.of(context);
        final gridWidth = constraints.maxWidth - 32;
        final cardWidth = (gridWidth - _gridSpacing * (columns - 1)) / columns;
        final cardHeight = cardWidth / _cardAspect;

        // 打开网格 / 切换聚焦档案时，直接滚到当前那张卡。
        _scheduleFocusedScroll(buckets, columns, cardHeight);

        for (final bucket in buckets) {
          // 「＋」只属于未分组，且只在「全部 / 未分组」视图、非搜索时出现。
          // 它是 section 的最后一个网格单元，但不进入 `bucket.statuses`，
          // 因此不参与计数、搜索、拖拽和自动滚动估算。
          final showPlus =
              bucket.group == null &&
              !_searching &&
              (filter == _allGroups || filter == _ungrouped);

          slivers.add(
            SliverToBoxAdapter(child: _groupHeader(context, l10n, bucket)),
          );
          if (bucket.statuses.isEmpty && !showPlus) {
            slivers.add(
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Text(
                    l10n.profileGroupEmpty,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            );
            continue;
          }

          final childCount = bucket.statuses.length + (showPlus ? 1 : 0);
          slivers.add(
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, _gridTop, 16, _gridBottom),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: _gridSpacing,
                  crossAxisSpacing: _gridSpacing,
                  childAspectRatio: _cardAspect,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  if (index < bucket.statuses.length) {
                    return _card(context, bucket, bucket.statuses[index]);
                  }
                  return ProfileGridNewCard(
                    onTap: () => _createChannel(groupId: bucket.group?.id),
                  );
                }, childCount: childCount),
              ),
            ),
          );
        }

        slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 24)));
        return CustomScrollView(controller: _scroll, slivers: slivers);
      },
    );
  }

  Widget _groupHeader(
    BuildContext context,
    AppLocalizations l10n,
    _Bucket bucket,
  ) {
    final theme = Theme.of(context);
    final group = bucket.group;
    final groups = _controller.profileGroups;
    final index = group == null
        ? -1
        : groups.indexWhere((item) => item.id == group.id);

    final header = SizedBox(
      key: ValueKey(
        group == null ? 'group-header-$_ungrouped' : 'group-header-${group.id}',
      ),
      height: _groupHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
        child: Row(
          children: [
            if (group != null)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Semantics(
                  label: l10n.profileGroupDragHint,
                  child: Icon(
                    Icons.drag_indicator,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.6,
                    ),
                  ),
                ),
              ),
            Text(
              group == null ? l10n.profileUngrouped : _groupName(l10n, group),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              key: ValueKey(
                group == null
                    ? 'group-header-count-$_ungrouped'
                    : 'group-header-count-${group.id}',
              ),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '${bucket.statuses.length}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Spacer(),
            if (group != null && !_searching)
              PopupMenuButton<_GroupAction>(
                key: ValueKey('group-menu-${group.id}'),
                tooltip: l10n.profileGroupMenuTooltip,
                padding: EdgeInsets.zero,
                onSelected: (action) =>
                    _onGroupAction(context, l10n, group, index, action),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    key: const ValueKey('group-menu-create'),
                    value: _GroupAction.create,
                    child: Text(l10n.profileNewChannel),
                  ),
                  PopupMenuItem(
                    key: const ValueKey('group-menu-rename'),
                    value: _GroupAction.rename,
                    child: Text(l10n.profileGroupRename),
                  ),
                  PopupMenuItem(
                    key: const ValueKey('group-menu-move-up'),
                    value: _GroupAction.moveUp,
                    enabled: index > 0,
                    child: Text(l10n.profileGroupMoveUp),
                  ),
                  PopupMenuItem(
                    key: const ValueKey('group-menu-move-down'),
                    value: _GroupAction.moveDown,
                    enabled: index >= 0 && index < groups.length - 1,
                    child: Text(l10n.profileGroupMoveDown),
                  ),
                  PopupMenuItem(
                    key: const ValueKey('group-menu-delete'),
                    value: _GroupAction.delete,
                    child: Text(l10n.profileGroupDelete),
                  ),
                ],
                child: const SizedBox(
                  width: 36,
                  height: 36,
                  child: Icon(Icons.more_horiz, size: 20),
                ),
              ),
          ],
        ),
      ),
    );

    // 组标题既能拖（调整组顺序），也能接（档案拖进来换组）。
    // 未分组那个不能拖，但可以接档案。
    final draggable = group == null
        ? header
        : LongPressDraggable<_DragData>(
            data: _DragGroup(group.id),
            hitTestBehavior: HitTestBehavior.opaque,
            feedback: _DragFeedback(
              icon: Icons.folder_outlined,
              label: _groupName(l10n, group),
            ),
            childWhenDragging: Opacity(opacity: 0.35, child: header),
            child: header,
          );

    return DragTarget<_DragData>(
      onWillAcceptWithDetails: (details) {
        final data = details.data;
        if (data is _DragGroup) return data.id != group?.id;
        if (data is _DragProfile) return data.groupId != group?.id;
        return false;
      },
      onAcceptWithDetails: (details) =>
          _dropOnGroup(context, l10n, bucket, details.data),
      builder: (context, candidates, rejected) {
        return ColoredBox(
          color: candidates.isEmpty
              ? Colors.transparent
              : theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
          child: draggable,
        );
      },
    );
  }

  Future<void> _dropOnGroup(
    BuildContext context,
    AppLocalizations l10n,
    _Bucket bucket,
    _DragData data,
  ) async {
    if (data is _DragGroup) {
      final target = bucket.group;
      if (target == null) return;
      final index = _controller.profileGroups.indexWhere(
        (group) => group.id == target.id,
      );
      if (index >= 0) await _controller.moveGroup(data.id, index);
      return;
    }
    if (data is! _DragProfile) return;

    final targetGroupId = bucket.group?.id;
    if (data.groupId == targetGroupId) return;
    final ok = await _controller.moveProfileToGroup(data.id, targetGroupId);
    if (!context.mounted) return;
    final name = _profileName(data.id);
    final groupLabel = bucket.group == null
        ? l10n.profileUngrouped
        : _groupName(l10n, bucket.group!);
    _toast(
      context,
      ok
          ? l10n.profileMovedToGroup(name, groupLabel)
          : l10n.profileMoveToGroupFailed(name),
    );
  }

  Widget _empty(BuildContext context, AppLocalizations l10n, bool searching) {
    return Center(
      child: Text(
        searching ? l10n.profileSearchEmpty : l10n.noEnabledProfiles,
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _limitBanner(
    BuildContext context,
    AppLocalizations l10n,
    int open,
    int max,
  ) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.profileOverLimit(open, max),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, _Bucket bucket, ProfileStatus status) {
    final groupId = bucket.group?.id;
    final card = ProfileGridCard(
      key: ValueKey('profile-card-visual-${status.profile.id}'),
      status: status,
      avatar: widget.avatarOf(status.profile),
      onFocus: () => _focus(status),
      onToggle: () => _toggle(status),
      onEdit: () => _edit(status),
      onMoveGroup: () => _moveToGroup(status),
    );

    // 长按卡片主体可以拖到同组另一张卡上重排，拖到别的组标题/卡片上换组。
    // 右上角开关、右下角菜单是卡片里的独立层，点按仍然各做各的。
    return Semantics(
      hint: AppLocalizations.of(context).profileDragHint,
      child: DragTarget<_DragData>(
        onWillAcceptWithDetails: (details) {
          final data = details.data;
          return data is _DragProfile && data.id != status.profile.id;
        },
        onAcceptWithDetails: (details) {
          final data = details.data;
          if (data is! _DragProfile) return;
          _dropOnCard(context, bucket, status, data);
        },
        builder: (context, candidates, rejected) {
          return LongPressDraggable<_DragData>(
            data: _DragProfile(status.profile.id, groupId),
            hitTestBehavior: HitTestBehavior.opaque,
            feedback: _DragFeedback(
              icon: Icons.person_outline,
              label: status.profile.displayName,
            ),
            childWhenDragging: Opacity(opacity: 0.35, child: card),
            child: card,
          );
        },
      ),
    );
  }

  Future<void> _dropOnCard(
    BuildContext context,
    _Bucket bucket,
    ProfileStatus target,
    _DragProfile data,
  ) async {
    final targetGroupId = bucket.group?.id;
    final changedGroup = data.groupId != targetGroupId;
    final ok = await _controller.moveProfileToGroup(
      data.id,
      targetGroupId,
      targetProfileId: target.profile.id,
    );
    if (!context.mounted || !changedGroup) return;
    final l10n = AppLocalizations.of(context);
    final name = _profileName(data.id);
    final groupLabel = bucket.group == null
        ? l10n.profileUngrouped
        : _groupName(l10n, bucket.group!);
    _toast(
      context,
      ok
          ? l10n.profileMovedToGroup(name, groupLabel)
          : l10n.profileMoveToGroupFailed(name),
    );
  }

  String _profileName(String id) {
    final index = _controller.config.profiles.indexWhere((p) => p.id == id);
    return index < 0 ? id : _controller.config.profiles[index].displayName;
  }

  /// 卡片菜单的「编辑频道」：直接打开这个频道的设置页。
  Future<void> _edit(ProfileStatus status) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChannelSettingsPage.edit(
          controller: _controller,
          profileId: status.profile.id,
        ),
      ),
    );
  }

  /// 新建频道。只打开草稿页，真正创建发生在用户点保存时。
  Future<void> _createChannel({String? groupId}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChannelSettingsPage.create(
          controller: _controller,
          groupId: groupId,
        ),
      ),
    );
  }

  /// 卡片菜单的「移动到分组」。新建分组的流程也在这里，不另开页面。
  Future<void> _moveToGroup(ProfileStatus status) async {
    final l10n = AppLocalizations.of(context);
    final groups = _controller.profileGroups;
    final current = _controller.groupIdOf(status.profile.id);
    final theme = Theme.of(context);

    Widget option(String label, bool selected) {
      return Row(
        children: [
          SizedBox(
            width: 24,
            child: selected
                ? Icon(Icons.check, size: 18, color: theme.colorScheme.primary)
                : null,
          ),
          const SizedBox(width: 6),
          Expanded(child: Text(label)),
        ],
      );
    }

    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(l10n.profileMoveToGroupTitle),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(_ungrouped),
            child: option(l10n.profileUngrouped, current == null),
          ),
          for (final group in groups)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(group.id),
              child: option(_groupName(l10n, group), current == group.id),
            ),
          const Divider(height: 8),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(_newGroup),
            child: Row(
              children: [
                const SizedBox(width: 24, child: Icon(Icons.add, size: 18)),
                const SizedBox(width: 6),
                Text(l10n.profileMoveToGroupNew),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected == null || !mounted) return;

    String? groupId;
    String groupLabel;
    if (selected == _ungrouped) {
      if (current == null) return;
      groupId = null;
      groupLabel = l10n.profileUngrouped;
    } else if (selected == _newGroup) {
      final name = await showGroupNameDialog(
        context,
        title: l10n.profileNewGroup,
        confirmLabel: l10n.profileGroupCreate,
      );
      if (name == null || !mounted) return;
      final group = await _controller.createGroup(name);
      groupId = group.id;
      groupLabel = name;
    } else {
      if (selected == current) return;
      final group = groups.firstWhere((item) => item.id == selected);
      groupId = group.id;
      groupLabel = _groupName(l10n, group);
    }

    final ok = await _controller.moveProfileToGroup(status.profile.id, groupId);
    if (!mounted) return;
    final name = status.profile.displayName;
    _toast(
      context,
      ok
          ? l10n.profileMovedToGroup(name, groupLabel)
          : l10n.profileMoveToGroupFailed(name),
    );
  }

  /// 卡片主体：只切焦点。关闭的档案不能聚焦，给一条提示，不偷偷打开。
  Future<void> _focus(ProfileStatus status) async {
    final l10n = AppLocalizations.of(context);
    if (!status.enabled) {
      _toast(context, l10n.profileClosedTapHint(status.profile.displayName));
      return;
    }
    if (status.focused) return;
    await _controller.switchProfile(status.profile.id);
  }

  /// 小开关：只改 enabled，不碰焦点。
  Future<void> _toggle(ProfileStatus status) async {
    final l10n = AppLocalizations.of(context);
    final name = status.profile.displayName;
    final wasFocused = status.focused;
    final result = await _controller.setProfileEnabled(
      status.profile.id,
      !status.enabled,
    );
    if (!mounted) return;

    switch (result) {
      case SetProfileEnabledResult.opened:
        _toast(
          context,
          _controller.sessionActive
              ? l10n.profileOpenedActive(name)
              : l10n.profileOpenedIdle(name),
        );
        break;
      case SetProfileEnabledResult.closed:
        final next = _controller.config.focusedProfile;
        if (wasFocused && next != null && next.id != status.profile.id) {
          _toast(context, l10n.profileClosedSwitched(name, next.displayName));
        } else {
          _toast(context, l10n.profileClosedNotice(name));
        }
        break;
      case SetProfileEnabledResult.atCapacity:
        _toast(context, l10n.profileAtCapacity(_controller.maxOpenProfiles));
        break;
      case SetProfileEnabledResult.notFound:
        _toast(
          context,
          status.enabled
              ? l10n.profileCloseFailed(name)
              : l10n.profileOpenFailed(name),
        );
        break;
      case SetProfileEnabledResult.alreadyOpen:
      case SetProfileEnabledResult.alreadyClosed:
        break;
    }
  }

  Future<void> _createGroup(BuildContext context, AppLocalizations l10n) async {
    final name = await showGroupNameDialog(
      context,
      title: l10n.profileNewGroup,
      confirmLabel: l10n.profileGroupCreate,
    );
    if (name == null || !context.mounted) return;
    final group = await _controller.createGroup(name);
    if (!context.mounted) return;
    _search.clear();
    setState(() {
      _query = '';
      _filter = group.id;
    });
    _toast(context, l10n.profileGroupCreated(name));
  }

  Future<void> _renameGroup(
    BuildContext context,
    AppLocalizations l10n,
    ProfileGroup group,
  ) async {
    final name = await showGroupNameDialog(
      context,
      title: l10n.profileGroupRename,
      confirmLabel: l10n.save,
      initialValue: group.name,
    );
    if (name == null || name == group.name || !context.mounted) return;
    await _controller.renameGroup(group.id, name);
    if (!context.mounted) return;
    _toast(context, l10n.profileGroupRenamed(name));
  }

  Future<void> _deleteGroup(
    BuildContext context,
    AppLocalizations l10n,
    ProfileGroup group,
  ) async {
    await _controller.removeGroup(group.id);
    if (!context.mounted) return;
    setState(() {
      if (_filter == group.id) _filter = _allGroups;
    });
    _toast(context, l10n.profileGroupDeleted(_groupName(l10n, group)));
  }

  Future<void> _onGroupAction(
    BuildContext context,
    AppLocalizations l10n,
    ProfileGroup group,
    int index,
    _GroupAction action,
  ) async {
    switch (action) {
      case _GroupAction.create:
        await _createChannel(groupId: group.id);
        break;
      case _GroupAction.rename:
        await _renameGroup(context, l10n, group);
        break;
      case _GroupAction.moveUp:
        if (index > 0) await _controller.moveGroup(group.id, index - 1);
        break;
      case _GroupAction.moveDown:
        final last = _controller.profileGroups.length - 1;
        if (index >= 0 && index < last) {
          await _controller.moveGroup(group.id, index + 1);
        }
        break;
      case _GroupAction.delete:
        await _deleteGroup(context, l10n, group);
        break;
    }
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 展开面板 / 切换聚焦档案后，把当前卡片滚进视口。
  ///
  /// 网格是懒构建的：200 个档案时聚焦卡片很可能还没建出来，所以不能只靠
  /// `ensureVisible`。这里按"组标题 + 每个 section 的行数 × 卡片高度"估算
  /// 滚动偏移，`ScrollController` 不需要卡片已经存在。
  void _scheduleFocusedScroll(
    List<_Bucket> buckets,
    int columns,
    double cardHeight,
  ) {
    if (_searching) return;
    final focusedId = _controller.config.focusedProfileId;
    if (focusedId == _lastFocusedScrollId &&
        _filter == _lastFocusedScrollFilter) {
      return;
    }
    _lastFocusedScrollId = focusedId;
    _lastFocusedScrollFilter = _filter;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final offset = _offsetForFocused(buckets, columns, cardHeight, focusedId);
      if (offset == null) return;
      final max = _scroll.position.maxScrollExtent;
      _scroll.animateTo(
        offset.clamp(0.0, max),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  double? _offsetForFocused(
    List<_Bucket> buckets,
    int columns,
    double cardHeight,
    String focusedId,
  ) {
    var offset = 0.0;
    for (final bucket in buckets) {
      final index = bucket.statuses.indexWhere(
        (status) => status.focused && status.profile.id == focusedId,
      );
      if (index >= 0) {
        final row = index ~/ columns;
        return offset +
            _groupHeaderHeight +
            _gridTop +
            row * (cardHeight + _gridSpacing);
      }

      offset += _groupHeaderHeight;
      if (bucket.statuses.isEmpty) {
        offset += _emptyGroupHeight;
        continue;
      }
      final rows = (bucket.statuses.length + columns - 1) ~/ columns;
      offset +=
          _gridTop +
          rows * cardHeight +
          (rows - 1) * _gridSpacing +
          _gridBottom;
    }
    return null;
  }

  String _effectiveFilter(List<ProfileGroup> groups) {
    if (_filter == _allGroups || _filter == _ungrouped) return _filter;
    return groups.any((group) => group.id == _filter) ? _filter : _allGroups;
  }

  String? _groupIdOf(String profileId, List<ProfileGroup> groups) {
    final id = _controller.groupIdOf(profileId);
    if (id == null) return null;
    return groups.any((group) => group.id == id) ? id : null;
  }

  bool _matches(ProfileStatus status, String query) {
    final profile = status.profile;
    final haystack = [
      profile.displayName,
      profile.name,
      profile.brain.brainId,
      profile.brain.baseUrl,
    ].join(' ').toLowerCase();
    return haystack.contains(query);
  }

  List<_Bucket> _buckets(
    List<ProfileStatus> statuses,
    List<ProfileGroup> groups,
    String filter,
  ) {
    final byGroup = <String?, List<ProfileStatus>>{};
    for (final status in statuses) {
      final id = _groupIdOf(status.profile.id, groups);
      byGroup.putIfAbsent(id, () => []).add(status);
    }

    final query = _query.trim().toLowerCase();
    if (query.isNotEmpty) {
      final buckets = <_Bucket>[];
      for (final group in groups) {
        final all = byGroup[group.id] ?? const <ProfileStatus>[];
        final groupNameMatches = _groupName(
          AppLocalizations.of(context),
          group,
        ).toLowerCase().contains(query);
        final matched = groupNameMatches
            ? all
            : all.where((status) => _matches(status, query)).toList();
        if (matched.isNotEmpty) buckets.add(_Bucket(group, matched));
      }
      final ungrouped = (byGroup[null] ?? const <ProfileStatus>[])
          .where((status) => _matches(status, query))
          .toList();
      if (ungrouped.isNotEmpty) buckets.add(_Bucket(null, ungrouped));
      return buckets;
    }

    if (filter == _ungrouped) {
      return [_Bucket(null, byGroup[null] ?? const <ProfileStatus>[])];
    }
    if (filter != _allGroups) {
      final group = groups.firstWhere(
        (item) => item.id == filter,
        orElse: () => groups.first,
      );
      return [_Bucket(group, byGroup[group.id] ?? const <ProfileStatus>[])];
    }

    final buckets = <_Bucket>[];
    for (final group in groups) {
      final list = byGroup[group.id] ?? const <ProfileStatus>[];
      if (list.isNotEmpty) buckets.add(_Bucket(group, list));
    }
    // 「未分组」是系统收件箱，也是固定的新建入口：即使为空也要保留 section，
    // 这样「＋」卡片在「全部」视图里始终可见。
    final ungrouped = byGroup[null] ?? const <ProfileStatus>[];
    buckets.add(_Bucket(null, ungrouped));
    return buckets;
  }

  String _groupName(AppLocalizations l10n, ProfileGroup group) {
    final name = group.name.trim();
    return name.isEmpty ? l10n.profileUntitledGroup : name;
  }
}

/// 拖动时跟着手指的小标签。组和卡片共用一个形状，只是图标/文字不同。
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
