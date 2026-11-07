import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'package:pp_friend/src/ui/widgets/message_markdown.dart';

import 'support/test_app.dart';

Widget _host(String data) {
  return testApp(
    Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Builder(
          builder: (context) => MessageMarkdown(
            data: data,
            foreground: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('渲染粗体、列表和标题', (tester) async {
    await tester.pumpWidget(_host('# 标题\n\n**粗体**\n\n- 第一项\n- 第二项'));
    await tester.pump();

    expect(find.byType(GptMarkdown), findsOneWidget);
    // GptMarkdown 用 RichText（含自定义子类）排版，普通 find.text 看不到。
    expect(find.text('标题', findRichText: true), findsOneWidget);
    expect(find.text('粗体', findRichText: true), findsOneWidget);
    expect(find.text('第一项', findRichText: true), findsOneWidget);
    expect(find.text('第二项', findRichText: true), findsOneWidget);
  });

  testWidgets('代码块显示原始代码、语言标签和复制按钮', (tester) async {
    const code = 'void main() {\n  print("hi");\n}';
    await tester.pumpWidget(_host('```dart\n$code\n```'));
    await tester.pump();

    expect(find.text(code), findsOneWidget);
    expect(find.text('dart'), findsOneWidget);
    expect(find.byTooltip('复制代码'), findsOneWidget);
  });

  testWidgets('点复制按钮把原始代码写进剪贴板并提示已复制', (tester) async {
    const code = 'const x = 1;\nprint(x);';
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(_host('```dart\n$code\n```'));
    await tester.pump();

    await tester.tap(find.byTooltip('复制代码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final clipboardCalls = calls
        .where((call) => call.method == 'Clipboard.setData')
        .toList();
    expect(clipboardCalls, hasLength(1));
    expect(clipboardCalls.single.arguments, <String, Object?>{'text': code});
    expect(find.text('已复制'), findsOneWidget);

    // 包内置的复制按钮会在 2 秒后恢复图标，等它落地，避免留下 pending timer。
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
  });

  testWidgets('没有语言标注的代码块也有复制按钮', (tester) async {
    await tester.pumpWidget(_host('```\nplain\n```'));
    await tester.pump();

    expect(find.text('plain'), findsOneWidget);
    expect(find.byTooltip('复制代码'), findsOneWidget);
  });

  testWidgets('链接打不开时给出本地化提示', (tester) async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      // 模拟系统没有能打开这个链接的应用。
      if (call.method == 'launch') return false;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(_host('[链接](https://example.com)'));
    await tester.pump();

    await tester.tap(find.text('链接', findRichText: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      calls.any(
        (call) =>
            call.method == 'launch' &&
            (call.arguments as Map)['url'] == 'https://example.com',
      ),
      isTrue,
      reason: '点击链接应该交给系统外部应用打开',
    );
    expect(find.text('打不开这个链接'), findsOneWidget);
  });
}
