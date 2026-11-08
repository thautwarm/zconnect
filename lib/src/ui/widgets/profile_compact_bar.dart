import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../config/profile.dart';
import '../../conversation/conversation_controller.dart';
import '../../conversation/profile_status.dart';
import 'profile_status_label.dart';

/// 折叠态顶部的那一条：当前聚焦档案 + 打开计数 + 展开网格入口。
///
/// 它自己订阅 [ConversationController.fleetRevision]，不跟着 500ms 电平和
/// 后台消息重建。展开动作只有一个按钮，不需要滑动/拖动/长按。
class ProfileCompactBar extends StatelessWidget {
  const ProfileCompactBar({
    super.key,
    required this.controller,
    required this.avatarOf,
    required this.onOpen,
    required this.onEditFocused,
  });

  final ConversationController controller;
  final ImageProvider? Function(Profile profile) avatarOf;
  final VoidCallback onOpen;

  /// 打开当前聚焦频道的设置页。没有聚焦频道时不会渲染这个入口。
  final VoidCallback onEditFocused;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: controller.fleetRevision,
      builder: (context, _, _) {
        final theme = Theme.of(context);
        final l10n = AppLocalizations.of(context);
        final statuses = controller.profileStatuses;
        ProfileStatus? focused;
        for (final status in statuses) {
          if (status.focused) {
            focused = status;
            break;
          }
        }

        final openCount = controller.openProfileCount;
        final name = focused?.profile.displayName;

        return SizedBox(
          height: 48,
          child: Row(
            children: [
              if (focused == null)
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.person_off_outlined,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        l10n.noEnabledProfiles,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor: Color(focused.profile.accentColor)
                        .withValues(alpha: 0.2),
                    foregroundImage: avatarOf(focused.profile),
                    child: Text(
                      focused.profile.displayName.characters.first,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: Color(focused.profile.accentColor),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        profileStatusLabel(context, focused),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: profileStatusColor(context, focused),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (focused == null) const Spacer(),
              if (focused != null)
                IconButton(
                  key: const ValueKey('focused-channel-settings'),
                  tooltip: l10n.channelSettingsTitle,
                  // 用铅笔而不是齿轮类图标：齿轮已经是全局设置，tune 是调试面板。
                  // 这里编辑的是「当前这个频道」，和它们必须一眼分得开。
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  visualDensity: VisualDensity.compact,
                  onPressed: onEditFocused,
                ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: TextButton.icon(
                  key: const ValueKey('fleet-open'),
                  onPressed: onOpen,
                  icon: const Icon(Icons.grid_view_rounded, size: 18),
                  label: Text(
                    l10n.profilesOpenCount(openCount, statuses.length),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
