import 'dart:math';

/// 档案分组。
///
/// 分组是**用户手动维护的对象**，不是从 URL/brainId 推导出来的标签。
/// 它有稳定的 id（改名字不影响成员关系）、可编辑的名字和可调整的顺序，
/// 因此空组也能存在。
///
/// **它不写进 `assistant_config_v1`。** 分组信息单独存在
/// `profile_fleet_v1`（见 `fleet_store.dart`）：旧版 APK 保存配置时不会
/// 碰它，降级之后分组不会丢。代价是两个 key 不是原子写入 —— 分组保存
/// 失败不该影响 brain 配置，调用方要按"非致命"处理。
class ProfileGroup {
  const ProfileGroup({required this.id, required this.name, this.order = 0});

  /// 稳定 id。它只做内部标识，不参与目录名，所以不像 [Profile.id] 那样
  /// 有字符集限制，但仍然只生成安全字符。
  final String id;

  /// 显示名。允许临时为空，由界面兜底显示。
  final String name;

  /// 组在组间切换条上的顺序。读入后会按它排序并重新编号。
  final int order;

  static final Random _random = Random();

  /// 造一个新组 id。只在用户新建分组时调一次。
  ///
  /// 和 `Profile.newId()` 一样带时间戳 + 随机后缀，避免同一毫秒内
  /// 连续新建时撞 id。
  static String newId() {
    final millis = DateTime.now().millisecondsSinceEpoch;
    final suffix = _random.nextInt(1 << 24).toRadixString(36);
    return 'g_${millis}_$suffix';
  }

  ProfileGroup copyWith({String? name, int? order}) =>
      ProfileGroup(id: id, name: name ?? this.name, order: order ?? this.order);

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'order': order};

  /// 坏数据返回 null，由调用方跳过这一项。
  ///
  /// 和档案配置一样：**不能抛**。抛出去会让整份分组配置回退成空，
  /// 用户手动建好的组会一起消失。
  static ProfileGroup? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.trim().isEmpty) return null;
    final name = json['name'];
    final order = json['order'];
    return ProfileGroup(
      id: id,
      name: name is String ? name : '',
      order: order is num ? order.toInt() : 0,
    );
  }
}

/// 所有分组以及"档案 → 组"的成员关系。
///
/// 成员关系单独存 map 而不是写在 `Profile` 上，正是为了走独立 key：
/// 旧版 APK 不认识 `Profile.groupId`，一旦保存配置就会把它抹掉。
class ProfileFleet {
  const ProfileFleet({
    this.groups = const <ProfileGroup>[],
    this.membership = const <String, String>{},
  });

  /// 组列表。使用时请用 [sortedGroups]；这里保留原始顺序，方便序列化。
  final List<ProfileGroup> groups;

  /// profileId → groupId。没有条目就是"未分组"。
  final Map<String, String> membership;

  static const ProfileFleet empty = ProfileFleet();

  ProfileFleet copyWith({
    List<ProfileGroup>? groups,
    Map<String, String>? membership,
  }) => ProfileFleet(
    groups: groups ?? this.groups,
    membership: membership ?? this.membership,
  );

  /// 按 order 排序后的组。
  List<ProfileGroup> get sortedGroups {
    final next = List<ProfileGroup>.of(groups);
    next.sort((a, b) {
      final byOrder = a.order.compareTo(b.order);
      // order 相同（手工改坏的配置）时用 id 兜底，保证结果稳定。
      return byOrder != 0 ? byOrder : a.id.compareTo(b.id);
    });
    return next;
  }

  String? groupIdOf(String profileId) => membership[profileId];

  /// 把档案放进一个组；[groupId] 为 null 表示移出分组。
  ProfileFleet assign(String profileId, String? groupId) {
    final next = Map<String, String>.of(membership);
    if (groupId == null) {
      next.remove(profileId);
    } else {
      next[profileId] = groupId;
    }
    return copyWith(membership: next);
  }

  ProfileFleet removeMembership(String profileId) => assign(profileId, null);

  /// 删除一个组。它的成员回到"未分组"，不跟着组一起消失。
  ProfileFleet removeGroup(String groupId) {
    final next = <String, String>{};
    membership.forEach((profileId, id) {
      if (id != groupId) next[profileId] = id;
    });
    return ProfileFleet(
      groups: groups.where((group) => group.id != groupId).toList(),
      membership: next,
    );
  }

  ProfileFleet renameGroup(String groupId, String name) => copyWith(
    groups: [
      for (final group in groups)
        group.id == groupId ? group.copyWith(name: name) : group,
    ],
  );

  /// 把组挪到 [newOrder]（挪完之后的最终下标），并重新编号。
  ProfileFleet moveGroup(String groupId, int newOrder) {
    final ordered = sortedGroups;
    final index = ordered.indexWhere((group) => group.id == groupId);
    if (index < 0) return this;

    final target = newOrder.clamp(0, ordered.length - 1);
    if (index == target) return this;

    final moved = ordered.removeAt(index);
    ordered.insert(target, moved);
    return copyWith(
      groups: [
        for (var i = 0; i < ordered.length; i++) ordered[i].copyWith(order: i),
      ],
    );
  }

  /// 按当前档案集合清理坏数据。
  ///
  /// - 组 id 重复的丢掉后面的；
  /// - order 重新连续编号；
  /// - 指向不存在档案或不存在组的成员关系丢掉。
  ///
  /// 空组**保留**：用户可能先建组再往里放档案。
  ProfileFleet normalized({required Set<String> profileIds}) {
    final seen = <String>{};
    final ordered = <ProfileGroup>[];
    for (final group in sortedGroups) {
      if (!seen.add(group.id)) continue;
      ordered.add(group.copyWith(order: ordered.length));
    }

    final groupIds = ordered.map((group) => group.id).toSet();
    final nextMembership = <String, String>{};
    membership.forEach((profileId, groupId) {
      if (!profileIds.contains(profileId)) return;
      if (!groupIds.contains(groupId)) return;
      nextMembership[profileId] = groupId;
    });

    return ProfileFleet(groups: ordered, membership: nextMembership);
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'groups': groups.map((group) => group.toJson()).toList(),
    'membership': membership,
  };

  /// 读盘。坏字段跳过，整份 JSON 损坏时上层会回退到 [empty]。
  factory ProfileFleet.fromJson(Map<String, dynamic> json) {
    final rawGroups = json['groups'];
    final groups = <ProfileGroup>[];
    final seen = <String>{};
    if (rawGroups is List) {
      for (final item in rawGroups) {
        if (item is! Map) continue;
        final group = ProfileGroup.fromJson(item.cast<String, dynamic>());
        if (group == null || !seen.add(group.id)) continue;
        groups.add(group);
      }
    }

    final rawMembership = json['membership'];
    final membership = <String, String>{};
    if (rawMembership is Map) {
      rawMembership.forEach((profileId, groupId) {
        if (profileId is String && groupId is String) {
          membership[profileId] = groupId;
        }
      });
    }

    return ProfileFleet(groups: groups, membership: membership);
  }
}
