import 'package:http/http.dart' as http;

/// Web 上没有 `dart:io` 的 HttpClient，也没有系统代理可读；走浏览器默认。
http.Client createProxyAwareClient() => http.Client();
