import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pp_friend/src/config/assistant_config.dart';
import 'package:pp_friend/src/config/profile_group.dart';
import 'package:pp_friend/src/conversation/conversation_controller.dart';
import 'package:pp_friend/src/storage/memory_message_store.dart';
import 'package:pp_friend/src/ui/home_page.dart';

import 'support/test_app.dart';
import 'support/voice_fakes.dart';

Profile _profile(String id, String name, {bool enabled = true}) => Profile(
  id: id,
  name: name,
  enabled: enabled,
  brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: id),
);

AssistantConfig _threeProfiles() => AssistantConfig(
  profiles: [_profile('p_a', 'A'), _profile('p_b', 'B'), _profile('p_c', 'C')],
  focusedProfileId: 'p_a',
);

Future<ConversationController> _boot({AssistantConfig? config}) async {
  final controller = ConversationController(
    engine: FakeVoiceEngine(),
    history: MemoryMessageStore(),
    appDir: () async => null,
  );
  await controller.updateConfig(config ?? _threeProfiles());
  return controller;
}

/// 建两个组：A 在"工作"、B 在"家庭"、C 未分组。
Future<(ProfileGroup, ProfileGroup)> _groups(
  ConversationController controller,
) async {
  final work = await controller.createGroup('工作');
  final home = await controller.createGroup('家庭');
  await controller.assignProfileGroup('p_a', work.id);
  await controller.assignProfileGroup('p_b', home.id);
  return (work, home);
}

Future<void> _settle(WidgetTester tester, [int frames = 10]) async {
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
Finder _chip(String id) => find.byKey(ValueKey('group-chip-$id'));
Finder _groupMenu(String id) => find.byKey(ValueKey('group-menu-$id'));

/// 三个组 section 在默认 600px 高里会有一部分在视口外，sliver 不会构建。
/// 这些测试验的是分组结构，不是滚动本身，所以给一个更高的测试视口。
void _useTallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _enterSearch(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('profile-search')), text);
  await _settle(tester, 4);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('网格按组 section，组 chip 可以组间切换', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    final (work, _) = await _groups(controller);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);
    await _openFleet(tester);

    expect(find.text('工作'), findsOneWidget);
    expect(find.text('家庭'), findsOneWidget);
    expect(find.text('未分组'), findsOneWidget);
    expect(_card('p_a'), findsOneWidget);
    expect(_card('p_b'), findsOneWidget);
    expect(_card('p_c'), findsOneWidget);

    await tester.tap(_chip(work.id));
    await _settle(tester);

    expect(_card('p_a'), findsOneWidget);
    expect(_card('p_b'), findsNothing);
    expect(_card('p_c'), findsNothing);
    expect(find.text('家庭'), findsNothing, reason: '筛选后不该还显示别的组');

    await tester.tap(_chip('__all__'));
    await _settle(tester);
    expect(_card('p_b'), findsOneWidget);
    expect(_card('p_c'), findsOneWidget);
  });

  testWidgets('搜索跨组；清空后恢复原来的组筛选', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    final (work, _) = await _groups(controller);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);
    await _openFleet(tester);

    await tester.tap(_chip(work.id));
    await _settle(tester);
    expect(_card('p_a'), findsOneWidget);
    expect(_card('p_b'), findsNothing);

    // B 在"家庭"里，但搜索是跨组的，应该能搜出来。
    await _enterSearch(tester, 'B');
    expect(_card('p_b'), findsOneWidget);
    expect(_card('p_a'), findsNothing);
    expect(find.text('家庭'), findsOneWidget);

    // 清空搜索 → 回到之前选中的"工作"。
    await _enterSearch(tester, '');
    expect(_card('p_a'), findsOneWidget);
    expect(_card('p_b'), findsNothing);
  });

  testWidgets('搜索也能按组名命中整组', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    await _groups(controller);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);
    await _openFleet(tester);

    await _enterSearch(tester, '家庭');
    expect(_card('p_b'), findsOneWidget);
    expect(_card('p_a'), findsNothing);
    expect(_card('p_c'), findsNothing);
  });

  testWidgets('新建分组后自动切到该组，空组有提示', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);
    await _openFleet(tester);

    await tester.tap(find.byKey(const ValueKey('group-new')));
    await tester.pumpAndSettle();

    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, '新组');
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(controller.profileGroups.map((g) => g.name), contains('新组'));
    expect(find.text('这个分组里还没有档案'), findsOneWidget);
  });

  testWidgets('组菜单可以改名、上移、删除', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    final (work, home) = await _groups(controller);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);
    await _openFleet(tester);

    // 改名
    await tester.tap(_groupMenu(work.id));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, '公司');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(
      controller.profileGroups.firstWhere((g) => g.id == work.id).name,
      '公司',
    );

    // 上移：家庭从第 2 个挪到第 1 个
    await tester.tap(_groupMenu(home.id));
    await tester.pumpAndSettle();
    await tester.tap(find.text('上移'));
    await tester.pumpAndSettle();
    expect(controller.profileGroups.map((g) => g.id).toList(), [
      home.id,
      work.id,
    ]);

    // 删除：成员回到未分组，组消失
    await tester.tap(_groupMenu(work.id));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除分组'));
    await tester.pumpAndSettle();

    expect(controller.profileGroups.any((g) => g.id == work.id), isFalse);
    expect(controller.groupIdOf('p_a'), isNull);
    expect(find.text('已删除分组 公司，成员回到未分组'), findsOneWidget);
  });

  testWidgets('选一个空组时显示该组的空态，不是全屏空态', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    final (work, _) = await _groups(controller);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);
    await _openFleet(tester);

    await tester.tap(_chip(work.id));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('group-new')));
    await tester.pumpAndSettle();
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, '空组');
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    // 新建后自动切到空组：能看到组标题和空态。
    expect(find.text('空组'), findsOneWidget);
    expect(find.text('这个分组里还没有档案'), findsOneWidget);
  });

  testWidgets('有多个分组时也会滚到后面的当前聚焦卡片', (tester) async {
    final profiles = [
      for (var i = 1; i <= 30; i++) _profile('p_$i', '档案$i', enabled: i == 30),
    ];
    final controller = await _boot(
      config: AssistantConfig(profiles: profiles, focusedProfileId: 'p_30'),
    );
    addTearDown(controller.dispose);

    // 三个组，每组 10 个；当前聚焦在最后一组。
    for (var g = 0; g < 3; g++) {
      final group = await controller.createGroup('组$g');
      for (var i = g * 10 + 1; i <= (g + 1) * 10; i++) {
        await controller.assignProfileGroup('p_$i', group.id);
      }
    }

    await _pumpHome(tester, controller);
    await _openFleet(tester);
    await _settle(tester, 12);

    final card = _card('p_30');
    expect(card, findsOneWidget, reason: '跨组估算偏移后，最后一组的当前卡片要可见');
    expect(tester.getRect(card).bottom, lessThanOrEqualTo(600.0));
  });

  testWidgets('卡片菜单可以编辑任意档案，并直接定位到它', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    addTearDown(controller.dispose);
    await controller.switchProfile('p_b');

    await _pumpHome(tester, controller);
    await _openFleet(tester);

    // 当前聚焦是 B，但点 A 的菜单必须打开 A。
    await tester.tap(find.byKey(const ValueKey('profile-menu-p_a')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑档案'));
    await tester.pumpAndSettle();

    expect(find.text('配置'), findsOneWidget);
    expect(find.text('p_a'), findsOneWidget, reason: '编辑的是 A，不是当前聚焦的 B');
    expect(find.text('p_b'), findsNothing);

    Navigator.of(tester.element(find.text('配置'))).pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-panel')), findsOneWidget);
  });

  testWidgets('卡片菜单可以移动到已有分组', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    addTearDown(controller.dispose);
    final work = await controller.createGroup('工作');

    await _pumpHome(tester, controller);
    await _openFleet(tester);

    await tester.tap(find.byKey(const ValueKey('profile-menu-p_a')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移动到分组'));
    await tester.pumpAndSettle();

    final dialog = find.byType(SimpleDialog);
    expect(dialog, findsOneWidget);
    await tester.tap(
      find.descendant(of: dialog, matching: find.text('工作')),
    );
    await tester.pumpAndSettle();

    expect(controller.groupIdOf('p_a'), work.id);
    expect(find.text('已将 A 移到 工作'), findsOneWidget);
  });

  testWidgets('卡片菜单可以顺手新建分组并移入', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);
    await _openFleet(tester);

    await tester.tap(find.byKey(const ValueKey('profile-menu-p_a')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移动到分组'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(SimpleDialog),
        matching: find.text('新建分组…'),
      ),
    );
    await tester.pumpAndSettle();

    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '新组');
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    final group = controller.profileGroups.singleWhere((g) => g.name == '新组');
    expect(controller.groupIdOf('p_a'), group.id);
    expect(find.text('已将 A 移到 新组'), findsOneWidget);
  });

  testWidgets('长按拖动组标题可以调整组顺序', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    final (work, home) = await _groups(controller);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);
    await _openFleet(tester);
    expect(controller.profileGroups.map((g) => g.id).toList(), [
      work.id,
      home.id,
    ]);

    // 标题行中间是 Spacer，命中测试落不到子节点上；从组名文字长按开始。
    final workHeader = find.byKey(ValueKey('group-header-${work.id}'));
    final homeHeader = find.byKey(ValueKey('group-header-${home.id}'));
    final drag = await tester.startGesture(
      tester.getCenter(
        find.descendant(of: workHeader, matching: find.text('工作')),
      ),
    );
    await tester.pump(kLongPressTimeout + kPressTimeout);
    await drag.moveTo(
      tester.getCenter(
        find.descendant(of: homeHeader, matching: find.text('家庭')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await drag.up();
    await tester.pumpAndSettle();

    expect(controller.profileGroups.map((g) => g.id).toList(), [
      home.id,
      work.id,
    ]);
  });

  testWidgets('长按拖动卡片可以在同组内重排', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);
    await _openFleet(tester);
    expect(controller.config.profiles.map((p) => p.id).toList(), [
      'p_a',
      'p_b',
      'p_c',
    ]);

    final drag = await tester.startGesture(tester.getCenter(_card('p_a')));
    await tester.pump(kLongPressTimeout + kPressTimeout);
    await drag.moveTo(tester.getCenter(_card('p_b')));
    await tester.pump(const Duration(milliseconds: 100));
    await drag.up();
    await tester.pumpAndSettle();

    expect(controller.config.profiles.map((p) => p.id).toList(), [
      'p_b',
      'p_a',
      'p_c',
    ]);
    expect(controller.config.focusedProfileId, 'p_a', reason: '拖动不该改焦点');
  });

  testWidgets('把卡片拖到组标题上会换组', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    final (work, _) = await _groups(controller);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);
    await _openFleet(tester);

    final drag = await tester.startGesture(tester.getCenter(_card('p_c')));
    await tester.pump(kLongPressTimeout + kPressTimeout);
    await drag.moveTo(
      tester.getCenter(find.byKey(ValueKey('group-header-${work.id}'))),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await drag.up();
    await tester.pumpAndSettle();

    expect(controller.groupIdOf('p_c'), work.id);
  });
}
