import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'system_proxy.dart';

/// 创建走系统代理（如果有）的 HTTP 客户端。
///
/// `findProxy` 用 `PROXY host:port`：HTTP 走代理的绝对 URI，HTTPS 走
/// CONNECT，两者都由代理完成目标 DNS，符合“Wi-Fi 代理 + 局域网域名”的用法。
http.Client createProxyAwareClient() {
  final inner = HttpClient();
  // 每次请求都现读：App 回到前台时会重新拉一次系统代理，已经建好的
  // 连接池也能跟着切换，不用重启。
  inner.findProxy = (_) {
    final authority = SystemProxy.authority;
    return authority == null ? 'DIRECT' : 'PROXY $authority';
  };
  return IOClient(inner);
}
