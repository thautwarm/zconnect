import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../config/profile.dart';
import '../conversation/conversation_controller.dart';
import '../conversation/message.dart';
import 'channel_settings_page.dart';
import 'debug_page.dart';
import 'settings_page.dart';
import 'widgets/message_markdown.dart';
import 'widgets/profile_compact_bar.dart';
import 'widgets/profile_grid_panel.dart';
import 'widgets/voice_orb.dart';

/// 主界面。
///
/// 结构：**顶部一个按钮 + 下面是消息流**。
/// 按钮放在上面而不是常见的底部，是因为消息流要占满剩下的空间、
/// 并且从下往上生长 —— 按钮压在上面既不会挡到最新消息，
/// 也始终在拇指够得着的地方。
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});

  final ConversationController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _scroll = ScrollController();

  /// 上一次见到的 [ConversationController.lastSeq]。判断"是不是来了新消息"。
  ///
  /// **不能用消息条数代替。** 内存窗口满了之后条数就不再增长（自动滚动会
  /// 静默失效）；反过来，往上翻历史会让条数变大，被误判成新消息，把正在
  /// 看历史的用户拽回底部。seq 是单调的，两个毛病都没有。
  int _seenLastSeq = 0;

  /// 上一次聚焦的档案。换了档案就把 [_seenLastSeq] 归零并滚到底 ——
  /// 换的是另一屏历史，和上一个档案的 seq 没有可比性。
  String? _lastFocusedId;

  /// 上一次见到的历史读盘版本。切换频道时 `historyLoaded` 可能还是上一次
  /// 的 true；re-load 完成后这个版本会变，据此再要求一次“回到底部”。
  int _lastHistoryRevision = -1;

  /// 切了频道、还没把消息流校正到新频道底部。
  ///
  /// 新频道的历史是**异步**读进来的：切过去的那一帧可能还是空列表，
  /// 这时 `_scroll` 根本没有 viewport。所以不能只在切换的那一帧跳一次，
  /// 而要一直记着这件事，等历史落地后的下一次 build 再校正。
  bool _pendingBottomCorrection = false;

  /// 校正过程中上一帧看到的最大滚动范围。
  ///
  /// 只跳一次是不够的：切过去的那一帧列表可能还没排完，`maxScrollExtent`
  /// 还是 0 或旧值；跳完就清标记会停在顶部。这里等最大值连续一帧不变
  /// 再收工。
  double? _bottomCorrectionMaxExtent;
  int _bottomCorrectionStableFrames = 0;
  bool _bottomCorrectionScheduled = false;

  /// 打开频道网格时的滚动位置，以及那时聚焦的频道。
  ///
  /// 网格会替换掉消息流（ListView 被销毁），关闭时如果频道没变，要把
  /// 原来的位置放回去；频道变了则由 [_pendingBottomCorrection] 负责到底。
  double? _fleetAnchorOffset;
  String? _fleetAnchorFocusId;

  /// 正在往前面插更早的历史。这期间**绝对不能**自动滚到底，
  /// 否则"用户正在往上翻，后台档案来了条消息"就会把人弹回去。
  bool _loadingEarlier = false;

  /// 用户翻得离底部够远了，要不要显示"回到底部"按钮。
  ///
  /// 只在 [ScrollController] 的监听里更新，而且**只在真假变化时**
  /// setState：滚动每帧都会回调，无脑 setState 会让整页跟着滚。
  bool _showJumpToBottom = false;

  /// 离顶部多近就去加载更早的。
  static const double _loadEarlierThreshold = 200;

  /// 判定"用户贴着底部"的容差（逻辑像素）。
  static const double _stickToBottomThreshold = 120;

  /// 头像的 [ImageProvider] 缓存。
  ///
  /// 这个页面每 500ms 就因为电平刷新重建一次，每次 build 都现造
  /// `FileImage` 的话会一直new 对象。按路径缓存，换头像时路径会变
  /// （文件名带时间戳），自然就换了。
  final Map<String, ImageProvider> _avatars = {};

  /// 是否正在看档案网格。它是 `HomePage` 的本地状态，不是路由/新页面。
  bool _fleetExpanded = false;

  /// 网格里被收起的组。放在 HomePage 里，关掉网格再打开还保持折叠；
  /// 组 id 用 `_ungrouped` 哨兵表示未分组。
  final Set<String> _collapsedGroups = <String>{};

  void _toggleGroupCollapsed(String groupId) {
    setState(() {
      if (!_collapsedGroups.remove(groupId)) _collapsedGroups.add(groupId);
    });
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;

    final position = _scroll.position;
    final away =
        (position.maxScrollExtent - position.pixels) > _stickToBottomThreshold;
    if (away != _showJumpToBottom) {
      setState(() => _showJumpToBottom = away);
    }

    if (_loadingEarlier) return;
    if (position.pixels > _loadEarlierThreshold) return;
    if (!widget.controller.hasMoreBefore) return;
    unawaited(_loadEarlier());
  }

  /// 一次跳到最新那条消息。
  ///
  /// 用 animateTo 而不是 jumpTo：从很远的地方瞬间跳过去会让人分不清
  /// 自己是被带到了底部还是整屏换了一页。240ms 足够看清方向。
  void _jumpToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  /// 往上翻一页，并且**把滚动位置补回来**。
  ///
  /// 往前面插 N 条会让内容变高。不补偿的话，`pixels` 没变而内容长了，
  /// 用户视野里的东西会瞬间跳走 —— 翻得越多跳得越狠。
  ///
  /// **已知的残余误差**：补偿量取的是"总高度长了多少"，而这段读盘时间里
  /// 新到的消息也会让总高度变长，于是你会被多推下去约一条消息的高度。
  /// 要彻底消掉得把读盘和插入拆成两步（在插入那一瞬间同步量高度），
  /// 但那会让"往哪个档案里插"变成跨 await 的判断 —— 串档的风险比这点
  /// 抖动大得多，所以留着。
  Future<void> _loadEarlier() async {
    if (_loadingEarlier) return;
    setState(() => _loadingEarlier = true);

    final focused = _lastFocusedId;
    final before = _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
    try {
      await widget.controller.loadOlder();
    } catch (e) {
      // 读失败也要放开标志。留在 true 上的话 `_onScroll` 和
      // `_maybeAutoScroll` 就双双短路了：往上翻不动、新消息也不自动滚到
      // 底，而且界面上一点提示都没有 —— 静默失灵是最难查的那种。
      if (mounted) setState(() => _loadingEarlier = false);
      return;
    }
    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 读盘期间换了档案 —— 这时 before 是上一个档案的量，差值毫无意义，
      // 跳过去只会把人甩到一个莫名其妙的位置。新档案那边
      // _syncFocusedProfile 会负责滚到底。
      if (_scroll.hasClients && _lastFocusedId == focused) {
        final delta = _scroll.position.maxScrollExtent - before;
        _scroll.jumpTo(
          (_scroll.position.pixels + delta).clamp(
            0.0,
            _scroll.position.maxScrollExtent,
          ),
        );
      }
      setState(() => _loadingEarlier = false);
    });
  }

  /// 来了新消息才自动滚到底，而且**只在用户本来就贴着底部时**。
  ///
  /// 两个条件缺一不可：
  ///  - 不判 seq 的话，`_refreshStats` 每 500ms 一次的 notifyListeners
  ///    会把列表死死钉在底部，用户根本滚不上去看历史
  ///  - 不判位置的话，你正在往上翻，一条新消息就把你拽回去了
  void _maybeAutoScroll(int lastSeq) {
    final grew = lastSeq > _seenLastSeq;
    _seenLastSeq = lastSeq;

    if (_loadingEarlier || !grew) return;

    // 必须在**插入新消息之前**判断位置 —— 插完之后 maxScrollExtent 就变了
    var wasAtBottom = true;
    if (_scroll.hasClients) {
      final position = _scroll.position;
      wasAtBottom =
          (position.maxScrollExtent - position.pixels) <
          _stickToBottomThreshold;
    }
    if (!wasAtBottom) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  /// 换档案时跳到新那屏的底部。
  ///
  /// 只记下"欠一次到底"，真正跳的动作在 [_maybeCorrectToBottom] 里。
  /// 切换当下新档案的历史通常还没读出来（空态、甚至没有 ListView），
  /// 那一帧跳不了；等历史落地后 build 会再来一次。
  void _syncFocusedProfile(String id) {
    final revision = widget.controller.historyRevision;
    final sameFocus = id == _lastFocusedId;
    if (sameFocus && revision == _lastHistoryRevision) return;

    // 换频道那一帧、以及这次换频道的 re-load 完成后各来一次。后者很重要：
    // 前一次可能是在旧历史/旧 maxScrollExtent 上校正的。
    _lastFocusedId = id;
    _lastHistoryRevision = revision;
    if (!sameFocus) _seenLastSeq = 0;
    _pendingBottomCorrection = true;
    _bottomCorrectionMaxExtent = null;
    _bottomCorrectionStableFrames = 0;
  }

  /// 把欠下的"切换频道后回到底部"补上。
  ///
  /// 必须等到历史读完（[ConversationController.historyLoaded]）才清掉标记：
  /// 历史插进来会让内容变高，早清的话会停在"先到过一次底、随后被新历史
  /// 撑高"的中间位置。历史还没到时如果已经有列表，也先贴到底，避免用旧
  /// 频道的位置显示新频道。
  void _maybeCorrectToBottom() {
    if (!_pendingBottomCorrection || _bottomCorrectionScheduled) return;
    _bottomCorrectionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bottomCorrectionScheduled = false;
      if (!mounted || !_pendingBottomCorrection) return;
      // 周期里又切走了：这时的底部属于另一个频道，交给下一次校正。
      if (_lastFocusedId != widget.controller.config.focusedProfileId) return;

      // 新频道还空着（历史没读出来，或者本来就没有历史）—— 空列表没有
      // 可挂的 viewport。**不要在这里清标记**：`historyLoaded` 可能是上一次
      // 读盘留下的旧值，清早了等历史真正插进来就会停在顶部。等列表挂上
      // 再校正；如果频道一直是空的，留着标记也没有副作用。
      if (!_scroll.hasClients) return;

      final position = _scroll.position;
      final max = position.maxScrollExtent;
      position.jumpTo(max);

      // `historyLoaded` 可能是上一次读盘留下的旧值。正在为切换重读历史时
      // 先别清标记 —— 等 re-load 完成后的那次 notify 再收工。
      final ready =
          widget.controller.historyLoaded && !widget.controller.historyLoading;
      if (!ready) return;

      final sameMax = _bottomCorrectionMaxExtent == max;
      _bottomCorrectionMaxExtent = max;
      _bottomCorrectionStableFrames = sameMax
          ? _bottomCorrectionStableFrames + 1
          : 0;

      // 历史读完，并且最大滚动范围连续一帧没变，才算真正贴到底。
      // 中间列表还在长高时继续跳，避免跳在旧的 max 上然后停在顶部。
      if (_bottomCorrectionStableFrames >= 1) {
        _pendingBottomCorrection = false;
        _bottomCorrectionMaxExtent = null;
        _bottomCorrectionStableFrames = 0;
        return;
      }

      WidgetsBinding.instance.scheduleFrame();
      _maybeCorrectToBottom();
    });
  }

  /// 直接打开当前聚焦频道的设置页，不用先展开频道网格。
  ///
  /// 入口只在有聚焦频道时显示；这里再判一次空，避免配置在点击的同一帧
  /// 被清掉（例如别处删除了最后一个频道）。`focusedProfileId` 是非空的，
  /// 没有焦点时是空字符串。
  void _openFocusedChannelSettings() {
    final id = widget.controller.config.focusedProfileId;
    if (id.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChannelSettingsPage.edit(
          controller: widget.controller,
          profileId: id,
        ),
      ),
    );
  }

  /// 打开频道网格前记下当前消息位置。只开关网格、没切频道时要回到这里。
  void _openFleet() {
    _fleetAnchorOffset = _scroll.hasClients ? _scroll.position.pixels : null;
    _fleetAnchorFocusId = widget.controller.config.focusedProfileId;
    setState(() => _fleetExpanded = true);
  }

  /// 关闭频道网格。频道没变就恢复打开前的位置；变了则滚到新频道底部。
  void _closeFleet() {
    final restore =
        _fleetAnchorFocusId == widget.controller.config.focusedProfileId
        ? _fleetAnchorOffset
        : null;
    setState(() => _fleetExpanded = false);
    if (restore == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(restore.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  ImageProvider? _avatarFor(Profile profile) {
    final path = widget.controller.avatarPathOf(profile);
    if (path == null) return null;
    return _avatars.putIfAbsent(path, () => FileImage(File(path)));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final l10n = AppLocalizations.of(context);

    // **不要把它放进 AnimatedBuilder 的 builder 里。** 折叠栏自己订阅
    // `fleetRevision`；放进 builder 会被 500ms 电平刷新和每条后台消息
    // 跟着重建。
    final compactBar = ProfileCompactBar(
      controller: controller,
      avatarOf: _avatarFor,
      onOpen: _openFleet,
      onEditFocused: _openFocusedChannelSettings,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Z Connect'),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: l10n.debugPanelTooltip,
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DebugPage(controller: controller),
              ),
            ),
          ),
          IconButton(
            tooltip: l10n.brainConfigTooltip,
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsPage(controller: controller),
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: _fleetExpanded
            ? ProfileGridPanel(
                controller: controller,
                avatarOf: _avatarFor,
                onClose: _closeFleet,
                collapsedGroupIds: _collapsedGroups,
                onToggleGroup: _toggleGroupCollapsed,
              )
            : AnimatedBuilder(
                animation: controller,
                // 档案栏不依赖电平/消息，作为 child 传进去避免跟着重建。
                child: compactBar,
                builder: (context, compactBar) {
                  _maybeAutoScroll(controller.lastSeq);
                  _syncFocusedProfile(controller.config.focusedProfileId);
                  _maybeCorrectToBottom();
                  final hasOpen =
                      controller.config.focusedProfile?.enabled ?? false;

                  return Column(
                    children: [
                      const SizedBox(height: 8),
                      compactBar!,
                      if (hasOpen) ...[
                        _focusedOrb(context),
                        const SizedBox(height: 4),
                        _toggles(context),
                        const SizedBox(height: 6),
                        _headline(context),
                      ] else
                        _emptyProfiles(context),
                      if (controller.brainError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            controller.brainError!,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      Expanded(child: _messageStreamWithJump(context)),
                    ],
                  );
                },
              ),
      ),
    );
  }

  /// 折叠态的那个说话按钮。
  ///
  /// 以前它是 `ProfileSwipeBand` 里的中间那一页；现在只有聚焦档案一个，
  /// 旁边的圆和箭头都收进了网格。
  Widget _focusedOrb(BuildContext context) {
    final controller = widget.controller;
    final profile = controller.config.focusedProfile;
    if (profile == null || !profile.enabled) return _emptyProfiles(context);

    return VoiceOrb(
      levels: controller.levelsNotifier,
      state: _state(),
      enabled: !controller.busy,
      scale: 0.62,
      accent: Color(profile.accentColor),
      avatar: _avatarFor(profile),
      onTap: controller.toggle,
    );
  }

  /// 一个打开的档案都没有时的占位。屏幕不能空出一块，标题行也不能还写着
  /// "点击开始对话" —— 根本没有可以开始的对象。
  Widget _emptyProfiles(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return SizedBox(
      height: VoiceOrb.baseCanvasSize * 0.62,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.person_off_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.noEnabledProfiles,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              l10n.noEnabledProfilesBody,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  OrbState _state() {
    if (!widget.controller.active) {
      // 启动要好几步（前台服务、音频链路、1.26MB 的断句模型），这期间
      // `active` 还是 false。不单独报一个"启动中"，用户按下去只会看到
      // 按钮和没按之前一模一样 —— 于是再按第二下。
      return widget.controller.busy ? OrbState.starting : OrbState.idle;
    }
    return widget.controller.speaking ? OrbState.speaking : OrbState.listening;
  }

  Widget _headline(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final controller = widget.controller;

    final String text;
    if (controller.busy) {
      text = l10n.starting;
    } else if (!controller.active) {
      text = l10n.tapToStart;
    } else if (controller.segmenterError != null) {
      // 断了就没法切句，比 brain 连不上更致命 —— 用户说话将毫无反应
      text = l10n.segmenterUnavailable;
    } else if (controller.authFailed) {
      text = l10n.tokenInvalid;
    } else if (controller.brainError != null) {
      // brain 连不上时，光显示"正在听你说"是骗人的
      text = l10n.brainUnresponsive;
    } else if (controller.micMuted) {
      // 压在"正在说话/正在听"前面：麦克风关着是这一屏最重要的事实
      text = l10n.mutedUploadingOff;
    } else if (controller.speaking) {
      // 关掉那个开关之后音量减就只是调音量了，再写着"可以清空"是骗人
      text = controller.config.volumeKeyClearsQueue
          ? l10n.speakingCanClear
          : l10n.speaking;
    } else if (controller.userSpeaking) {
      text = l10n.listening;
    } else if (controller.queuedUtterances > 0) {
      text = l10n.queuedUtterances(controller.queuedUtterances);
    } else {
      text = l10n.listening;
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: Text(
        text,
        key: ValueKey(text),
        style: theme.textTheme.titleMedium?.copyWith(
          color: controller.active
              ? theme.colorScheme.onSurface
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _messageStream(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final controller = widget.controller;
    final messages = controller.messages;

    // 历史还没从盘上读出来（冷启动的头一两帧）时**什么都别说**。
    // 不区分的话会先闪一句"直接说话就行"，下一帧历史才冒出来 ——
    // 对用户来说就是"它说没有记录，然后又有了"。
    if (messages.isEmpty && !controller.historyLoaded) {
      return const SizedBox.shrink();
    }

    if (messages.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        children: [
          if (controller.segmenterError != null) _segmenterBanner(context),
          if (!controller.config.brain.isUsable) _configBanner(context),
          const SizedBox(height: 24),
          Text(
            controller.active ? l10n.idleHint : l10n.emptyHint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      controller: _scroll,
      // 允许回看历史：新消息不会把正在往上翻的用户拽回底部
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        // 往上翻会把更早的消息**插到前面**，没有 key 的话 Flutter 会按位置
        // 复用列表项，整屏内容会错位一帧。seq 是盘上发的号，唯一且单调。
        //
        // 落盘失败的那几条没有号（seq == 0），退回对象身份 —— 两个 seq 0
        // 的消息共用一个 key 会让列表项张冠李戴。
        return _bubble(
          context,
          message,
          key: message.seq > 0
              ? ValueKey<int>(message.seq)
              : ObjectKey(message),
        );
      },
    );
  }

  /// 消息流 + 右下角"回到底部"。
  ///
  /// 按钮压在列表上而不是占一行高度：它出现的时候正好是用户不在乎
  /// 最后一条消息被挡住一点的时候；贴在列表下面会永久吃掉一行空间。
  Widget _messageStreamWithJump(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final show = _showJumpToBottom && widget.controller.messages.isNotEmpty;

    return Stack(
      children: [
        Positioned.fill(child: _messageStream(context)),
        Positioned(
          right: 16,
          bottom: 12,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            child: show
                ? IconButton.filledTonal(
                    key: const ValueKey('jump-to-bottom'),
                    tooltip: l10n.jumpToBottom,
                    onPressed: _jumpToBottom,
                    icon: const Icon(Icons.keyboard_double_arrow_down_rounded),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  /// 断句引擎加载失败时的提示。
  ///
  /// 这一条比"还没配置 brain"更严重：没有 segmenter 就永远不会切出一句话，
  /// 你说什么都毫无反应。能量 VAD 已经删掉，没有能够顶上来的备胎，
  /// 所以必须在主界面正面说出来，而不是只写进调试日志。
  Widget _segmenterBanner(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline,
                size: 18,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.segmenterLoadFailed,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${widget.controller.segmenterError}\n\n'
            '${l10n.segmenterLoadFailedBody}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
        ],
      ),
    );
  }

  /// 未配置 brain 时的提示。
  ///
  /// 没有它的话，用户点按钮会毫无反应 —— 因为 start() 提前返回了，
  /// 而原因只写在调试日志里。那是最糟糕的一种失败：静默。
  Widget _configBanner(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline,
                size: 18,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.noBrain,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l10n.noBrainBody,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsPage(controller: widget.controller),
                ),
              ),
              child: Text(l10n.goToSettings),
            ),
          ),
        ],
      ),
    );
  }

  /// 两个开关：闭麦 / 打断。
  ///
  /// 放在 orb 下面而不是塞进设置页：闭麦是"我现在要跟旁边人说句话"这种
  /// 临时动作，点进设置页再退出来，话都说完了。
  Widget _toggles(BuildContext context) {
    final controller = widget.controller;
    final l10n = AppLocalizations.of(context);
    // 没开始对话时它没有意义（本来就没在采音频）。置灰但**不隐藏** ——
    // 否则开始/结束的一瞬间按钮会跳一下。
    final enabled = controller.active && !controller.busy;

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 10,
      runSpacing: 6,
      children: [
        _toggleChip(
          icon: controller.micMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
          label: controller.micMuted ? l10n.muted : l10n.mute,
          on: controller.micMuted,
          enabled: enabled,
          onTap: controller.toggleMicMuted,
        ),
        _toggleChip(
          icon: Icons.front_hand_rounded,
          label: l10n.bargeIn,
          on: controller.bargeIn,
          // 闭麦时打断天然失效（音频根本没上去），灰掉而不是假装能用
          enabled: enabled && !controller.micMuted,
          onTap: () => controller.updateConfig(
            controller.config.copyWith(bargeIn: !controller.bargeIn),
          ),
        ),
        Tooltip(
          message: l10n.skipCurrentSpeechTooltip,
          child: _actionChip(
            icon: Icons.skip_next_rounded,
            label: l10n.skipCurrentSpeech,
            // 没有声音在放/排队时按了也没用，灰掉。macOS 没有音量减键，
            // 手机上多一个随时可点的入口也不冲突。
            enabled: enabled && controller.speaking,
            onTap: () => controller.clearPlayback(),
          ),
        ),
      ],
    );
  }

  Widget _actionChip({
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return ActionChip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      onPressed: enabled ? onTap : null,
    );
  }

  Widget _toggleChip({
    required IconData icon,
    required String label,
    required bool on,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return FilterChip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      selected: on,
      // 选中已经有了底色，再打一个勾反而看不清图标
      showCheckmark: false,
      onSelected: enabled ? (_) => onTap() : null,
    );
  }

  Widget _bubble(
    BuildContext context,
    ConversationMessage message, {
    Key? key,
  }) {
    final theme = Theme.of(context);

    // 客户端自己写的一行提示（目前只有闭麦留痕）。不套气泡 —— 它不是谁说的话。
    if (message.role == MessageRole.note) {
      return Padding(
        key: key,
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          message.text,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final fromUser = message.role == MessageRole.user;

    final background = fromUser
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final foreground = fromUser
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;

    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: fromUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!fromUser) _assistantAvatar(context, theme, message),
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.72,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(fromUser ? 18 : 4),
                  bottomRight: Radius.circular(fromUser ? 4 : 18),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 正文可选：手机长按、桌面拖选/右键都能走系统选择菜单。
                  // 时间戳仍是普通 Text，不参与选择。
                  //
                  // 用户消息是语音转出来的，必须保持纯文本 —— 否则一句随口
                  // 说的 `*` 或 `#` 会被当成 Markdown。助手消息才渲染格式。
                  if (fromUser)
                    SelectableText(
                      message.text,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: foreground,
                      ),
                    )
                  else
                    MessageMarkdown(data: message.text, foreground: foreground),
                  const SizedBox(height: 3),
                  Text(
                    message.time,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: foreground.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (fromUser) _avatar(theme, Icons.person_rounded, foreground),
        ],
      ),
    );
  }

  Widget _avatar(ThemeData theme, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: CircleAvatar(
        radius: 14,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        child: Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  /// 助手头像上方的「原文」按钮。
  ///
  /// 按钮从上面收进头像那一列，而不是塞进气泡：气泡的宽高是消息内容说了算，
  /// 多余控件会改变气泡形状；头像列本来就有空白，宽度也刚好容得下 28px。
  /// 只有助手消息会走到这里 —— 用户消息是语音转写，没有 Markdown 源码。
  Widget _assistantAvatar(
    BuildContext context,
    ThemeData theme,
    ConversationMessage message,
  ) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: ValueKey('raw-markdown-${message.seq}'),
            tooltip: l10n.rawMarkdownTooltip,
            onPressed: () => _showRawMarkdown(context, message),
            icon: const Icon(Icons.code_rounded, size: 14),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(
              foregroundColor: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          CircleAvatar(
            radius: 14,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            child: Icon(
              Icons.graphic_eq_rounded,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 打开「原文」浮层。
  ///
  /// 手机用带拖拽手柄的底部弹层，桌面用居中的自定义对话框；两者共用
  /// [_RawMarkdownView]。气泡本身继续用 [MessageMarkdown] 渲染，关闭浮层
  /// 不会改动消息流。原文可能很长（代码块、表格），所以正文放在可滚动容器里。
  Future<void> _showRawMarkdown(
    BuildContext context,
    ConversationMessage message,
  ) {
    final theme = Theme.of(context);

    return showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final size = MediaQuery.sizeOf(dialogContext);
        final maxHeight = size.height * 0.72;
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          backgroundColor: theme.colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 620, maxHeight: maxHeight),
            child: SizedBox(
              width: 620,
              child: _RawMarkdownView(
                text: message.text,
                maxBodyHeight: maxHeight - 100,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 「原文」浮层的共享内容：标题栏 + 可滚动的等宽文本。
///
/// 单独做成 [StatefulWidget] 是为了自己持有 [ScrollController]：
/// `thumbVisibility: true` 的 [Scrollbar] 需要明确的控制器，否则会去挂到
/// 页面的 PrimaryScrollController 上。正文用 [Expanded] 吃掉剩余高度，
/// 浮层总高度因此保持稳定，长文本只滚动阅读区。
class _RawMarkdownView extends StatefulWidget {
  const _RawMarkdownView({
    required this.text,
    required this.maxBodyHeight,
  });

  final String text;

  /// 阅读区最高能占多高；短文本按内容收缩，长文本到上限后滚动。
  final double maxBodyHeight;

  @override
  State<_RawMarkdownView> createState() => _RawMarkdownViewState();
}

class _RawMarkdownViewState extends State<_RawMarkdownView> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);

    return Padding(
      key: const ValueKey('raw-markdown-content'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Icon(
                  Icons.notes_rounded,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.rawMarkdownTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('raw-markdown-close'),
                  onPressed: () => Navigator.of(context).maybePop(),
                  tooltip: l10n.close,
                  icon: const Icon(Icons.close_rounded, size: 20),
                  color: scheme.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxBodyHeight),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  radius: const Radius.circular(8),
                  thickness: 4,
                  child: SingleChildScrollView(
                    key: const ValueKey('raw-markdown-scroll'),
                    controller: _scroll,
                    padding: const EdgeInsets.only(right: 12),
                    child: SelectableText(
                      widget.text,
                      key: const ValueKey('raw-markdown-source'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        height: 1.5,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
