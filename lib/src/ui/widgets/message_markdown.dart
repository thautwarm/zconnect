import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';

/// 助手消息的 Markdown 正文。
///
/// 只有 AI 的话走这里：用户的文字是语音转出来的，直接按 Markdown 解析会把
/// 他随口说的 `*`、`#` 之类当成格式，所以用户气泡仍然用 [SelectableText]。
///
/// 包本身用普通的 `Text` 渲染，选中能力由外层的 [SelectionArea] 提供：
/// 手机长按、桌面拖选/右键都走系统的选择菜单。代码块的复制按钮、链接点击
/// 也都由这个 widget 接过来，交给包内置的控件和回调。
class MessageMarkdown extends StatelessWidget {
  const MessageMarkdown({
    super.key,
    required this.data,
    required this.foreground,
  });

  /// Markdown 源文本。
  final String data;

  /// 气泡正文颜色（一般是 `onSurface`）。
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final body =
        theme.textTheme.bodyLarge?.copyWith(color: foreground) ??
        TextStyle(color: foreground);

    // GptMarkdown 不做选中，官方方式是在外面包一层 SelectionArea。
    return SelectionArea(
      child: GptMarkdown(
        data,
        style: body,
        styleSheet: _styleSheet(theme, foreground, l10n),
        onCodeCopy: (_) => _copied(context),
        onLinkTap: (url, title) {
          unawaited(_openLink(context, url));
        },
      ),
    );
  }

  /// 从主题派生样式，但正文/标题/列表/引用统一换成气泡的前景色。
  GptMarkdownStyleSheet _styleSheet(
    ThemeData theme,
    Color foreground,
    AppLocalizations l10n,
  ) {
    final text = theme.textTheme;
    final scheme = theme.colorScheme;

    // 内联代码和代码块的底色要比气泡深/浅一档，否则和背景糊在一起。
    final codeBackground = scheme.surfaceContainerLow;
    final mutedForeground = foreground.withValues(alpha: 0.7);

    return GptMarkdownStyleSheet(
      blockSpacing: 6,
      heading: HeadingStyle(
        // 包默认会在 H1 下面画一条分隔线；气泡里不需要，和切换前的排版保持一致。
        showDivider: false,
        textStyle: TextStyle(color: foreground, fontWeight: FontWeight.w600),
      ),
      link: LinkStyle(color: scheme.primary),
      list: ListStyle(
        bulletColor: foreground,
        markerTextStyle: TextStyle(color: foreground),
      ),
      inlineCode: InlineCodeStyle(
        color: foreground,
        backgroundColor: codeBackground,
        borderColor: scheme.outlineVariant,
      ),
      blockQuote: BlockQuoteStyle(
        barColor: scheme.outlineVariant,
        backgroundColor: codeBackground.withValues(alpha: 0.55),
        textStyle: TextStyle(color: foreground.withValues(alpha: 0.85)),
      ),
      codeBlock: CodeBlockStyle(
        backgroundColor: codeBackground,
        borderColor: scheme.outlineVariant,
        borderWidth: 1,
        borderRadius: const Radius.circular(10),
        textColor: foreground,
        showLanguageLabel: true,
        showCopyButton: true,
        copyLabel: l10n.copyCode,
        copiedLabel: l10n.copiedToClipboard,
        languageStyle: text.labelSmall?.copyWith(color: mutedForeground),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        headerPadding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
      ),
    );
  }

  /// 包内置的复制按钮已经写入剪贴板，这里只负责本地化反馈。
  void _copied(BuildContext context) {
    if (!context.mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).copiedToClipboard)),
      );
  }

  /// 用系统浏览器/外部应用打开链接；失败时给一句本地化提示。
  ///
  /// `Uri.tryParse` 返回 null 或 `launchUrl` 返回 false/抛异常都算失败 ——
  /// 静默失败的话用户会以为链接坏了。
  Future<void> _openLink(BuildContext context, String? href) async {
    final uri = href == null ? null : Uri.tryParse(href);
    var opened = false;
    if (uri != null) {
      try {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        opened = false;
      }
    }
    if (opened || !context.mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).linkOpenFailed)),
      );
  }
}
