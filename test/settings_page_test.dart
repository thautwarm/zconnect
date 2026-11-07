import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pp_friend/src/brain/brain_client.dart';
import 'package:pp_friend/src/config/assistant_config.dart';
import 'package:pp_friend/src/conversation/conversation_controller.dart';
import 'package:pp_friend/src/storage/memory_message_store.dart';
import 'package:pp_friend/src/ui/settings_page.dart';

import 'support/avatar_fakes.dart';
import 'support/test_app.dart';
import 'support/voice_fakes.dart';

AssistantConfig _config() => const AssistantConfig(
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

/// 全程不碰磁盘：历史走内存、头像走假的。
///
/// **不能给它真的 appDir。** `testWidgets` 把测试体跑在假时钟里，真实的
/// 异步文件 IO 在那里永远不会完成 —— 测试不是失败，是直接挂死。
Future<(ConversationController, FakeAvatarStore, FakeVoiceEngine)> _boot({
  AssistantConfig? config,
}) async {
  final avatars = FakeAvatarStore();
  final engine = FakeVoiceEngine();
  final controller = ConversationController(
    engine: engine,
    brainFactory: () =>
        BrainClient(client: MockClient((_) async => throw StateError('不该发请求'))),
    history: MemoryMessageStore(),
    avatars: avatars,
    segmenterFactory: ({
      required int sampleRate,
      required AssistantConfig config,
    }) async => FakeSegmenter(),
  );
  await controller.updateConfig(config ?? _config());
  return (controller, avatars, engine);
}

Future<void> _pump(
  WidgetTester tester,
  ConversationController controller,
) async {
  await tester.pumpWidget(testApp(SettingsPage(controller: controller)));
  await tester.pumpAndSettle();
}

/// 按标签找输入框。比按下标找稳 —— 页面上本来就有一堆 TextField。
Finder _field(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(TextField));

/// 「说话人识别」在断句参数下面，默认 600px 高的视口里不会被构建。
void _useTallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('设置页是单页「配置」，只剩通用配置', (tester) async {
    final (controller, _, _) = await _boot();
    addTearDown(controller.dispose);

    await _pump(tester, controller);

    expect(find.text('配置'), findsOneWidget, reason: '标题还是原来的 settingsTitle');
    expect(find.text('频道'), findsNothing, reason: '频道 tab 已退役');
    expect(find.text('通用'), findsNothing, reason: '只剩一个 tab 就没必要保留 TabBar');

    // 通用配置项直接出现
    expect(_field('静音判定 (ms)'), findsOneWidget);
    expect(find.text('语言'), findsOneWidget);

    // 频道编辑字段不该再嵌在设置页里
    expect(find.text('Base URL'), findsNothing);
    expect(find.text('启用'), findsNothing);
  });

  testWidgets('保存会把断句参数写进配置', (tester) async {
    final (controller, _, _) = await _boot();
    addTearDown(controller.dispose);

    await _pump(tester, controller);
    await tester.enterText(_field('静音判定 (ms)'), '1234');
    await tester.pump();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(controller.config.vadMinSilenceMs, 1234);
    expect(find.text('已保存'), findsOneWidget);
  });

  testWidgets('「只有我的声音」切换后页面跟着 controller 重建', (tester) async {
    _useTallView(tester);
    final (controller, _, _) = await _boot();
    addTearDown(controller.dispose);

    await _pump(tester, controller);

    final tile = find.ancestor(
      of: find.text('只识别本人的声音'),
      matching: find.byType(SwitchListTile),
    );
    expect(tile, findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(tile).value,
      isTrue,
      reason: 'pvadEnabled 默认开',
    );

    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(controller.config.pvadEnabled, isFalse);
    expect(
      tester.widget<SwitchListTile>(tile).value,
      isFalse,
      reason: '开关状态必须跟着 controller 更新，不能停在旧画面',
    );
    expect(find.text('需要先导入声纹'), findsOneWidget);
  });

  testWidgets('关掉「音量减键清空队列」，会推到原生', (tester) async {
    // 原生侧按 onKeyDown 收键，它看不到配置 —— 不推下去的话，开关在界面上
    // 动了，按键行为一动不动。
    final (controller, _, engine) = await _boot();
    addTearDown(controller.dispose);

    await _pump(tester, controller);

    expect(controller.config.volumeKeyClearsQueue, isTrue, reason: '默认是拦');
    expect(engine.volumeKeyPushes, isEmpty, reason: '没人动过，不该推');

    // 这一节排在断句参数和说话人识别下面，默认在视口外。ListView 是懒构建的，
    // 屏幕外的项根本不在树里 —— 必须先滚出来。
    final tile = find.text('音量减键清空队列');
    final list = find.byType(ListView).last;
    for (var i = 0; i < 20 && tile.evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    expect(tile, findsOneWidget, reason: '滚到底也该看得见这一项');
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(controller.config.volumeKeyClearsQueue, isFalse);
    expect(engine.volumeKeyClearsQueue, isFalse, reason: '推下去的还是旧值就等于没改');
    expect(engine.volumeKeyPushes, [false]);
  });

  testWidgets('配置还没读回来时打开设置页不会崩', (tester) async {
    // 故意不 updateConfig：模拟冷启动后立刻点齿轮的那一帧。设置页只读全局
    // 参数，不应该依赖 profiles 是否已经加载。
    final controller = ConversationController(
      engine: FakeVoiceEngine(),
      brainFactory: () => BrainClient(
        client: MockClient((_) async => throw StateError('不该发请求')),
      ),
      history: MemoryMessageStore(),
      avatars: FakeAvatarStore(),
      segmenterFactory: ({
        required int sampleRate,
        required AssistantConfig config,
      }) async => FakeSegmenter(),
    );
    addTearDown(controller.dispose);

    await _pump(tester, controller);

    expect(tester.takeException(), isNull);
    expect(find.text('配置'), findsOneWidget, reason: '设置页本身要出来');
  });
}
