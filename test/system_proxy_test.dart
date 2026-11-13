import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pp_friend/src/network/system_proxy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.ppfriend.pp_friend/proxy');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    SystemProxy.debugSetAuthority(null);
  });

  test('读取原生返回的 host/port', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getProxy');
      return <String, dynamic>{'host': '192.168.1.2', 'port': 7890};
    });

    await SystemProxy.load();
    expect(SystemProxy.authority, '192.168.1.2:7890');
  });

  test('没有代理或端口非法时退回直连', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);

    await SystemProxy.load();
    expect(SystemProxy.authority, isNull);

    messenger.setMockMethodCallHandler(
      channel,
      (call) async => <String, dynamic>{'host': '', 'port': 0},
    );
    await SystemProxy.load();
    expect(SystemProxy.authority, isNull);
  });

  test('原生通道不可用时不影响启动', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => throw MissingPluginException('no proxy plugin'),
    );

    await SystemProxy.load();
    expect(SystemProxy.authority, isNull);
  });
}
