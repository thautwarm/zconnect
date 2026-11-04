import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pp_friend/src/config/fleet_store.dart';
import 'package:pp_friend/src/config/profile_group.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('保存的分组能在新 store 里读回来', () async {
    final fleet = const ProfileFleet(
      groups: [ProfileGroup(id: 'g_a', name: '工作', order: 0)],
      membership: {'p_1': 'g_a'},
    );

    await FleetStore().save(fleet);
    final back = await FleetStore().load();

    expect(back.sortedGroups.single.name, '工作');
    expect(back.groupIdOf('p_1'), 'g_a');
  });

  test('没有数据或 JSON 损坏时回退到空配置，不抛', () async {
    expect(
      (await FleetStore().load()).groups,
      isEmpty,
      reason: '第一次启动还没有这个 key',
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(FleetStore.key, '{不是 JSON');
    expect((await FleetStore().load()).groups, isEmpty);
  });

  test('分组独立 key：写分组不会碰 assistant_config_v1', () async {
    final prefs = await SharedPreferences.getInstance();
    const configJson = '{"profiles":[{"id":"p_1","brain":{}}]}';
    await prefs.setString('assistant_config_v1', configJson);

    await FleetStore().save(
      const ProfileFleet(
        groups: [ProfileGroup(id: 'g_a', name: '工作', order: 0)],
      ),
    );

    expect(prefs.getString('assistant_config_v1'), configJson);
    expect(prefs.getString(FleetStore.key), isNotNull);
  });

  test('旧版只认识 assistant_config_v1 时，分组仍然在', () async {
    final prefs = await SharedPreferences.getInstance();
    // 模拟旧 APK：只写自己的配置 key，完全不认识 profile_fleet_v1
    await prefs.setString('assistant_config_v1', '{"profiles":[]}');

    await FleetStore().save(
      const ProfileFleet(
        groups: [ProfileGroup(id: 'g_a', name: '保留', order: 0)],
        membership: {'p_1': 'g_a'},
      ),
    );

    // 旧 APK 再保存一次配置（内容无所谓），分组 key 不受影响
    await prefs.setString('assistant_config_v1', '{"profiles":[]}');

    final back = await FleetStore().load();
    expect(back.sortedGroups.single.name, '保留');
    expect(back.groupIdOf('p_1'), 'g_a');
  });
}
