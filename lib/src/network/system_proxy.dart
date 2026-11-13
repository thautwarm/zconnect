import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 当前系统网络配置的 HTTP 代理。
///
/// Dart 的 `HttpClient` 默认不走 Android Wi-Fi 设置里的自定义代理；启动时
/// 通过原生 MethodChannel 读一次 host/port，后面创建 HTTP 客户端时把它
/// 显式交给 `HttpClient.findProxy`。
class SystemProxy {
  SystemProxy._();

  static const MethodChannel _channel = MethodChannel(
    'com.ppfriend.pp_friend/proxy',
  );

  /// 形如 `host:port`；没有代理或平台不支持时为 null。
  static String? _authority;
  static String? get authority => _authority;

  /// 读取一次系统代理。失败（Web、macOS 暂无实现、权限问题）就当直连。
  static Future<void> load() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('getProxy');
      final host = (result?['host'] as String?)?.trim();
      final port = result?['port'];
      _authority = host != null && host.isNotEmpty && port is int && port > 0
          ? '$host:$port'
          : null;
    } catch (_) {
      _authority = null;
    }
  }

  @visibleForTesting
  static void debugSetAuthority(String? value) => _authority = value;
}
