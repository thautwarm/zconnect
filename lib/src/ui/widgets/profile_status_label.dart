import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../conversation/profile_status.dart';

/// 档案卡片/折叠栏上那一行状态文案。
///
/// 状态优先级是固定的：**关着 > 没配置 > 鉴权失败 > 连接失败 > 正在收 >
/// 已打开但没开始 > 已打开正在连**。不能把"已打开"直接当"监听中"——
/// 用户会话没开始时，打开的档案并不会轮询。
String profileStatusLabel(BuildContext context, ProfileStatus status) {
  final l10n = AppLocalizations.of(context);
  if (!status.enabled) return l10n.profileStatusClosed;
  if (!status.brainUsable) return l10n.profileStatusUnconfigured;
  if (status.authFailed) return l10n.profileStatusAuthFailed;
  if (status.error != null) return l10n.profileStatusError;
  if (status.sessionActive && status.polling) {
    return l10n.profileStatusListening;
  }
  if (!status.sessionActive) return l10n.profileStatusOpenIdle;
  return l10n.profileStatusConnecting;
}

/// 状态点的颜色。文字才是主要信息，颜色只做辅助。
Color profileStatusColor(BuildContext context, ProfileStatus status) {
  final scheme = Theme.of(context).colorScheme;
  if (!status.enabled) return scheme.onSurfaceVariant;
  if (!status.brainUsable) return scheme.tertiary;
  if (status.authFailed || status.error != null) return scheme.error;
  if (status.sessionActive && status.polling) return scheme.primary;
  return scheme.tertiary;
}
