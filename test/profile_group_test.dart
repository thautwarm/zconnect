import 'package:flutter_test/flutter_test.dart';

import 'package:pp_friend/src/config/profile_group.dart';

void main() {
  group('ProfileGroup', () {
    test('JSON 往返不丢字段', () {
      const group = ProfileGroup(id: 'g_1', name: '工作', order: 2);
      final back = ProfileGroup.fromJson(group.toJson())!;

      expect(back.id, 'g_1');
      expect(back.name, '工作');
      expect(back.order, 2);
    });

    test('id 非法的项丢掉，不让它变成幽灵组', () {
      expect(ProfileGroup.fromJson(const {'name': '没有 id'}), isNull);
      expect(
        ProfileGroup.fromJson(const {'id': '   ', 'name': '空白 id'}),
        isNull,
      );
    });

    test('newId 每次都不同，且不是空串', () {
      final ids = <String>{for (var i = 0; i < 100; i++) ProfileGroup.newId()};
      expect(ids.length, 100);
      expect(ids.every((id) => id.startsWith('g_')), isTrue);
    });
  });

  group('ProfileFleet', () {
    const a = ProfileGroup(id: 'g_a', name: 'A', order: 0);
    const b = ProfileGroup(id: 'g_b', name: 'B', order: 1);

    test('assign / groupIdOf / removeMembership', () {
      var fleet = const ProfileFleet()
          .assign('p_1', 'g_a')
          .assign('p_2', 'g_a');

      expect(fleet.groupIdOf('p_1'), 'g_a');
      expect(fleet.groupIdOf('p_2'), 'g_a');
      expect(fleet.groupIdOf('p_3'), isNull);

      fleet = fleet.removeMembership('p_1');
      expect(fleet.groupIdOf('p_1'), isNull);
      expect(fleet.groupIdOf('p_2'), 'g_a');
    });

    test('删除组时成员回到未分组，组本身消失', () {
      final fleet = const ProfileFleet(groups: [a, b])
          .assign('p_1', 'g_a')
          .assign('p_2', 'g_b')
          .removeGroup('g_a');

      expect(fleet.groups.map((g) => g.id), ['g_b']);
      expect(fleet.groupIdOf('p_1'), isNull);
      expect(fleet.groupIdOf('p_2'), 'g_b');
    });

    test('改名不动成员，移动后重新编号', () {
      var fleet = const ProfileFleet(groups: [a, b])
          .assign('p_1', 'g_a')
          .renameGroup('g_a', '工作');

      expect(fleet.groups.first.name, '工作');
      expect(fleet.groupIdOf('p_1'), 'g_a');

      fleet = fleet.moveGroup('g_b', 0);
      expect(fleet.sortedGroups.map((g) => g.id), ['g_b', 'g_a']);
      expect(fleet.sortedGroups.map((g) => g.order), [0, 1]);
    });

    test('normalized 丢掉孤儿成员关系，压缩 order，保留空组', () {
      final fleet = ProfileFleet(
        groups: const [
          ProfileGroup(id: 'g_a', name: 'A', order: 5),
          ProfileGroup(id: 'g_b', name: 'B', order: 5),
          ProfileGroup(id: 'g_c', name: '空组', order: 9),
        ],
        membership: const {
          'p_1': 'g_a',
          'p_2': 'g_b',
          'p_deleted': 'g_a', // 档案没了
          'p_1_dup': 'g_missing', // 组没了
        },
      );

      final normalized = fleet.normalized(profileIds: {'p_1', 'p_2'});

      expect(normalized.groups.map((g) => g.id), ['g_a', 'g_b', 'g_c']);
      expect(normalized.groups.map((g) => g.order), [0, 1, 2]);
      expect(normalized.groupIdOf('p_1'), 'g_a');
      expect(normalized.groupIdOf('p_2'), 'g_b');
      expect(normalized.groupIdOf('p_deleted'), isNull);
      expect(normalized.groupIdOf('p_1_dup'), isNull);
    });

    test('JSON 往返保留组、顺序和成员关系', () {
      final fleet = const ProfileFleet(groups: [a, b])
          .assign('p_1', 'g_b')
          .assign('p_2', 'g_a');
      final back = ProfileFleet.fromJson(fleet.toJson());

      expect(back.sortedGroups.map((g) => g.id), ['g_a', 'g_b']);
      expect(back.groupIdOf('p_1'), 'g_b');
      expect(back.groupIdOf('p_2'), 'g_a');
    });

    test('JSON 里的重复组 id 只留第一个，坏成员关系跳过', () {
      final fleet = ProfileFleet.fromJson(const {
        'groups': [
          {'id': 'g_a', 'name': '第一', 'order': 0},
          {'id': 'g_a', 'name': '重复', 'order': 1},
          {'id': '', 'name': '非法', 'order': 2},
        ],
        'membership': {'p_1': 'g_a', 'p_2': 42},
      });

      expect(fleet.groups.length, 1);
      expect(fleet.groups.single.name, '第一');
      expect(fleet.membership['p_1'], 'g_a');
      expect(fleet.membership.containsKey('p_2'), isFalse);
    });
  });
}
