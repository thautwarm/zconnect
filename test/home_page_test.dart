import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pp_friend/src/config/assistant_config.dart';
import 'package:pp_friend/src/conversation/conversation_controller.dart';
import 'package:pp_friend/src/conversation/message.dart';
import 'package:pp_friend/src/storage/memory_message_store.dart';
import 'package:pp_friend/src/storage/message_store.dart';
import 'package:pp_friend/src/ui/channel_settings_page.dart';
import 'package:pp_friend/src/ui/home_page.dart';

import 'support/test_app.dart';
import 'support/voice_fakes.dart';

AssistantConfig _twoProfiles() => const AssistantConfig(
  profiles: [
    Profile(
      id: 'p_a',
      name: 'A',
      brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: 'a'),
    ),
    Profile(
      id: 'p_b',
      name: 'B',
      brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: 'b'),
    ),
  ],
  focusedProfileId: 'p_a',
);

Future<ConversationController> _boot(
  MessageStore store, {
  AssistantConfig? config,
}) async {
  final controller = ConversationController(
    engine: FakeVoiceEngine(),
    history: store,
    appDir: () async => null,
  );
  await controller.updateConfig(config ?? _twoProfiles());
  return controller;
}

/// 可以卡住某个频道读盘的历史仓库，用来制造"频道已切过去、历史还没到"的中间态。
class _GatedMessageStore implements MessageStore {
  _GatedMessageStore(this._inner);

  final MemoryMessageStore _inner;

  /// 非空时，`p_b` 的 [loadRecent] 会一直等到它完成。
  Completer<void>? gate;

  @override
  Future<List<ConversationMessage>> loadRecent(
    String profileId, {
    int limit = 300,
  }) async {
    final gate = this.gate;
    if (gate != null && profileId == 'p_b') await gate.future;
    return _inner.loadRecent(profileId, limit: limit);
  }

  @override
  Future<List<ConversationMessage>> loadOlder(
    String profileId, {
    required int beforeSeq,
    int limit = 50,
  }) => _inner.loadOlder(profileId, beforeSeq: beforeSeq, limit: limit);

  @override
  Future<ConversationMessage> append(
    String profileId, {
    required MessageRole role,
    required String text,
    DateTime? at,
  }) => _inner.append(profileId, role: role, text: text, at: at);

  @override
  Future<int> lastSeq(String profileId) => _inner.lastSeq(profileId);

  @override
  Future<void> clear(String profileId) => _inner.clear(profileId);

  @override
  Future<int> sizeBytes(String profileId) => _inner.sizeBytes(profileId);
}

/// 主界面里那个说话按钮一直在呼吸（无限动画），
/// 所以**不能用 pumpAndSettle** —— 它永远等不到静止，会直接超时。
Future<void> _settle(WidgetTester tester, [int frames = 8]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _pumpHome(WidgetTester tester, ConversationController c) async {
  await tester.pumpWidget(testApp(HomePage(controller: c)));
  await _settle(tester);
}

/// 消息列表的滚动位置。
///
/// 消息正文现在是 `SelectableText`，它内部也带一个（横向的）Scrollable，
/// 所以在 ListView 的后代里按类型找会命中多个；列表自己的那个最先出现。
ScrollPosition _listPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('有历史就直接显示，不显示"直接说话就行"', (tester) async {
    final store = MemoryMessageStore();
    await store.append('p_a', role: MessageRole.user, text: '我上次说的');
    await store.append('p_a', role: MessageRole.assistant, text: '它上次回的');
    final controller = await _boot(store);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    expect(find.text('我上次说的'), findsOneWidget);
    expect(find.text('它上次回的'), findsOneWidget);
    expect(find.text('直接说话就行'), findsNothing);
  });

  testWidgets('没历史才显示引导语', (tester) async {
    final controller = await _boot(MemoryMessageStore());
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    // 没开始对话，所以是"开始之后…"那句
    expect(find.text('开始之后，你和它说的话都会出现在这里'), findsOneWidget);
  });

  testWidgets('点档案入口展开网格，点卡片主体切档案', (tester) async {
    final store = MemoryMessageStore();
    await store.append('p_a', role: MessageRole.user, text: 'A 说的话');
    await store.append('p_b', role: MessageRole.user, text: 'B 说的话');
    final controller = await _boot(store);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);
    expect(find.text('A 说的话'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('fleet-open')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('profile-panel')),
      findsOneWidget,
      reason: '入口单击在同页展开网格，不是新路由',
    );

    await tester.tap(find.byKey(const ValueKey('profile-card-p_b')));
    await _settle(tester, 12);
    expect(controller.config.focusedProfileId, 'p_b');

    await tester.tap(find.byKey(const ValueKey('fleet-close')));
    await _settle(tester, 12);

    expect(find.text('B 说的话'), findsOneWidget);
    expect(find.text('A 说的话'), findsNothing, reason: '一个档案一屏历史，不混在一起');
  });

  testWidgets('消息流可直接打开当前聚焦频道的设置页', (tester) async {
    final controller = await _boot(MemoryMessageStore());
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    // 三个入口并存：调试、全局设置、当前频道设置。
    expect(find.byIcon(Icons.tune_rounded), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    final entry = find.byKey(const ValueKey('focused-channel-settings'));
    expect(entry, findsOneWidget, reason: '有聚焦频道时入口应可见');

    await tester.tap(entry);
    await _settle(tester, 12);

    expect(find.byType(ChannelSettingsPage), findsOneWidget);
    expect(find.text('频道设置'), findsOneWidget);
    expect(
      tester
          .widget<ChannelSettingsPage>(find.byType(ChannelSettingsPage))
          .profileId,
      'p_a',
      reason: '打开的必须是当前聚焦的频道，而不是随便一个',
    );
  });

  testWidgets('切到另一个频道后，直接入口打开的是新聚焦频道', (tester) async {
    final controller = await _boot(MemoryMessageStore());
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);
    await controller.switchProfile('p_b');
    await _settle(tester, 12);

    await tester.tap(find.byKey(const ValueKey('focused-channel-settings')));
    await _settle(tester, 12);

    expect(
      tester
          .widget<ChannelSettingsPage>(find.byType(ChannelSettingsPage))
          .profileId,
      'p_b',
      reason: '入口要跟着当前焦点走',
    );
  });

  testWidgets('没有聚焦频道时不显示频道设置入口', (tester) async {
    // 唯一的频道是关着的，因此没有「当前聚焦频道」。
    const config = AssistantConfig(
      profiles: [
        Profile(
          id: 'p_a',
          name: 'A',
          enabled: false,
          brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: 'a'),
        ),
      ],
      focusedProfileId: 'p_a',
    );
    final controller = await _boot(MemoryMessageStore(), config: config);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    expect(
      find.byKey(const ValueKey('focused-channel-settings')),
      findsNothing,
      reason: '没有可编辑的频道时不能留一个点了没反应的入口',
    );
    // 网格和全局设置入口不受影响。
    expect(find.byKey(const ValueKey('fleet-open')), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
  });

  testWidgets('手机端网格底部有回到消息横条', (tester) async {
    final controller = await _boot(MemoryMessageStore());
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);
    await tester.tap(find.byKey(const ValueKey('fleet-open')));
    await _settle(tester);

    final back = find.byKey(const ValueKey('fleet-back-to-messages'));
    expect(back, findsOneWidget);
    await tester.tap(back);
    await _settle(tester, 12);

    expect(
      find.byKey(const ValueKey('profile-panel')),
      findsNothing,
      reason: '底部横条点一下就应该回到消息流',
    );
    expect(find.byKey(const ValueKey('fleet-open')), findsOneWidget);
  });

  testWidgets('桌面端网格不显示回到消息横条，保留左上角关闭', (tester) async {
    final controller = await _boot(MemoryMessageStore());
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      testApp(
        Theme(
          data: ThemeData(platform: TargetPlatform.linux),
          child: HomePage(controller: controller),
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('fleet-open')));
    await _settle(tester);

    expect(
      find.byKey(const ValueKey('fleet-back-to-messages')),
      findsNothing,
      reason: '桌面端不需要拇指可达的底部横条',
    );
    expect(
      find.byKey(const ValueKey('fleet-close')),
      findsOneWidget,
      reason: '左上角关闭仍然保留',
    );
  });

  testWidgets('往上翻会加载更早的历史，加载完之后视野不跳', (tester) async {
    final store = MemoryMessageStore();
    // 超过内存窗口（300 条）才谈得上分页
    for (var i = 1; i <= 340; i++) {
      await store.append('p_a', role: MessageRole.user, text: '第 $i 条');
    }
    final controller = await _boot(store);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    // 打开时载入的是最近的 300 条（第 41~340 条）
    expect(find.text('第 340 条'), findsOneWidget);
    expect(controller.hasMoreBefore, isTrue);

    // 拖一次就到顶，而且拖动距离给得比内容总高度还大，所以一定停在 pixels = 0。
    // （drag 是按给定距离滚动的，不是滚到尽头 —— 给 20000 会停在离顶 1676px 处，
    //   那样根本触发不了加载。）
    final maxBefore = _listPosition(tester).maxScrollExtent;
    await tester.drag(find.byType(ListView), const Offset(0, 30000));
    await _settle(tester, 6);

    expect(
      controller.messages.length,
      greaterThan(300),
      reason: '翻到顶就该去读更早的那一页',
    );
    expect(controller.messages.first.seq, 1);
    expect(
      controller.messages.map((m) => m.seq).toSet().length,
      controller.messages.length,
      reason: '不重不漏',
    );

    // 往前面插 40 条会让内容变高。不补偿滚动位置的话 pixels 还停在 0，
    // 用户会瞬间被弹到最开头。
    final position = _listPosition(tester);
    final grew = position.maxScrollExtent - maxBefore;
    expect(grew, greaterThan(0));
    expect(
      position.pixels,
      closeTo(grew, 1),
      reason:
          '补了正好"新插进来那些的高度"：插进来的应该在视野上面，'
          '而不是把当前视野挤走',
    );
  });

  testWidgets('翻上去之后出现"回到底部"，点一下回到最新', (tester) async {
    final store = MemoryMessageStore();
    for (var i = 1; i <= 30; i++) {
      await store.append('p_a', role: MessageRole.user, text: '第 $i 条');
    }
    final controller = await _boot(store);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    const button = ValueKey('jump-to-bottom');
    expect(find.byKey(button), findsNothing, reason: '贴着底部时不该挡着');

    // 往上翻（drag 正值 = 内容往下走 = 看更早的消息）
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await _settle(tester);

    expect(find.byKey(button), findsOneWidget);
    final position = _listPosition(tester);
    expect(
      position.maxScrollExtent - position.pixels,
      greaterThan(120),
      reason: '得真的离底部够远才显示',
    );

    await tester.tap(find.byKey(button));
    await _settle(tester);

    final after = _listPosition(tester);
    expect(after.pixels, closeTo(after.maxScrollExtent, 1));
    expect(find.byKey(button), findsNothing, reason: '回到最新之后按钮收起');
  });

  testWidgets('切到另一个频道后停在新频道历史底部，历史异步到达后再校正', (tester) async {
    final inner = MemoryMessageStore();
    for (var i = 1; i <= 40; i++) {
      await inner.append('p_a', role: MessageRole.user, text: 'A 第 $i 条');
      await inner.append('p_b', role: MessageRole.user, text: 'B 第 $i 条');
    }
    final store = _GatedMessageStore(inner);
    final controller = await _boot(store);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);
    // 启动时聚焦 p_a，已经停在它自己的底部。
    final aPosition = _listPosition(tester);
    expect(aPosition.pixels, closeTo(aPosition.maxScrollExtent, 1));

    // 卡住 p_b 的读盘：切过去之后消息流先是空的，历史稍后才插进来。
    store.gate = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('fleet-open')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('profile-card-p_b')));
    await _settle(tester, 12);
    expect(controller.config.focusedProfileId, 'p_b');

    // 历史还没到就回到消息流：这时不能停在顶部，也不能用 p_a 的位置。
    await tester.tap(find.byKey(const ValueKey('fleet-close')));
    await _settle(tester, 12);
    expect(find.text('B 第 40 条'), findsNothing, reason: '历史仍被卡住');

    // 历史落地：插进来之后必须再次校正到底部，而不是停在中间。
    store.gate!.complete();
    await _settle(tester, 12);

    expect(find.text('B 第 40 条'), findsOneWidget);
    expect(find.text('A 第 40 条'), findsNothing, reason: '显示的是新频道的历史');
    final position = _listPosition(tester);
    expect(position.maxScrollExtent, greaterThan(0));
    expect(
      position.pixels,
      closeTo(position.maxScrollExtent, 1),
      reason: '历史异步加载完成后要再次校正到底部',
    );
  });

  testWidgets('只开关频道网格、没有切频道时保留滚动位置', (tester) async {
    final store = MemoryMessageStore();
    for (var i = 1; i <= 40; i++) {
      await store.append('p_a', role: MessageRole.user, text: '第 $i 条');
    }
    final controller = await _boot(store);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    // 先主动往上翻，离开底部。
    await tester.drag(find.byType(ListView), const Offset(0, 500));
    await _settle(tester, 8);
    final before = _listPosition(tester);
    expect(before.pixels, greaterThan(0));
    expect(
      before.maxScrollExtent - before.pixels,
      greaterThan(120),
      reason: '确实不在底部，否则这个测试没有区分度',
    );

    await tester.tap(find.byKey(const ValueKey('fleet-open')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('profile-panel')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('fleet-close')));
    await _settle(tester, 12);

    final after = _listPosition(tester);
    expect(
      after.pixels,
      closeTo(before.pixels, 1),
      reason: '只是开关网格，不应该被强制拉回底部',
    );
  });

  testWidgets('消息正文可选中：用户消息保持纯文本，助手消息走 Markdown', (tester) async {
    final store = MemoryMessageStore();
    await store.append('p_a', role: MessageRole.user, text: '我上次说的');
    await store.append('p_a', role: MessageRole.assistant, text: '它上次回的');
    final controller = await _boot(store);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    // 用户消息仍然是普通的 SelectableText，且没有被 Markdown 解析。
    final userSelectable = tester.widgetList<SelectableText>(
      find.ancestor(
        of: find.text('我上次说的'),
        matching: find.byType(SelectableText),
      ),
    );
    expect(userSelectable, hasLength(1));
    expect(userSelectable.single.data, '我上次说的');
    expect(userSelectable.single.enableInteractiveSelection, isTrue);
    expect(
      find.ancestor(of: find.text('我上次说的'), matching: find.byType(GptMarkdown)),
      findsNothing,
      reason: '用户的语音转写不能被当成 Markdown',
    );

    // 助手消息由 GptMarkdown 渲染，外面包着 SelectionArea 提供选中能力。
    expect(find.byType(GptMarkdown), findsOneWidget);
    expect(
      find.ancestor(of: find.text('它上次回的'), matching: find.byType(GptMarkdown)),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text('它上次回的'),
        matching: find.byType(SelectionArea),
      ),
      findsOneWidget,
      reason: '必须允许交互式选择（手机长按 / 桌面拖选、右键）',
    );
  });

  testWidgets('桌面宽度下原文以居中对话框展示，关闭后仍渲染 Markdown', (tester) async {
    final store = MemoryMessageStore();
    await store.append('p_a', role: MessageRole.user, text: '用户的话');
    await store.append('p_a', role: MessageRole.assistant, text: '**是粗体**');
    final controller = await _boot(store);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    // 默认测试视口 800x600，走桌面分支。
    expect(
      tester.view.physicalSize.width / tester.view.devicePixelRatio,
      greaterThanOrEqualTo(600),
    );

    // 气泡里显示的是渲染结果，源码默认不可见。
    expect(find.text('是粗体'), findsOneWidget);
    expect(find.text('**是粗体**'), findsNothing);
    expect(find.byTooltip('原文'), findsOneWidget, reason: '只有助手消息头像上方有原文入口');

    await tester.tap(find.byTooltip('原文'));
    await _settle(tester, 8);

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('原文'), findsOneWidget);
    final source = tester.widget<SelectableText>(
      find.byKey(const ValueKey('raw-markdown-source')),
    );
    expect(source.data, '**是粗体**', reason: '浮层展示原文，而不是渲染后的文本');
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
      reason: '长原文必须放在可滚动容器里',
    );
    final scrollbar = tester.widget<Scrollbar>(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(Scrollbar),
      ),
    );
    expect(scrollbar.thumbVisibility, isTrue, reason: '滚动条要一直可见');

    await tester.tap(find.byKey(const ValueKey('raw-markdown-close')));
    await _settle(tester, 8);

    expect(find.byType(Dialog), findsNothing);
    expect(find.text('是粗体'), findsOneWidget, reason: '关闭浮层不改动消息流');
    expect(find.text('**是粗体**'), findsNothing);
  });

  testWidgets('手机宽度下原文以居中弹窗展示，长文本可滚动', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final longText = [
      '**开头**',
      '',
      ...List.generate(40, (i) => '第 $i 行：这是一段比较长的原文内容。'),
    ].join('\n');

    final store = MemoryMessageStore();
    await store.append('p_a', role: MessageRole.assistant, text: longText);
    final controller = await _boot(store);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    // 手机宽度也走居中弹窗，不再从底部弹出。
    expect(
      tester.view.physicalSize.width / tester.view.devicePixelRatio,
      lessThan(600),
    );

    await tester.tap(find.byTooltip('原文'));
    await _settle(tester, 8);

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('原文'), findsOneWidget);

    final source = tester.widget<SelectableText>(
      find.byKey(const ValueKey('raw-markdown-source')),
    );
    expect(source.data, longText, reason: '弹窗展示完整原文');

    final scrollbar = tester.widget<Scrollbar>(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(Scrollbar),
      ),
    );
    expect(scrollbar.thumbVisibility, isTrue, reason: '滚动条要一直可见');
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
      reason: '长原文必须放在可滚动容器里',
    );

    await tester.tap(find.byKey(const ValueKey('raw-markdown-close')));
    await _settle(tester, 8);

    expect(find.byType(Dialog), findsNothing);
    expect(find.text('开头'), findsOneWidget, reason: '关闭弹窗不改动消息流');
  });

  testWidgets('用户消息没有原文入口', (tester) async {
    final store = MemoryMessageStore();
    await store.append('p_a', role: MessageRole.user, text: '**用户说的**');
    final controller = await _boot(store);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    expect(find.text('**用户说的**'), findsOneWidget, reason: '用户消息保持纯文本');
    expect(find.byTooltip('原文'), findsNothing, reason: '语音转写没有 Markdown 源码可看');
  });

  testWidgets('助手消息的 Markdown 会渲染，用户消息里的符号保持原样', (tester) async {
    final store = MemoryMessageStore();
    await store.append('p_a', role: MessageRole.user, text: '**不是粗体**');
    await store.append('p_a', role: MessageRole.assistant, text: '**是粗体**');
    final controller = await _boot(store);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    expect(find.text('**不是粗体**'), findsOneWidget, reason: '用户消息按纯文本显示，星号不能被吃掉');
    expect(find.text('是粗体'), findsOneWidget);
    expect(find.text('**是粗体**'), findsNothing);
  });
}
