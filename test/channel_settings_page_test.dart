import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pp_friend/src/brain/brain_client.dart';
import 'package:pp_friend/src/config/assistant_config.dart';
import 'package:pp_friend/src/conversation/conversation_controller.dart';
import 'package:pp_friend/src/storage/memory_message_store.dart';
import 'package:pp_friend/src/ui/channel_settings_page.dart';

import 'support/avatar_fakes.dart';
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

/// A、B 开着，C 关着 —— 用来验证编辑现有频道时的上限。
AssistantConfig _threeProfiles() => const AssistantConfig(
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
    Profile(
      id: 'p_c',
      name: 'C',
      enabled: false,
      brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: 'c'),
    ),
  ],
  focusedProfileId: 'p_a',
);

/// 可控的测试 controller：不碰磁盘，允许子类卡住某一步来制造竞态。
abstract class _TestController extends ConversationController {
  _TestController()
    : super(
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
}

class _SlowSaveController extends _TestController {
  Completer<void>? gate;

  @override
  Future<void> saveProfile(Profile profile) async {
    final gate = this.gate;
    if (gate != null) await gate.future;
    await super.saveProfile(profile);
  }
}

class _FailingGroupController extends _TestController {
  @override
  Future<bool> assignProfileGroup(String profileId, String? groupId) async {
    throw StateError('group save failed');
  }
}

class _SlowDeleteController extends _TestController {
  Completer<void>? gate;

  @override
  Future<void> removeProfile(String id) async {
    final gate = this.gate;
    if (gate != null) await gate.future;
    await super.removeProfile(id);
  }
}

/// 全程不碰磁盘：历史走内存、头像走假的。
Future<ConversationController> _boot({
  int maxOpenProfiles = 12,
  AssistantConfig? config,
  FakeAvatarStore? avatars,
}) async {
  final controller = ConversationController(
    engine: FakeVoiceEngine(),
    maxOpenProfiles: maxOpenProfiles,
    brainFactory: () =>
        BrainClient(client: MockClient((_) async => throw StateError('不该发请求'))),
    history: MemoryMessageStore(),
    avatars: avatars ?? FakeAvatarStore(),
    segmenterFactory: ({
      required int sampleRate,
      required AssistantConfig config,
    }) async => FakeSegmenter(),
  );
  await controller.updateConfig(config ?? _twoProfiles());
  return controller;
}

Profile _profile(ConversationController controller, String id) =>
    controller.config.profiles.firstWhere((profile) => profile.id == id);

/// 用一个宿主页面把频道设置页推进导航栈 —— 这样 pop 之后还能断言「回到了
/// 网格」，而不是面对一个根路由。
class _Host extends StatelessWidget {
  const _Host({required this.page});

  final Widget page;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('网格')),
      body: Center(
        child: ElevatedButton(
          key: const ValueKey('host-open'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => page),
          ),
          child: const Text('打开频道设置'),
        ),
      ),
    );
  }
}

Future<void> _pumpPage(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(testApp(_Host(page: page)));
  await tester.tap(find.byKey(const ValueKey('host-open')));
  await tester.pumpAndSettle();
}

Finder _field(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(TextField));

/// 删除按钮在编辑器最下面，默认 600px 高的视口里不会被构建。
void _useTallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('新建是草稿：保存后才创建并归入预设分组', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    addTearDown(controller.dispose);
    final group = await controller.createGroup('工作');

    await _pumpPage(
      tester,
      ChannelSettingsPage.create(controller: controller, groupId: group.id),
    );

    expect(find.text('频道设置'), findsOneWidget);
    expect(find.text('新频道'), findsOneWidget, reason: '初始名称用 newChannelName');
    expect(controller.config.profiles.length, 2, reason: '打开页面不能落盘');
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
      reason: '没到上限时草稿默认启用',
    );

    await tester.enterText(_field('名字'), '我的频道');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(controller.config.profiles.length, 3);
    final created = controller.config.profiles.last;
    expect(created.name, '我的频道');
    expect(created.enabled, isTrue);
    expect(controller.groupIdOf(created.id), group.id, reason: '保存后归入来源分组');
    expect(
      controller.config.focusedProfileId,
      'p_a',
      reason: '新建频道不自动切换当前频道',
    );
    expect(find.byKey(const ValueKey('host-open')), findsOneWidget, reason: '保存后回到网格');
  });

  testWidgets('新建草稿不显示历史 section', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    addTearDown(controller.dispose);

    await _pumpPage(
      tester,
      ChannelSettingsPage.create(controller: controller),
    );

    expect(find.text('历史'), findsNothing, reason: '新频道还没有历史');
    expect(find.text('清空'), findsNothing);
  });

  testWidgets('编辑现有频道显示历史 section', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    addTearDown(controller.dispose);

    await _pumpPage(
      tester,
      ChannelSettingsPage.edit(controller: controller, profileId: 'p_a'),
    );

    expect(find.text('历史'), findsOneWidget);
  });

  testWidgets('未改动的草稿直接返回：不弹确认，也不创建频道', (tester) async {
    final controller = await _boot();
    addTearDown(controller.dispose);

    await _pumpPage(
      tester,
      ChannelSettingsPage.create(controller: controller),
    );
    expect(controller.config.profiles.length, 2);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing, reason: '什么都没改，不用拦');
    expect(find.byKey(const ValueKey('host-open')), findsOneWidget);
    expect(controller.config.profiles.length, 2, reason: '草稿不能变成空白频道');
  });

  testWidgets('有修改时返回先确认，放弃后什么都不留下', (tester) async {
    final controller = await _boot();
    addTearDown(controller.dispose);

    await _pumpPage(
      tester,
      ChannelSettingsPage.create(controller: controller),
    );
    await tester.enterText(_field('名字'), '改过的名字');
    await tester.pump();

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('放弃'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('host-open')), findsOneWidget);
    expect(controller.config.profiles.length, 2);
    expect(
      controller.config.profiles.any((p) => p.name == '改过的名字'),
      isFalse,
    );
  });

  testWidgets('确认框里点「算了」就留在页面上', (tester) async {
    final controller = await _boot();
    addTearDown(controller.dispose);

    await _pumpPage(
      tester,
      ChannelSettingsPage.create(controller: controller),
    );
    await tester.enterText(_field('名字'), '不要丢');
    await tester.pump();

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('算了'));
    await tester.pumpAndSettle();

    expect(find.text('频道设置'), findsOneWidget);
    expect(find.byKey(const ValueKey('host-open')), findsNothing);
  });

  testWidgets('编辑现有频道：复用同一份表单并保存', (tester) async {
    final controller = await _boot();
    addTearDown(controller.dispose);

    await _pumpPage(
      tester,
      ChannelSettingsPage.edit(controller: controller, profileId: 'p_a'),
    );

    expect(find.text('频道设置'), findsOneWidget);
    expect(
      tester.widget<TextField>(_field('名字')).controller?.text,
      'A',
      reason: '编辑模式加载现有频道',
    );

    await tester.enterText(_field('名字'), 'A 改');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(
      controller.config.profiles.firstWhere((p) => p.id == 'p_a').name,
      'A 改',
    );
    expect(controller.config.profiles.length, 2, reason: '编辑不应该新建频道');
    expect(find.byKey(const ValueKey('host-open')), findsOneWidget);
  });

  testWidgets('删除频道后 pop 回网格', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    addTearDown(controller.dispose);

    await _pumpPage(
      tester,
      ChannelSettingsPage.edit(controller: controller, profileId: 'p_a'),
    );

    final deleteButton = find.text('删除这个频道');
    final list = find.byType(ListView);
    for (var i = 0; i < 20 && deleteButton.evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(deleteButton);
    await tester.pumpAndSettle();
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(controller.config.profiles.any((p) => p.id == 'p_a'), isFalse);
    expect(find.byKey(const ValueKey('host-open')), findsOneWidget);
  });

  testWidgets('达到上限时草稿默认关闭，手动打开保存会被拦住并提示', (tester) async {
    _useTallView(tester);
    final controller = await _boot(maxOpenProfiles: 2);
    addTearDown(controller.dispose);

    await _pumpPage(
      tester,
      ChannelSettingsPage.create(controller: controller),
    );

    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
      reason: '到上限时新建频道先关着，不让新建绕过上限',
    );

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('最多同时打开 2 个，请先关闭一个'), findsOneWidget);
    expect(controller.config.profiles.length, 2, reason: '没写进去');
    expect(find.text('频道设置'), findsOneWidget, reason: '保存失败不该退页');
  });

  testWidgets('达到上限时保存仍可创建，但频道是关闭的并提示上限', (tester) async {
    final controller = await _boot(maxOpenProfiles: 2);
    addTearDown(controller.dispose);

    await _pumpPage(
      tester,
      ChannelSettingsPage.create(controller: controller),
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(controller.config.profiles.length, 3);
    final created = controller.config.profiles.last;
    expect(created.name, '新频道');
    expect(created.enabled, isFalse);
    expect(find.text('最多同时打开 2 个，请先关闭一个'), findsOneWidget);
    expect(find.byKey(const ValueKey('host-open')), findsOneWidget);
  });

  testWidgets('编辑现有频道：打开开关也不能绕过同时打开上限', (tester) async {
    _useTallView(tester);
    final controller = await _boot(
      maxOpenProfiles: 2,
      config: _threeProfiles(),
    );
    addTearDown(controller.dispose);

    await _pumpPage(
      tester,
      ChannelSettingsPage.edit(controller: controller, profileId: 'p_c'),
    );

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(_profile(controller, 'p_c').enabled, isFalse, reason: '上限必须拦住编辑路径');
    expect(find.text('最多同时打开 2 个，请先关闭一个'), findsOneWidget);
    expect(find.text('频道设置'), findsOneWidget, reason: '保存失败不该退页');
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
      reason: '没写进去，界面上的开关也要退回去',
    );
  });

  testWidgets('编辑现有频道：选已有分组，保存后落到分组存储', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    addTearDown(controller.dispose);
    final group = await controller.createGroup('工作');

    await _pumpPage(
      tester,
      ChannelSettingsPage.edit(controller: controller, profileId: 'p_a'),
    );

    await tester.ensureVisible(
      find.byKey(const ValueKey('profile-group-dropdown')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('profile-group-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('工作').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(controller.groupIdOf('p_a'), group.id);
  });

  testWidgets('编辑现有频道：可以新建分组，保存后归入该组', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    addTearDown(controller.dispose);

    await _pumpPage(
      tester,
      ChannelSettingsPage.edit(controller: controller, profileId: 'p_a'),
    );

    await tester.ensureVisible(find.byKey(const ValueKey('profile-group-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('profile-group-new')));
    await tester.pumpAndSettle();

    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '家庭');
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final group = controller.profileGroups.singleWhere((g) => g.name == '家庭');
    expect(controller.groupIdOf('p_a'), group.id);
  });

  testWidgets('编辑现有频道：去掉头像保存后把文件也删掉', (tester) async {
    final avatars = FakeAvatarStore();
    final controller = await _boot(avatars: avatars);
    addTearDown(controller.dispose);

    // 先让它"有一个头像"：配置里记着文件名，假存储里也有这个文件。
    const oldName = 'p_a_0.png';
    avatars.files[oldName] = '图';
    await controller.saveProfile(
      _profile(controller, 'p_a').copyWith(avatarFile: oldName),
    );

    await _pumpPage(
      tester,
      ChannelSettingsPage.edit(controller: controller, profileId: 'p_a'),
    );
    expect(find.text('去掉'), findsOneWidget, reason: '有头像才显示「去掉」');

    await tester.tap(find.text('去掉'));
    await tester.pumpAndSettle();
    expect(find.text('选头像'), findsOneWidget, reason: '按了去掉就变回「选头像」');

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(_profile(controller, 'p_a').avatarFile, isNull);
    expect(
      avatars.removed,
      contains(oldName),
      reason: '配置里不引用了，文件也得删 —— 不然每换一次就多一份永久垃圾',
    );
    expect(avatars.files.containsKey(oldName), isFalse);
  });

  testWidgets('新建保存中途失败会回滚，不留下半成品频道', (tester) async {
    final controller = _FailingGroupController();
    await controller.updateConfig(_twoProfiles());
    addTearDown(controller.dispose);

    await _pumpPage(
      tester,
      ChannelSettingsPage.create(controller: controller),
    );
    await tester.enterText(_field('名字'), '半成品');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(controller.config.profiles.length, 2, reason: '失败后必须回滚');
    expect(find.textContaining('没保存成功'), findsOneWidget);
    expect(find.text('频道设置'), findsOneWidget, reason: '失败后留在编辑页');
  });

  testWidgets('快速连点保存只创建一次，也只退一页', (tester) async {
    final controller = _SlowSaveController();
    await controller.updateConfig(_twoProfiles());
    addTearDown(controller.dispose);

    await _pumpPage(
      tester,
      ChannelSettingsPage.create(controller: controller),
    );
    await tester.enterText(_field('名字'), '双击频道');
    await tester.pump();

    controller.gate = Completer<void>();
    final save = find.text('保存');
    await tester.tap(save);
    await tester.tap(save);
    controller.gate!.complete();
    await tester.pumpAndSettle();

    expect(
      controller.config.profiles.where((p) => p.name == '双击频道').length,
      1,
    );
    expect(find.byKey(const ValueKey('host-open')), findsOneWidget);
  });

  testWidgets('来源分组在页面打开后被删，保存时回落到未分组', (tester) async {
    final controller = await _boot();
    addTearDown(controller.dispose);
    final group = await controller.createGroup('临时');

    await _pumpPage(
      tester,
      ChannelSettingsPage.create(controller: controller, groupId: group.id),
    );
    await controller.removeGroup(group.id);
    await tester.enterText(_field('名字'), '无组频道');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final created = controller.config.profiles.last;
    expect(created.name, '无组频道');
    expect(controller.groupIdOf(created.id), isNull);
  });

  testWidgets('从频道设置切到该频道后，按钮状态跟着刷新', (tester) async {
    _useTallView(tester);
    final controller = await _boot();
    addTearDown(controller.dispose);

    await _pumpPage(
      tester,
      ChannelSettingsPage.edit(controller: controller, profileId: 'p_b'),
    );

    final switchText = find.text('切到这个频道');
    final list = find.byType(ListView);
    for (var i = 0; i < 20 && switchText.evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    expect(switchText, findsOneWidget);
    await tester.ensureVisible(switchText);
    await tester.pumpAndSettle();
    await tester.tap(switchText);
    await tester.pumpAndSettle();

    expect(controller.config.focusedProfileId, 'p_b');
    expect(
      find.text('切到这个频道'),
      findsNothing,
      reason: '切过去之后这个入口应该消失',
    );
  });

  testWidgets('删除写盘时按返回不会多弹一层', (tester) async {
    _useTallView(tester);
    final controller = _SlowDeleteController();
    await controller.updateConfig(_twoProfiles());
    addTearDown(controller.dispose);

    await _pumpPage(
      tester,
      ChannelSettingsPage.edit(controller: controller, profileId: 'p_a'),
    );

    final deleteButton = find.text('删除这个频道');
    final list = find.byType(ListView);
    for (var i = 0; i < 20 && deleteButton.evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(deleteButton);
    await tester.pumpAndSettle();
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();

    controller.gate = Completer<void>();
    await tester.tap(find.text('删除'));
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pump();

    expect(
      find.text('频道设置'),
      findsOneWidget,
      reason: '删除请求还没完成，返回键不能把页面弹掉',
    );

    controller.gate!.complete();
    await tester.pumpAndSettle();

    expect(controller.config.profiles.any((p) => p.id == 'p_a'), isFalse);
    expect(find.byKey(const ValueKey('host-open')), findsOneWidget);
  });
}
