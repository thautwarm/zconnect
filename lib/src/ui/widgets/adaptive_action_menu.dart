import 'package:flutter/material.dart';

/// 一个可选的菜单项。
///
/// 桌面端渲染成 [PopupMenuItem]，手机端渲染成底部浮层里的 [ListTile]。
class AdaptiveActionItem<T> {
  const AdaptiveActionItem({
    required this.value,
    required this.label,
    this.icon,
    this.enabled = true,
    this.key,
  });

  final T value;
  final String label;
  final IconData? icon;
  final bool enabled;
  final Key? key;
}

/// 自适应操作菜单：桌面端用下拉菜单，手机端用固定底部浮层。
///
/// 手机端浮层盖住整页，所有菜单都出现在同一个位置；[showModalBottomSheet]
/// 自己处理背景压暗和点击外部关闭，所以同一时间只会有一个浮层。
class AdaptiveActionMenu<T> extends StatelessWidget {
  const AdaptiveActionMenu({
    super.key,
    required this.tooltip,
    required this.items,
    required this.onSelected,
    this.child,
    this.iconSize = 18,
    this.width = 32,
    this.height = 32,
  });

  final String tooltip;
  final List<AdaptiveActionItem<T>> items;
  final ValueChanged<T> onSelected;
  final Widget? child;
  final double iconSize;
  final double width;
  final double height;

  /// 低于这个宽度按手机端处理。桌面窗口拖窄时也走底部浮层。
  static const double mobileBreakpoint = 600;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < mobileBreakpoint) {
      return IconButton(
        tooltip: tooltip,
        onPressed: () => _showSheet(context),
        icon: Icon(Icons.more_horiz, size: iconSize),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: BoxConstraints.tightFor(width: width, height: height),
      );
    }

    return PopupMenuButton<T>(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final item in items)
          PopupMenuItem(
            key: item.key,
            value: item.value,
            enabled: item.enabled,
            child: Text(item.label),
          ),
      ],
      child:
          child ??
          SizedBox(
            width: width,
            height: height,
            child: Icon(Icons.more_horiz, size: iconSize),
          ),
    );
  }

  Future<void> _showSheet(BuildContext context) async {
    final theme = Theme.of(context);

    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: theme.colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
              child: Text(
                tooltip,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final item in items)
              ListTile(
                key: item.key,
                enabled: item.enabled,
                leading: item.icon == null ? null : Icon(item.icon),
                title: Text(item.label),
                onTap: item.enabled
                    ? () {
                        Navigator.of(sheetContext).pop();
                        onSelected(item.value);
                      }
                    : null,
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
