import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'profile_group.dart';

/// 分组配置的本地持久化。
///
/// **故意和 `assistant_config_v1` 分开。** 旧版 APK 的 `Profile` 不认识
/// 分组字段，一旦它保存整份 `assistant_config_v1`，嵌在里面的分组信息
/// 就会被抹掉。分组单独存一个 key，降级回旧版再升回来仍然还在。
///
/// 代价是两个 key 不是原子写入：分组保存失败只影响分组展示，不影响
/// brain 配置。调用方按非致命错误处理。
class FleetStore {
  static const String key = 'profile_fleet_v1';

  /// 读不到、JSON 损坏都回退到空配置 —— 分组丢了不应该让 App 起不来。
  Future<ProfileFleet> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return ProfileFleet.empty;
    try {
      return ProfileFleet.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      return ProfileFleet.empty;
    }
  }

  Future<void> save(ProfileFleet fleet) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(fleet.toJson()));
  }
}
