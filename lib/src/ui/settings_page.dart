import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../conversation/conversation_controller.dart';
import '../i18n/locale_controller.dart';
import 'onboarding_page.dart';
import 'widgets/settings_widgets.dart';

/// 设置页。
///
/// 「档案」tab 已经退役：频道编辑搬到独立的 [ChannelSettingsPage]，这里只
/// 保留全局配置 —— 断句参数、声纹、音量键、语言、权限。
///
/// 这些参数是**全局的**，不跟频道走：每个频道一套的话，切频道就得重建
/// 那个 1.26MB 的 ONNX 断句器，而切换必须是立刻的。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final ConversationController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _vadMinSilenceMs;
  late final TextEditingController _vadThreshold;
  late final TextEditingController _vadSpeechPadMs;
  late final TextEditingController _vadMinSpeechMs;
  late final TextEditingController _vadMaxSpeechS;
  late final TextEditingController _pvadMinCosine;

  @override
  void initState() {
    super.initState();
    final config = widget.controller.config;
    _vadMinSilenceMs = TextEditingController(
      text: config.vadMinSilenceMs.toString(),
    );
    _vadThreshold = TextEditingController(text: config.vadThreshold.toString());
    _vadSpeechPadMs = TextEditingController(
      text: config.vadSpeechPadMs.toString(),
    );
    _vadMinSpeechMs = TextEditingController(
      text: config.vadMinSpeechMs.toString(),
    );
    _vadMaxSpeechS = TextEditingController(
      text: config.vadMaxSpeechS.toString(),
    );
    _pvadMinCosine = TextEditingController(
      text: config.pvadMinCosine.toString(),
    );
  }

  @override
  void dispose() {
    _vadMinSilenceMs.dispose();
    _vadThreshold.dispose();
    _vadSpeechPadMs.dispose();
    _vadMinSpeechMs.dispose();
    _vadMaxSpeechS.dispose();
    _pvadMinCosine.dispose();
    super.dispose();
  }

  AppLocalizations get _l10n => AppLocalizations.of(context);

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 解析失败一律回落到默认值 —— 不该因为一个手滑的输入就保存不了。
  int _int(TextEditingController c, int fallback) =>
      int.tryParse(c.text.trim()) ?? fallback;

  double _double(TextEditingController c, double fallback) =>
      double.tryParse(c.text.trim()) ?? fallback;

  Future<void> _save() async {
    final l10n = _l10n;
    try {
      await _saveVad();
    } catch (e) {
      _toast(l10n.saveFailed('$e'));
      return;
    }
    _toast(l10n.saved);
  }

  Future<void> _saveVad() async {
    final base = widget.controller.config;
    // 只写全局参数。`copyWith` 不带 brain，档案一个都不会被动到。
    await widget.controller.updateConfig(
      base.copyWith(
        vadMinSilenceMs: _int(_vadMinSilenceMs, base.vadMinSilenceMs),
        vadThreshold: _double(
          _vadThreshold,
          base.vadThreshold,
        ).clamp(0.01, 0.99),
        vadSpeechPadMs: _int(_vadSpeechPadMs, base.vadSpeechPadMs),
        vadMinSpeechMs: _int(_vadMinSpeechMs, base.vadMinSpeechMs),
        vadMaxSpeechS: _int(_vadMaxSpeechS, base.vadMaxSpeechS).clamp(1, 600),
        pvadMinCosine: _double(
          _pvadMinCosine,
          base.pvadMinCosine,
        ).clamp(0.1, 0.9),
      ),
    );
  }

  /// 创建页要在线跑 onnxruntime-web，只能开浏览器，不能内嵌。
  /// 直接落到 /enroll/，不然用户还得在主页上再点一次。
  static const _voiceprintPageUrl =
      'https://thautwarm.github.io/zconnect/enroll/';

  Future<void> _openVoiceprintPage() async {
    final l10n = _l10n;
    try {
      final opened = await launchUrl(
        Uri.parse(_voiceprintPageUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) _toast(l10n.noAppToOpenPage);
    } catch (e) {
      _toast(l10n.openPageFailed('$e'));
    }
  }

  /// 从文件里导入声纹。只认 768 字节的 `spkemb.f32`。
  Future<void> _importVoiceprint() async {
    final l10n = _l10n;
    // 不按扩展名过滤：Android 对 `.f32` 没有标准 MIME，按 custom 过滤
    // 反而会让文件在列表里变灰。字节数校验比扩展名可靠。
    final file = await FilePicker.pickFile();
    if (file == null) return;
    final bytes = await file.readAsBytes();
    try {
      await widget.controller.importVoiceprint(bytes);
      _toast(l10n.voiceprintImported);
    } on FormatException catch (e) {
      _toast(l10n.notVoiceprint(e.message));
    } catch (e) {
      _toast(l10n.importFailed('$e'));
    }
  }

  Future<void> _removeVoiceprint() async {
    final l10n = _l10n;
    await widget.controller.removeVoiceprint();
    _toast(l10n.voiceprintRemoved);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    // 整页跟着 controller 重建：声纹导入/删除、「只有我的声音」开关都会
    // 直接改 controller 的配置，不监听的话界面会停在旧状态。
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(l10n.settingsTitle),
          actions: [TextButton(onPressed: _save, child: Text(l10n.save))],
        ),
        body: _generalTab(theme),
      ),
    );
  }

  Widget _generalTab(ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _languageSection(l10n),
        const SizedBox(height: 16),
        _permissionsEntry(theme, l10n),
        const SizedBox(height: 16),
        SettingsSection(
          title: l10n.localSegmentation,
          children: [
            Text(
              l10n.localSegmentationBody,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            SettingsTextField(
              controller: _vadMinSilenceMs,
              label: l10n.vadMinSilenceMsLabel,
              hint: l10n.vadMinSilenceMsHint,
              keyboardType: TextInputType.number,
            ),
            SettingsTextField(
              controller: _vadThreshold,
              label: l10n.vadThresholdLabel,
              hint: l10n.vadThresholdHint,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            SettingsTextField(
              controller: _vadSpeechPadMs,
              label: l10n.vadSpeechPadMsLabel,
              hint: l10n.vadSpeechPadMsHint,
              keyboardType: TextInputType.number,
            ),
            SettingsTextField(
              controller: _vadMinSpeechMs,
              label: l10n.vadMinSpeechMsLabel,
              hint: l10n.vadMinSpeechMsHint,
              keyboardType: TextInputType.number,
            ),
            SettingsTextField(
              controller: _vadMaxSpeechS,
              label: l10n.vadMaxSpeechSLabel,
              hint: l10n.vadMaxSpeechSHint,
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        const SizedBox(height: 16),
        SettingsSection(
          title: l10n.speakerRecognition,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: widget.controller.config.pvadEnabled,
              onChanged: (enabled) => widget.controller.updateConfig(
                widget.controller.config.copyWith(pvadEnabled: enabled),
              ),
              title: Text(l10n.onlyMyVoice),
              subtitle: Text(
                widget.controller.hasVoiceprint
                    ? l10n.voiceprintImportedStatus
                    : l10n.voiceprintNeeded,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _openVoiceprintPage,
                  icon: const Icon(Icons.open_in_new),
                  label: Text(l10n.openVoiceprintPage),
                ),
                OutlinedButton.icon(
                  onPressed: _importVoiceprint,
                  icon: const Icon(Icons.file_open_outlined),
                  label: Text(
                    widget.controller.hasVoiceprint
                        ? l10n.reimportVoiceprint
                        : l10n.importVoiceprint,
                  ),
                ),
                if (widget.controller.hasVoiceprint)
                  TextButton.icon(
                    onPressed: _removeVoiceprint,
                    icon: const Icon(Icons.delete_outline),
                    label: Text(l10n.deleteVoiceprint),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l10n.voiceprintOptionalHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            // 没导入声纹时这个数没有任何意义，先不占位置。
            if (widget.controller.hasVoiceprint) ...[
              const SizedBox(height: 12),
              SettingsTextField(
                controller: _pvadMinCosine,
                label: l10n.similarityThreshold,
                hint: '0.40',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        SettingsSection(
          title: l10n.volumeKeys,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: widget.controller.config.volumeKeyClearsQueue,
              onChanged: (enabled) => widget.controller.updateConfig(
                widget.controller.config.copyWith(
                  volumeKeyClearsQueue: enabled,
                ),
              ),
              title: Text(l10n.volumeKeyClearsQueue),
              subtitle: Text(l10n.volumeKeySubtitle),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _notice(theme, l10n),
      ],
    );
  }

  Widget _permissionsEntry(ThemeData theme, AppLocalizations l10n) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.verified_user_outlined),
        title: Text(l10n.permissionCheckEntry),
        subtitle: Text(l10n.permissionCheckEntrySubtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => OnboardingPage(controller: widget.controller),
          ),
        ),
      ),
    );
  }

  Widget _languageSection(AppLocalizations l10n) {
    final locale = context.watch<LocaleController>();
    return SettingsSection(
      title: l10n.languageSection,
      children: [
        DropdownButton<String>(
          value: locale.selection,
          isExpanded: true,
          items: [
            DropdownMenuItem(
              value: LocaleController.systemValue,
              child: Text(l10n.languageFollowSystem),
            ),
            DropdownMenuItem(value: 'zh', child: Text(l10n.languageChinese)),
            DropdownMenuItem(value: 'en', child: Text(l10n.languageEnglish)),
            DropdownMenuItem(value: 'ja', child: Text(l10n.languageJapanese)),
          ],
          onChanged: (value) {
            if (value != null) locale.select(value);
          },
        ),
      ],
    );
  }

  Widget _notice(ThemeData theme, AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        l10n.settingsNotice,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
