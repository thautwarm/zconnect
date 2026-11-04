import '../config/profile.dart';

/// 一个档案在"档案网格"里的运行态快照。
///
/// 这是**只读的推导结果**，不落盘、不缓存：`ConversationController` 每次
/// 按当前配置和各档案的 `ProfileRuntime` 现算。界面拿它渲染卡片状态，
/// 避免自己把「聚焦 / 打开 / 正在轮询 / 出错」几个概念混在一起。
class ProfileStatus {
  const ProfileStatus({
    required this.profile,
    required this.focused,
    required this.enabled,
    required this.sessionActive,
    required this.polling,
    required this.authFailed,
    required this.error,
  });

  final Profile profile;

  /// 当前聚焦。**关闭的档案不算聚焦**，和 [Profile.stateIn] 的优先级一致。
  final bool focused;

  /// 用户在卡片上打开/关闭的那个开关，也就是 `Profile.enabled`。
  final bool enabled;

  /// 对话会话是否已经开始。没开始时，打开的档案也不会轮询。
  final bool sessionActive;

  /// 这个档案的轮询循环是否活着。
  final bool polling;

  /// 轮询碰到 401/403，已停止。
  final bool authFailed;

  /// 最近一次失败原因。成功一次会清掉。
  final String? error;

  /// brain 地址/名字填全了没有。没填时打开也不会轮询。
  bool get brainUsable => profile.brain.isUsable;

  /// 真正在后台收消息：用户打开、brain 可用、会话已开始、轮询活着。
  ///
  /// 界面不要只拿 [enabled] 当"监听中" —— 那会把"已打开但还没开始对话"
  /// 和"打开了但 brain 没配"都显示成正在工作。
  bool get listening =>
      enabled && brainUsable && sessionActive && polling && !authFailed;
}
