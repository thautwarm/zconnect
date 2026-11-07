import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pp_friend/src/config/assistant_config.dart';
import 'package:pp_friend/src/conversation/conversation_controller.dart';
import 'package:pp_friend/src/storage/memory_message_store.dart';
import 'package:pp_friend/src/ui/home_page.dart';
import 'package:pp_friend/src/ui/widgets/profile_grid_card.dart';

import 'support/test_app.dart';
import 'support/voice_fakes.dart';

Profile _profile(String id, {bool enabled = true, String? name}) => Profile(
  id: id,
  name: name ?? id,
  enabled: enabled,
  brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: id),
);

/// A 聚焦、B 打开、C 可开可关。
AssistantConfig _threeProfiles({
  bool cEnabled = false,
  bool cConfigured = true,
}) => AssistantConfig(
  profiles: [
    _profile('p_a', name: 'A'),
    _profile('p_b', name: 'B'),
    Profile(
      id: 'p_c',
      name: 'C',
      enabled: cEnabled,
      brain: cConfigured
          ? const BrainConfig(baseUrl: 'http://test.local:8000', brainId: 'c')
          : const BrainConfig(),
    ),
  ],
  focusedProfileId: 'p_a',
);

Future<ConversationController> _boot(
  AssistantConfig config, {
  int maxOpenProfiles = 12,
  MemoryMessageStore? history,
}) async {
  final controller = ConversationController(
    engine: FakeVoiceEngine(),
    history: history ?? MemoryMessageStore(),
    appDir: () async => null,
    maxOpenProfiles: maxOpenProfiles,
  );
  await controller.updateConfig(config);
  return controller;
}

/// orb 在折叠态一直呼吸，不能用 pumpAndSettle。
Future<void> _settle(WidgetTester tester, [int frames = 8]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _pumpHome(
  WidgetTester tester,
  ConversationController controller,
) async {
  await tester.pumpWidget(testApp(HomePage(controller: controller)));
  await _settle(tester);
}

Future<void> _openFleet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('fleet-open')));
  await _settle(tester);
}

Finder _card(String id) => find.byKey(ValueKey('profile-card-$id'));
Finder _power(String id) => find.byKey(ValueKey('profile-power-$id'));
Finder _newCard() => find.byKey(const ValueKey('profile-new-channel-card'));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('卡片主体只切 focus，不改 enabled', (tester) async {
    final controller = await _boot(_threeProfiles());
    addTearDown(controller.dispose);
    await _pumpHome(tester, controller);
    await _openFleet(tester);

    await tester.tap(_card('p_b'));
    await _settle(tester);

    expect(controller.config.focusedProfileId, 'p_b');
    expect(
      controller.config.profiles.firstWhere((p) => p.id == 'p_b').enabled,
      isTrue,
      reason: '切换焦点不是开关，不能顺手改 enabled',
    );
  });

  testWidgets('小开关只改 enabled，不改 focus', (tester) async {
    final controller = await _boot(_threeProfiles());
    addTearDown(controller.dispose);
    await _pumpHome(tester, controller);
    await _openFleet(tester);

    expect(find.byTooltip('关闭B'), findsOneWidget);

    await tester.tap(_power('p_b'));
    await _settle(tester);

    expect(
      controller.config.profiles.firstWhere((p) => p.id == 'p_b').enabled,
      isFalse,
    );
    expect(controller.config.focusedProfileId, 'p_a', reason: '开关不能切走焦点');
    expect(find.byTooltip('打开B'), findsOneWidget);

    await tester.tap(_power('p_b'));
    await _settle(tester);

    expect(
      controller.config.profiles.firstWhere((p) => p.id == 'p_b').enabled,
      isTrue,
    );
    expect(controller.config.focusedProfileId, 'p_a');
  });

  testWidgets('关闭的卡片主体只提示，不切换也不打开', (tester) async {
    final controller = await _boot(_threeProfiles());
    addTearDown(controller.dispose);
    await _pumpHome(tester, controller);
    await _openFleet(tester);

    await tester.tap(_card('p_c'));
    await _settle(tester);

    expect(controller.config.focusedProfileId, 'p_a');
    expect(
      controller.config.profiles.firstWhere((p) => p.id == 'p_c').enabled,
      isFalse,
    );
    expect(find.text('C 已关闭，点右上角开关打开'), findsOneWidget);
  });

  testWidgets('打开数量到上限时提示，不偷偷再开一个', (tester) async {
    final controller = await _boot(_threeProfiles(), maxOpenProfiles: 2);
    addTearDown(controller.dispose);
    await _pumpHome(tester, controller);
    await _openFleet(tester);

    expect(find.text('2/3 已打开'), findsOneWidget);

    await tester.tap(_power('p_c'));
    await _settle(tester);

    expect(
      controller.config.profiles.firstWhere((p) => p.id == 'p_c').enabled,
      isFalse,
    );
    expect(find.text('最多同时打开 2 个，请先关闭一个'), findsOneWidget);
  });

  testWidgets('状态行区分当前、打开待开始和关闭', (tester) async {
    final controller = await _boot(_threeProfiles());
    addTearDown(controller.dispose);
    await _pumpHome(tester, controller);
    await _openFleet(tester);

    expect(find.text('当前'), findsOneWidget);
    expect(
      find.text('已打开 · 待开始'),
      findsNWidgets(2),
      reason: '会话没开始，开着的 A、B 都不能显示成监听中',
    );
    expect(find.text('已关闭'), findsOneWidget);
  });

  testWidgets('打开但没配置 brain 时状态行明确说未配置', (tester) async {
    final controller = await _boot(
      _threeProfiles(cEnabled: true, cConfigured: false),
    );
    addTearDown(controller.dispose);
    await _pumpHome(tester, controller);
    await _openFleet(tester);

    expect(find.text('未配置 brain'), findsOneWidget);
  });

  testWidgets('未分组末尾有＋卡片，点它打开频道新建页且不落盘', (tester) async {
    final controller = await _boot(_threeProfiles());
    addTearDown(controller.dispose);
    await _pumpHome(tester, controller);
    await _openFleet(tester);

    expect(_newCard(), findsOneWidget, reason: '全部视图里未分组末尾固定有＋卡片');

    await tester.tap(_newCard());
    await tester.pumpAndSettle();

    expect(find.text('频道设置'), findsOneWidget);
    expect(find.text('新频道'), findsOneWidget, reason: '打开的是新建草稿');
    expect(controller.config.profiles.length, 3, reason: '打开新建页不能立刻创建频道，保存才落盘');

    // 什么都没改，直接返回。
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(controller.config.profiles.length, 3);
    expect(find.byKey(const ValueKey('profile-panel')), findsOneWidget);
  });

  testWidgets('＋卡片不计入组标题数量，也不参与拖拽', (tester) async {
    final controller = await _boot(_threeProfiles());
    addTearDown(controller.dispose);
    await _pumpHome(tester, controller);
    await _openFleet(tester);

    // 打开面板时会自动把当前聚焦卡片滚进视口，组标题可能刚好被滚出
    // 懒构建范围；先回到顶部再检查标题数量。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await _settle(tester);

    final header = find.byKey(const ValueKey('group-header-__ungrouped__'));
    expect(
      find.descendant(of: header, matching: find.text('3')),
      findsOneWidget,
      reason: '组标题数量只算频道，不算＋卡片',
    );

    expect(
      find.ancestor(
        of: _newCard(),
        matching: find.byWidgetPredicate(
          (widget) => widget is LongPressDraggable<dynamic>,
        ),
      ),
      findsNothing,
      reason: '＋卡片只是入口，不能像频道卡片那样长按拖动',
    );
  });

  testWidgets('搜索框保持紧凑，图标和提示文字竖直居中', (tester) async {
    final controller = await _boot(_threeProfiles());
    addTearDown(controller.dispose);
    await _pumpHome(tester, controller);
    await _openFleet(tester);

    final search = find.byKey(const ValueKey('profile-search'));
    expect(tester.getSize(search).height, lessThanOrEqualTo(40.1));
    final iconCenter = tester.getCenter(find.byIcon(Icons.search));
    final hintCenter = tester.getCenter(find.text('搜索频道'));
    expect(
      (iconCenter.dy - hintCenter.dy).abs(),
      lessThan(2),
      reason: '搜索图标和提示文字要在同一水平线上',
    );
  });

  testWidgets('搜索时隐藏＋卡片，清空后恢复', (tester) async {
    final controller = await _boot(_threeProfiles());
    addTearDown(controller.dispose);
    await _pumpHome(tester, controller);
    await _openFleet(tester);

    expect(_newCard(), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('profile-search')), 'A');
    await _settle(tester, 4);
    expect(_newCard(), findsNothing, reason: '搜索只显示匹配频道，不显示新建入口');

    await tester.enterText(find.byKey(const ValueKey('profile-search')), '');
    await _settle(tester, 4);
    expect(_newCard(), findsOneWidget);
  });

  testWidgets('200 个档案只构建视口里的卡片', (tester) async {
    final profiles = [
      for (var i = 1; i <= 200; i++)
        _profile('p_$i', name: '档案$i', enabled: i <= 12),
    ];
    final controller = await _boot(
      AssistantConfig(profiles: profiles, focusedProfileId: 'p_1'),
    );
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);
    await _openFleet(tester);

    final built = find.byType(ProfileGridCard).evaluate().length;
    expect(built, greaterThan(0));
    expect(built, lessThan(200), reason: 'SliverGrid 应该只构建视口附近的卡片，不能一次建 200 张');

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1200));
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('展开网格会自动滚到当前聚焦卡片', (tester) async {
    final profiles = [
      for (var i = 1; i <= 40; i++)
        _profile('p_$i', name: '档案$i', enabled: i == 40),
    ];
    final controller = await _boot(
      AssistantConfig(profiles: profiles, focusedProfileId: 'p_40'),
    );
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);
    await _openFleet(tester);
    await _settle(tester, 12);

    final card = _card('p_40');
    expect(card, findsOneWidget, reason: '聚焦卡片在列表末尾，展开后应被滚进视口并构建出来');

    final rect = tester.getRect(card);
    expect(rect.top, greaterThanOrEqualTo(0.0));
    expect(
      rect.bottom,
      lessThanOrEqualTo(600.0),
      reason: '默认测试视口高 600，滚动后当前卡片必须完整落在视口内',
    );
  });
}
