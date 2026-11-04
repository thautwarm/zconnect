import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../conversation/profile_status.dart';
import 'profile_status_label.dart';
import 'settings_widgets.dart';

enum _CardAction { edit, moveGroup }

/// 舰队网格里的一张档案卡片。
///
/// **三个动作必须分开：**
/// - 卡片主体（[onFocus]）只切换焦点；
/// - 右上角的小开关（[onToggle]）只改 `enabled`（打开/关闭后台收消息）；
/// - 右下角的「更多」菜单（[onEdit] / [onMoveGroup]）只做档案管理。
///
/// 小开关和菜单都是 `Stack` 的独立一层，不在主体 InkWell 里面，所以点它们
/// 不会顺带触发切换。视觉上做小，但触控目标保持 40×40 / 32×32。
class ProfileGridCard extends StatelessWidget {
  const ProfileGridCard({
    super.key,
    required this.status,
    required this.avatar,
    required this.onFocus,
    required this.onToggle,
    required this.onEdit,
    required this.onMoveGroup,
  });

  final ProfileStatus status;
  final ImageProvider? avatar;

  /// 点卡片主体：已打开 → 切过去；已关闭 → 只提示，不切换。
  final VoidCallback onFocus;

  /// 点右上角小开关：打开/关闭，不涉及焦点。
  final VoidCallback onToggle;

  /// 打开已有设置页，直接定位到这个档案。
  final VoidCallback onEdit;

  /// 弹出分组选择器，只改 membership。
  final VoidCallback onMoveGroup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final profile = status.profile;
    final accent = Color(profile.accentColor);
    final closed = !status.enabled;
    final stateText = profileStatusLabel(context, status);
    final stateColor = profileStatusColor(context, status);
    final firstLetter = profile.displayName.characters.first;

    final body = Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 48, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: accent.withValues(alpha: 0.2),
                foregroundImage: avatar,
                // 图丢了也要露出首字，不能只剩一个空圆。
                child: Text(
                  firstLetter,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      profile.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: closed
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    if (profile.name.trim().isNotEmpty &&
                        profile.brain.brainId.trim().isNotEmpty)
                      Text(
                        profile.brain.brainId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const Spacer(),
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: stateColor,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  stateText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: stateColor,
                  ),
                ),
              ),
              if (status.focused)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    l10n.profileCurrent,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: onAccentColor(accent),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );

    return Material(
      color: status.focused
          ? accent.withValues(alpha: 0.08)
          : theme.colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: status.focused ? accent : theme.colorScheme.outlineVariant,
          width: status.focused ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              button: true,
              selected: status.focused,
              label: '${profile.displayName}，$stateText',
              child: InkWell(
                key: ValueKey('profile-card-${profile.id}'),
                onTap: onFocus,
                child: closed ? Opacity(opacity: 0.55, child: body) : body,
              ),
            ),
          ),
          Positioned(
            top: 6,
            right: 6,
            child: _PowerToggle(
              key: ValueKey('profile-power-${profile.id}'),
              enabled: status.enabled,
              accent: accent,
              name: profile.displayName,
              onPressed: onToggle,
            ),
          ),
          Positioned(
            right: 6,
            bottom: 6,
            child: _CardMenu(
              key: ValueKey('profile-menu-${profile.id}'),
              onEdit: onEdit,
              onMoveGroup: onMoveGroup,
            ),
          ),
        ],
      ),
    );
  }
}

/// 卡片右下角的档案操作菜单。
///
/// 单独一层，和右上角的开关一样不落在主体 InkWell 里：点「更多」不会
/// 顺带切焦点，也不会碰 enabled。
class _CardMenu extends StatelessWidget {
  const _CardMenu({
    super.key,
    required this.onEdit,
    required this.onMoveGroup,
  });

  final VoidCallback onEdit;
  final VoidCallback onMoveGroup;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopupMenuButton<_CardAction>(
      tooltip: l10n.profileCardActions,
      padding: EdgeInsets.zero,
      onSelected: (action) {
        switch (action) {
          case _CardAction.edit:
            onEdit();
            break;
          case _CardAction.moveGroup:
            onMoveGroup();
            break;
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _CardAction.edit,
          child: Text(l10n.profileCardEdit),
        ),
        PopupMenuItem(
          value: _CardAction.moveGroup,
          child: Text(l10n.profileCardMoveGroup),
        ),
      ],
      child: const SizedBox(
        width: 32,
        height: 32,
        child: Icon(Icons.more_horiz, size: 18),
      ),
    );
  }
}

/// 卡片右上角那个独立的小开关。
///
/// 只做一件事：打开/关闭。**不切换焦点**。放在卡片的 Stack 顶层而不是
/// 主体 InkWell 的 child 里，避免手势落到底下的切换动作上。
class _PowerToggle extends StatelessWidget {
  const _PowerToggle({
    super.key,
    required this.enabled,
    required this.accent,
    required this.name,
    required this.onPressed,
  });

  final bool enabled;
  final Color accent;
  final String name;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final label = enabled
        ? l10n.profileCloseAction(name)
        : l10n.profileOpenAction(name);

    return Semantics(
      button: true,
      toggled: enabled,
      label: label,
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        icon: const Icon(Icons.power_settings_new_rounded),
        iconSize: 18,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        style: IconButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: enabled
              ? accent.withValues(alpha: 0.16)
              : theme.colorScheme.surfaceContainerHighest,
          foregroundColor: enabled
              ? accent
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
