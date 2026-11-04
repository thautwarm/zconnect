import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pp_friend/src/audio/segmenter.dart';
import 'package:pp_friend/src/brain/brain_client.dart';
import 'package:pp_friend/src/config/assistant_config.dart';
import 'package:pp_friend/src/config/fleet_store.dart';
import 'package:pp_friend/src/conversation/conversation_controller.dart';
import 'package:pp_friend/src/conversation/message.dart';
import 'package:pp_friend/src/conversation/profile_status.dart';
import 'package:pp_friend/src/storage/memory_message_store.dart';
import 'package:pp_friend/src/voice/voice_engine.dart';

import 'support/framed_brain.dart';
import 'support/voice_fakes.dart';

/// 48kHz 下 20ms 一帧。
final Uint8List _frame = Uint8List(1920);

/// 切出来的一句话。内容无所谓，要的是"有东西排进上传队列"。
SpeechSegment _segment() => SpeechSegment(
  pcm16le: Uint8List(320),
  sampleRate: fakeSileroRate,
  durationSeconds: 0.3,
);

/// 一条排队的假回复。
class _FakeReply {
  _FakeReply({
    required this.text,
    required this.sentences,
    required this.chunks,
    required this.audio,
    required this.skipped,
  });

  final String text;
  final List<String> sentences;
  final List<String> chunks;
  final List<int> audio;
  final bool skipped;
}

/// 假 brain **群**：每个档案一个。
///
/// 路由靠请求体里的 brain_id，这正是要验的东西 —— 每个档案只跟自己那个
/// brain 说话。工厂每被调用一次就造一个新的 MockClient，所以工厂调用次数
/// 等于档案个数。共用一个是错的：[BrainClient.abort] 会把底层 client 关掉
/// 重开，那会顺带打断别的档案在途的长轮询。
class _FakeBrains {
  int factoryCalls = 0;

  /// brain_id → 排着队还没发出去的回复。发完就一直"没话说"。
  final Map<String, List<_FakeReply>> replies = {};

  /// brain_id → 收到过多少次 /brain-to-human
  final Map<String, int> polls = {};

  /// brain_id → 每次 /brain-to-human 带上的 skip_before（没带就是 null）。
  final Map<String, List<int?>> skipBefore = {};

  /// 每次上行请求体，按先后顺序。
  final List<List<int>> uploads = [];

  /// 每次上行是发给哪个 brain 的。
  final List<String> uploadTargets = [];

  /// 这些 brain 的 /brain-to-human 一律回 401（token 不对）。
  final Set<String> unauthorized = {};

  /// 没消息时回一条空响应（文本长度 0），而不是 503。
  ///
  /// 503 会让轮询进入错误状态；验证"后台消息不抬 fleetRevision"时，
  /// 错误/恢复本身就会抬两次，干扰断言。空响应没有状态变化。
  bool idleAsEmpty = false;

  /// 挂住上行请求不放，用它验"排队中切档案"。
  Completer<void>? uploadGate;

  void queue(
    String brainId, {
    required String text,
    List<String>? sentences,
    List<String>? chunks,
    List<int> audio = const [],
    bool skipped = false,
  }) {
    replies
        .putIfAbsent(brainId, () => [])
        .add(
          _FakeReply(
            text: text,
            sentences: sentences ?? <String>[text],
            chunks: chunks ?? <String>[text],
            audio: audio,
            skipped: skipped,
          ),
        );
  }

  BrainClient call() {
    factoryCalls++;
    return BrainClient(client: MockClient.streaming(_handle));
  }

  Future<http.StreamedResponse> _handle(
    http.BaseRequest request,
    http.ByteStream bodyStream,
  ) async {
    final requestBytes = await bodyStream.toBytes();
    final body = msgpack.deserialize(requestBytes) as Map;
    final brainId = body['brain_id'] as String? ?? '';

    if (request.url.path.endsWith('/brain-to-human')) {
      polls[brainId] = (polls[brainId] ?? 0) + 1;
      skipBefore
          .putIfAbsent(brainId, () => <int?>[])
          .add(body['skip_before'] as int?);
      if (unauthorized.contains(brainId)) {
        return http.StreamedResponse(const Stream<List<int>>.empty(), 401);
      }
      final queue = replies[brainId];
      if (queue == null || queue.isEmpty) {
        if (idleAsEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return http.StreamedResponse(
            Stream<List<int>>.value(
              speechBody('', skipped: false, ogg: const <int>[]),
            ),
            200,
            headers: const {'content-type': 'application/octet-stream'},
          );
        }
        // 没话说。用 503 让轮询走退避分支，别空转。
        return http.StreamedResponse(const Stream<List<int>>.empty(), 503);
      }

      // 一条响应只回答一件事：没内容、一条 skipped 旧消息、或一条真回复。
      // 真回复的 body 是前导后面跟一段连续 Ogg；内容无所谓，解码交给
      // 假引擎，这里只负责把字节原样送出去。
      final next = queue.removeAt(0);
      final response = speechBody(
        next.text,
        skipped: next.skipped,
        ogg: next.skipped ? const <int>[] : next.audio,
      );

      return http.StreamedResponse(
        Stream<List<int>>.value(response),
        200,
        headers: const {'content-type': 'application/octet-stream'},
      );
    }

    uploads.add(requestBytes);
    uploadTargets.add(brainId);
    // 记完之后再挂住：请求算"已经到了服务端"，只是回包还没回来
    if (uploadGate != null) await uploadGate!.future;
    return http.StreamedResponse(
      Stream<List<int>>.value(
        msgpack.serialize(<String, dynamic>{'kind': 'text', 'text': '收到'}),
      ),
      200,
      headers: const {'content-type': 'application/msgpack'},
    );
  }
}

/// 两个档案：A 聚焦、B 在后台。
AssistantConfig _twoProfiles({bool bargeIn = false}) => AssistantConfig(
  profiles: const [
    Profile(
      id: 'p_a',
      name: 'A',
      brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: 'a'),
    ),
    Profile(
      id: 'p_b',
      name: 'B',
      brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: 'b'),
    ),
  ],
  focusedProfileId: 'p_a',
  bargeIn: bargeIn,
);

Future<ConversationController> _boot(
  _FakeBrains brains,
  FakeVoiceEngine engine,
  FakeSegmenter segmenter, {
  MemoryMessageStore? history,
  bool bargeIn = false,
  AssistantConfig? config,
  int maxOpenProfiles = 12,
  bool start = true,
}) async {
  final controller = ConversationController(
    engine: engine,
    brainFactory: brains.call,
    history: history ?? MemoryMessageStore(),
    maxOpenProfiles: maxOpenProfiles,
    segmenterFactory:
        ({required int sampleRate, required AssistantConfig config}) async {
          segmenter.sampleRates.add(sampleRate);
          return segmenter;
        },
  );
  await controller.updateConfig(config ?? _twoProfiles(bargeIn: bargeIn));
  if (start) await controller.start();
  return controller;
}

/// 三个档案：A 聚焦、B 开着、C 关着。
///
/// 用于验证"关闭且从未运行过的档案不预建 runtime"以及打开上限。
AssistantConfig _threeProfiles() => const AssistantConfig(
  profiles: [
    Profile(
      id: 'p_a',
      name: 'A',
      brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: 'a'),
    ),
    Profile(
      id: 'p_b',
      name: 'B',
      brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: 'b'),
    ),
    Profile(
      id: 'p_c',
      name: 'C',
      brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: 'c'),
      enabled: false,
    ),
  ],
  focusedProfileId: 'p_a',
);

/// 用户"说了一段够格的话"（打断要靠连续时长，一声咳嗽不算）。
Future<void> _speak(
  FakeVoiceEngine engine,
  FakeSegmenter segmenter, {
  int frames = 20,
}) async {
  segmenter.statsValue = const SegmenterStats(speaking: true, probability: 0.9);
  for (var i = 0; i < frames; i++) {
    engine.micCtrl.add(_frame);
  }
  await pumpEventQueue();
  segmenter.statsValue = SegmenterStats.idle;
}

Future<void> _settle([int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await pumpEventQueue();
  }
}

/// 等到条件成立（轮询间隔 20ms），超时才算失败。
///
/// 轮询有 500ms 退避，固定 sleep 700ms 在负载高的机器上会假失败；
/// 这里让测试跟着服务端/轮询的真实节奏走。
Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String reason = '等待条件超时',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('$reason（等了 ${timeout.inMilliseconds}ms）');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await _settle(1);
  }
  await _settle();
}

Map<String, dynamic> _body(List<int> bytes) =>
    (msgpack.deserialize(Uint8List.fromList(bytes)) as Map)
        .cast<String, dynamic>();

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('运行模型', () {
    test('每个档案拿一个自己的 brain 客户端', () async {
      final engine = FakeVoiceEngine();
      final brains = _FakeBrains();
      final controller = await _boot(brains, engine, FakeSegmenter());
      addTearDown(controller.dispose);

      expect(brains.factoryCalls, 2, reason: '共用客户端会让 abort 互相打断');
    });

    test('两个档案同时在轮询', () async {
      final engine = FakeVoiceEngine();
      final brains = _FakeBrains();
      final controller = await _boot(brains, engine, FakeSegmenter());
      addTearDown(controller.dispose);

      await _settle();

      expect(brains.polls['a'], greaterThan(0));
      expect(brains.polls['b'], greaterThan(0), reason: '后台档案也要收消息');
    });

    test('没聚焦的档案收到语音也不播，但文字进了它自己的历史', () async {
      final engine = FakeVoiceEngine();
      final brains = _FakeBrains();
      final controller = await _boot(brains, engine, FakeSegmenter());
      addTearDown(controller.dispose);

      brains.queue('b', text: 'B 说的话', audio: const [1, 2, 3, 4]);
      await _settle();

      expect(engine.playbackPushes, 0, reason: '没聚焦的档案不该出声');
      expect(
        controller.messages.map((m) => m.text),
        isNot(contains('B 说的话')),
        reason: '它是 B 的消息，不该出现在 A 的消息流里',
      );

      // 切过去就看得见 —— 只收不播，但文字一条没少
      await controller.switchProfile('p_b');
      await _settle();
      expect(controller.messages.map((m) => m.text), contains('B 说的话'));
    });

    test('聚焦的档案照常播', () async {
      final engine = FakeVoiceEngine()
        ..opusUpstream = true
        ..decodedPcm = Uint8List(2400)
        ..decodedRate = 48000;
      final brains = _FakeBrains();
      final controller = await _boot(brains, engine, FakeSegmenter());
      addTearDown(controller.dispose);

      brains.queue('a', text: 'A 说的话', audio: const [1, 2, 3, 4]);
      await _settle();

      expect(engine.playbackPushes, greaterThan(0));
      expect(controller.messages.map((m) => m.text), contains('A 说的话'));
    });

    test('关掉正在聚焦的档案，焦点挪到下一个开着的，而且它不再轮询', () async {
      final engine = FakeVoiceEngine();
      final brains = _FakeBrains();
      final controller = await _boot(brains, engine, FakeSegmenter());
      addTearDown(controller.dispose);

      await _settle();
      final strokesBefore = brains.polls['a'] ?? 0;
      expect(strokesBefore, greaterThan(0));

      final a = controller.config.profiles.firstWhere((p) => p.id == 'p_a');
      await controller.saveProfile(a.copyWith(enabled: false));
      await _settle();

      expect(controller.config.focusedProfile!.id, 'p_b');

      // 退避是 500ms 起步，所以要真的让时间过去才看得出"没再轮询"。
      // pumpEventQueue 不推时钟，这里得用真实等待。
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await _settle();

      expect(brains.polls['a'], strokesBefore, reason: '关掉的档案不该再轮询');
    });
  });

  group('轮询的生命周期', () {
    test('token 改对之后，那个档案自己就能重新连上', () async {
      final brains = _FakeBrains()..unauthorized.add('a');
      final controller = await _boot(
        brains,
        FakeVoiceEngine(),
        FakeSegmenter(),
      );
      addTearDown(controller.dispose);

      await _settle();
      final before = brains.polls['a'] ?? 0;
      expect(before, greaterThan(0), reason: '一开始是连过的');

      // 401 之后就该停手：token 错了，重试只会变成持续请求
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await _settle();
      expect(brains.polls['a'], before, reason: '鉴权失败之后不该再发请求');

      // 用户去设置页把 token 改对、保存
      brains.unauthorized.clear();
      brains.queue('a', text: '又能说话了');
      await controller.updateConfig(_twoProfiles());

      await _settle(30);
      expect(
        brains.polls['a'],
        greaterThan(before),
        reason:
            '改对 token 之后必须自己重新连上 —— 不然这个档案永远哑着，'
            '界面还写着"正在听你说"',
      );
      expect(controller.messages.last.text, '又能说话了');
    });

    test('网络一直不通时，结束对话不该被退避拖住', () async {
      // 一个回复都不排：每次 /brain-to-human 都 503，一路退避
      final brains = _FakeBrains();
      final controller = await _boot(
        brains,
        FakeVoiceEngine(),
        FakeSegmenter(),
      );
      addTearDown(controller.dispose);

      // 退避是 500 → 1000 → 2000ms…，等它睡进那个 2 秒的退避里再停
      await Future<void>.delayed(const Duration(milliseconds: 1700));

      final watch = Stopwatch()..start();
      await controller.stop();
      watch.stop();

      expect(
        watch.elapsedMilliseconds,
        lessThan(600),
        reason:
            'stop 会 await 那条轮询，退避里睡着的十几秒不该算进来 —— '
            '那期间界面卡在"请稍候…"，而且声音还没停',
      );
    });
  });

  group('离线积压', () {
    test('停着的时候积压的消息全部原样送达：文本进消息流，音频照播', () async {
      final engine = FakeVoiceEngine()..opusUpstream = true;
      final brains = _FakeBrains();
      final controller = await _boot(brains, engine, FakeSegmenter());
      addTearDown(controller.dispose);

      brains.queue('a', text: '旧消息一。');
      brains.queue('a', text: '旧消息二。');
      brains.queue('a', text: '新回复。');
      await _settle();

      expect(
        controller.messages.map((m) => m.text),
        containsAll(<String>['旧消息一。', '旧消息二。', '新回复。']),
        reason: '队列没满就该全送过来，一条都不能悄悄吞掉',
      );
      // 方案 A 一条响应一条消息，三条积压就是三次轮询。
      expect(brains.polls['a'], greaterThanOrEqualTo(3));
      expect(
        brains.skipBefore['a']!.every((value) => value == null),
        isTrue,
        reason: '客户端不再请求跳过积压，必须原样送达',
      );

      await controller.sendTestUtterance();
      await _settle();
      final body = _body(brains.uploads.single);
      expect(body.containsKey('unheard_text'), isFalse, reason: '都听到了，没有没听到的账');
    });

    test('万一服务端回了 skipped，文本也显示出来并记进没听到', () async {
      final engine = FakeVoiceEngine()..opusUpstream = true;
      final brains = _FakeBrains();
      final controller = await _boot(brains, engine, FakeSegmenter());
      addTearDown(controller.dispose);

      brains.queue('a', text: '旧消息一。', skipped: true);
      brains.queue('a', text: '新回复。');
      await _settle();

      expect(
        controller.messages.map((m) => m.text),
        containsAll(<String>['旧消息一。', '新回复。']),
        reason: '服务端即使跳过合成，文本也不能从界面上消失',
      );

      await controller.sendTestUtterance();
      await _settle();
      final body = _body(brains.uploads.single);
      expect(body['unheard_text'], '旧消息一。');
    });

    test('打断之后才带 skip_before；被跳过的文本显示并记进没听到', () async {
      final engine = FakeVoiceEngine()
        ..opusUpstream = true
        ..decodedPcm = Uint8List(480000)
        ..decodedRate = 48000
        ..pushGate = Completer<void>();
      final brains = _FakeBrains();
      final controller = await _boot(brains, engine, FakeSegmenter());
      addTearDown(controller.dispose);

      // 先让它真的在播，clearPlayback 才不是空操作。
      brains.queue(
        'a',
        text: '正在说的那句。',
        sentences: const <String>['正在说的那句。'],
        audio: const <int>[1, 2, 3, 4],
      );
      await _settle();
      expect(controller.speaking, isTrue);

      // 开始对话时的请求都不该带 skip_before。
      expect(
        brains.skipBefore['a']!.every((value) => value == null),
        isTrue,
        reason: '打断之前不能跳过任何东西',
      );

      // 通知栏停止说话 / 音量减键 / 开口打断，都走这一条。
      await controller.clearPlayback();
      engine.pushGate!.complete();
      engine.pushGate = null;

      // 打断之前排队的旧消息，服务端会以 skipped 回来。
      brains.queue('a', text: '被打断后排队的旧消息。', skipped: true);
      brains.queue('a', text: '打断之后的新回复。');
      await _settle();

      final vod = brains.skipBefore['a']!;
      expect(vod.whereType<int>(), isNotEmpty, reason: '打断之后的请求要带水位');
      expect(vod.last, isNull, reason: '拿到真回复之后水位要清掉');

      expect(
        controller.messages.map((m) => m.text),
        containsAll(<String>['被打断后排队的旧消息。', '打断之后的新回复。']),
        reason: '被 skip 的文本也必须显示出来',
      );

      await controller.sendTestUtterance();
      await _settle();
      final body = _body(brains.uploads.single);
      expect(
        body['unheard_text'],
        contains('被打断后排队的旧消息。'),
        reason: '没合成的文字要回报给 brain',
      );
    });
  });

  group('切换档案', () {
    test('正在播的声音立刻停', () async {
      final engine = FakeVoiceEngine()
        ..opusUpstream = true
        // 长一点，让推送分成好几块
        ..decodedPcm = Uint8List(480000)
        ..decodedRate = 48000
        ..pushGate = Completer<void>();
      final brains = _FakeBrains();
      final controller = await _boot(brains, engine, FakeSegmenter());
      addTearDown(controller.dispose);

      brains.queue('a', text: 'A 的回复', audio: const [1, 2, 3, 4]);
      await _settle();
      expect(engine.playbackPushes, greaterThan(0));
      expect(controller.speaking, isTrue);

      final flushes = engine.flushCount;
      await controller.switchProfile('p_b');

      expect(
        engine.flushCount,
        greaterThan(flushes),
        reason: '光抬 epoch 拦不住已经推进 AudioTrack 缓冲的那几百毫秒',
      );
      expect(controller.speaking, isFalse);

      engine.pushGate!.complete();
      engine.pushGate = null;
      await _settle();
    });

    test('关掉正在说话的那个档案，声音也得停，账还得记在它头上', () async {
      // 改焦点不止"滑动切换"一条路：关掉正在聚焦的档案，焦点会被挪到
      // 别人身上。以前只有滑动那条路会停播、会结账 —— 走这条路声音会
      // 接着播完，而没听完的那几句会被记到新档案头上。
      final engine = FakeVoiceEngine()
        ..opusUpstream = true
        ..decodedPcm = Uint8List(480000)
        ..decodedRate = 48000
        ..pushGate = Completer<void>();
      final brains = _FakeBrains();
      final controller = await _boot(brains, engine, FakeSegmenter());
      addTearDown(controller.dispose);

      brains.queue('a', text: 'A 的回复', audio: const [1, 2, 3, 4]);
      await _settle();
      expect(controller.speaking, isTrue);
      final flushes = engine.flushCount;

      final a = controller.config.profiles.firstWhere((p) => p.id == 'p_a');
      await controller.saveProfile(a.copyWith(enabled: false));

      expect(controller.config.focusedProfile!.id, 'p_b');
      expect(
        engine.flushCount,
        greaterThan(flushes),
        reason: '关掉正在说话的档案，它的声音必须立刻停',
      );
      expect(controller.speaking, isFalse);

      engine.pushGate!.complete();
      engine.pushGate = null;
      await _settle();
    });

    test('切走之后，还排在队里没发出去的那句不再发了', () async {
      // 留着的话，轮到它发的时候会按"当时聚焦的档案"决定发给谁 —— 新档案的
      // 历史里会凭空多出一条它没听到的"你说的话"，旧档案则永远不知道你说过。
      final brains = _FakeBrains()..uploadGate = Completer<void>();
      // 没开 opus 的话那一段在编码那一步就被丢掉了，根本走不到上传
      final engine = FakeVoiceEngine()..opusUpstream = true;
      final segmenter = FakeSegmenter();
      final controller = await _boot(brains, engine, segmenter);
      addTearDown(controller.dispose);

      // 喂一帧，让 controller 把断句回调递进来（`emit` 靠它）
      engine.micCtrl.add(_frame);
      await _settle();

      // 第一句卡在上传里（还没回来）
      segmenter.emit(_segment());
      await _settle();
      expect(brains.uploadTargets, ['a']);

      // 第二句排在队里，还没轮到它发
      segmenter.emit(_segment());
      await _settle();
      expect(controller.queuedUtterances, 1);

      await controller.switchProfile('p_b');
      await _settle();

      brains.uploadGate!.complete();
      brains.uploadGate = null;
      await _settle(20);

      expect(brains.uploadTargets, ['a'], reason: '切走之后不能再发任何东西 —— 尤其是不能发给新档案');
      expect(brains.uploadTargets, isNot(contains('b')));
      expect(controller.queuedUtterances, 0);
    });

    test('切换会换掉整屏历史', () async {
      final engine = FakeVoiceEngine();
      final brains = _FakeBrains();
      final controller = await _boot(brains, engine, FakeSegmenter());
      addTearDown(controller.dispose);

      brains.queue('a', text: 'A 的一条');
      brains.queue('b', text: 'B 的一条');
      await _settle();
      expect(controller.messages.map((m) => m.text), contains('A 的一条'));

      await controller.switchProfile('p_b');
      await _settle();

      expect(controller.messages.map((m) => m.text), contains('B 的一条'));
      expect(
        controller.messages.map((m) => m.text),
        isNot(contains('A 的一条')),
        reason: '一个档案一屏历史，不混在一起',
      );
    });

    test('不重启音频 —— 麦克风只订阅一次', () async {
      final engine = FakeVoiceEngine();
      final brains = _FakeBrains();
      final controller = await _boot(brains, engine, FakeSegmenter());
      addTearDown(controller.dispose);

      final listens = engine.micListenCount;
      await controller.switchProfile('p_b');
      await _settle();

      expect(engine.micListenCount, listens, reason: '麦克风和扬声器全机只有一份，切档案不该碰它们');
    });

    test('切到关掉的档案上会被拒绝', () async {
      final engine = FakeVoiceEngine();
      final brains = _FakeBrains();
      final controller = await _boot(brains, engine, FakeSegmenter());
      addTearDown(controller.dispose);

      final b = controller.config.profiles.firstWhere((p) => p.id == 'p_b');
      await controller.saveProfile(b.copyWith(enabled: false));
      await controller.switchProfile('p_b');

      expect(controller.config.focusedProfile!.id, 'p_a');
    });
  });

  group('「没听到」的账归属正确', () {
    test('在 A 里攒下的漏听不会报给 B，也不会丢', () async {
      final engine = FakeVoiceEngine()..opusUpstream = true;
      final brains = _FakeBrains();
      // 必须是 controller 真正在用的那一个 —— 换个新的，
      // 帧喂进去了但 statsValue 设不到它身上，打断根本不会触发。
      final segmenter = FakeSegmenter();
      final controller = await _boot(brains, engine, segmenter, bargeIn: true);
      addTearDown(controller.dispose);

      // A 正在播一条 3 秒的回复；流式解码一次吐完，客户端按 1 秒一块
      // 推进播放队列（共 3 块）。
      engine.decodedPcm = Uint8List(288000);
      engine.decodedRate = 48000;
      brains.queue(
        'a',
        text: '第一句。第二句。第三句。',
        sentences: const ['第一句。', '第二句。', '第三句。'],
        chunks: const ['第一句。', '第二句。', '第三句。'],
        audio: const [1, 2, 3, 4],
      );
      await _settle();
      expect(controller.messages.map((m) => m.text), contains('第一句。第二句。第三句。'));

      // 播到 1.5 秒时用户开口，把 A 打断
      engine.headMs = 1500;
      engine.backlogFrames = 48000;
      await _speak(engine, segmenter);
      expect(engine.flushCount, 1);

      // 切到 B，随便说一句
      await controller.switchProfile('p_b');
      await _settle();
      brains.uploads.clear();
      brains.uploadTargets.clear();
      await controller.sendTestUtterance();
      await _settle();

      expect(brains.uploadTargets.single, 'b');
      final toB = _body(brains.uploads.single);
      expect(
        toB.containsKey('unheard_text'),
        isFalse,
        reason: '那些字是 A 说的，报给 B 就成了无中生有',
      );
      expect(toB.containsKey('heard_ms'), isFalse);

      // 切回 A，同一笔账还得在 —— 切档案不该把它弄丢
      await controller.switchProfile('p_a');
      await _settle();
      brains.uploads.clear();
      brains.uploadTargets.clear();
      await controller.sendTestUtterance();
      await _settle();

      expect(brains.uploadTargets.single, 'a');
      final toA = _body(brains.uploads.single);
      expect(toA['heard_ms'], 1500);
      // 播到 1.5s：第一块整块听完，第二块听到一半（按比例往后snap到
      // 最近的断句点，算整句听完），第三块一个字都没听到。
      expect(toA['unheard_text'], '第三句。');
    });
  });

  group('历史落盘', () {
    test('重启之后消息还在（换一个 controller 读同一份历史）', () async {
      final store = MemoryMessageStore();
      final engine = FakeVoiceEngine();
      final brains = _FakeBrains();
      final first = await _boot(
        brains,
        engine,
        FakeSegmenter(),
        history: store,
      );

      brains.queue('a', text: '记住我这一句');
      await _settle();
      expect(first.messages.map((m) => m.text), contains('记住我这一句'));
      first.dispose();

      // 新 controller + 同一份存储 = 重启 App
      final second = ConversationController(
        engine: FakeVoiceEngine(),
        brainFactory: brains.call,
        history: store,
      );
      addTearDown(second.dispose);
      await second.loadConfig();
      await _settle();

      expect(
        second.messages.map((m) => m.text),
        contains('记住我这一句'),
        reason: 'loadConfig 时就要把上次的历史读回来，不用等点开始',
      );
    });

    test('停一次再开，消息不清空', () async {
      final engine = FakeVoiceEngine();
      final brains = _FakeBrains();
      final controller = await _boot(brains, engine, FakeSegmenter());
      addTearDown(controller.dispose);

      brains.queue('a', text: '聊到一半');
      await _settle();

      await controller.stop();
      await controller.start();
      await _settle();

      expect(controller.messages.map((m) => m.text), contains('聊到一半'));
    });

    test('清历史只清那个档案的', () async {
      final engine = FakeVoiceEngine();
      final brains = _FakeBrains();
      final controller = await _boot(brains, engine, FakeSegmenter());
      addTearDown(controller.dispose);

      brains.queue('a', text: 'A 的话');
      brains.queue('b', text: 'B 的话');
      await _settle();

      await controller.clearHistory('p_a');
      await _settle();

      expect(controller.messages, isEmpty);
      await controller.switchProfile('p_b');
      await _settle();
      expect(controller.messages.map((m) => m.text), contains('B 的话'));
    });
  });

  group('外部音频占用焦点', () {
    test('永久失去焦点不结束会话，麦克风改喂静音，恢复后重新收音', () async {
      final engine = FakeVoiceEngine();
      final segmenter = FakeSegmenter();
      final controller = await _boot(_FakeBrains(), engine, segmenter);
      addTearDown(controller.dispose);

      final voiced = Uint8List.fromList(List<int>.filled(1920, 7));

      engine.eventCtrl.add(
        const InterruptionBegan(transient: false, canDuck: false),
      );
      await _settle();

      expect(controller.active, isTrue, reason: '切去 B 站不该结束会话');

      engine.micCtrl.add(voiced);
      await pumpEventQueue();
      expect(
        segmenter.frames.last.every((b) => b == 0),
        isTrue,
        reason: '外部音频期间不能把视频声音当成用户说话',
      );

      engine.eventCtrl.add(const InterruptionEnded(shouldResume: true));
      await _settle();

      engine.micCtrl.add(voiced);
      await pumpEventQueue();
      expect(
        segmenter.frames.last.every((b) => b == 0),
        isFalse,
        reason: '焦点回来之后要恢复正常收音',
      );
    });

    test('暂停期间到达的回复只上屏，不播；恢复后才播', () async {
      final engine = FakeVoiceEngine()
        ..opusUpstream = true
        ..decodedPcm = Uint8List(2400)
        ..decodedRate = 48000;
      final brains = _FakeBrains();
      final controller = await _boot(brains, engine, FakeSegmenter());
      addTearDown(controller.dispose);

      engine.eventCtrl.add(
        const InterruptionBegan(transient: false, canDuck: false),
      );
      await _settle();

      brains.queue('a', text: '视频期间的消息', audio: const [1, 2, 3, 4]);
      // 等真正的丢弃发生，而不是猜轮询的退避时间。
      await _waitUntil(
        () => controller.log.any((e) => e.message.contains('这条先不播')),
        reason: '暂停期间的回复应该被丢弃',
      );

      expect(engine.playbackPushes, 0, reason: '不能盖在视频声音上');
      expect(
        controller.messages.map((m) => m.text),
        contains('视频期间的消息'),
        reason: '文字还是要上屏',
      );
      expect(
        controller.focused!.pendingUnheardText,
        contains('视频期间的消息'),
        reason: '没播出来的回复要记账，等下次上传告诉 brain',
      );

      engine.eventCtrl.add(const InterruptionEnded(shouldResume: true));
      await pumpEventQueue();
      brains.queue('a', text: '恢复后的消息', audio: const [1, 2, 3, 4]);
      await _waitUntil(() => engine.playbackPushes > 0, reason: '焦点恢复后新回复应该播放');

      expect(engine.playbackPushes, greaterThan(0));
    });

    test('失焦时原生缓冲里没播完的声音要清掉', () async {
      final engine = FakeVoiceEngine()
        ..opusUpstream = true
        ..decodedPcm = Uint8List(2400)
        ..decodedRate = 48000;
      final brains = _FakeBrains();
      final controller = await _boot(brains, engine, FakeSegmenter());
      addTearDown(controller.dispose);

      brains.queue('a', text: '正在播的一条', audio: const [1, 2, 3, 4]);
      await _waitUntil(() => engine.playbackPushes > 0, reason: '回复应该先播起来');
      await _settle();

      // Dart 侧的推送已经结束，声音还在原生 FIFO 里；统计缓存每 500ms
      // 才刷一次，这时可能还是 0。暂停不能靠缓存判断"有没有在播"。
      engine.backlogFrames = 50;
      engine.eventCtrl.add(
        const InterruptionBegan(transient: false, canDuck: false),
      );
      await _settle();

      expect(engine.flushCount, 1, reason: '失焦必须清掉原生播放缓冲');
      expect(
        controller.focused!.pendingUnheardText,
        contains('正在播的一条'),
        reason: '没听完的那条要算没听到',
      );
    });

    test('外部音频期间切出来的句子直接丢，不上传', () async {
      final engine = FakeVoiceEngine()..opusUpstream = true;
      final segmenter = FakeSegmenter();
      final controller = await _boot(_FakeBrains(), engine, segmenter);
      addTearDown(controller.dispose);

      engine.eventCtrl.add(
        const InterruptionBegan(transient: false, canDuck: false),
      );
      await _settle();

      // 先喂一帧，让 controller 把断句回调挂到 fake 上。
      engine.micCtrl.add(_frame);
      await pumpEventQueue();
      segmenter.emit(_segment());
      await _settle();

      expect(engine.encodedSampleRates, isEmpty, reason: '不能把外部声音传上去');
      expect(
        controller.log.any((e) => e.message.contains('外部音频占用中，丢掉一段')),
        isTrue,
      );
    });
  });

  group('档案开关与上限', () {
    test('关闭且从未运行过的档案不预建 runtime，打开后才建', () async {
      final brains = _FakeBrains();
      final controller = await _boot(
        brains,
        FakeVoiceEngine(),
        FakeSegmenter(),
        config: _threeProfiles(),
      );
      addTearDown(controller.dispose);

      // A、B 开着，C 关着而且从未运行过。
      expect(brains.factoryCalls, 2, reason: '关着的 C 不该白占一个 runtime');

      final opened = await controller.setProfileEnabled('p_c', true);
      expect(opened, SetProfileEnabledResult.opened);

      await _waitUntil(
        () => (brains.polls['c'] ?? 0) > 0,
        reason: '打开之后 C 应该开始轮询',
      );
      expect(brains.factoryCalls, 3, reason: '打开时才建 C 的 runtime');
    });

    test('开关只改 enabled，不改焦点', () async {
      final brains = _FakeBrains();
      final controller = await _boot(
        brains,
        FakeVoiceEngine(),
        FakeSegmenter(),
        config: _threeProfiles(),
      );
      addTearDown(controller.dispose);

      expect(controller.config.focusedProfileId, 'p_a');

      final closed = await controller.setProfileEnabled('p_b', false);
      expect(closed, SetProfileEnabledResult.closed);
      expect(controller.config.focusedProfileId, 'p_a', reason: '关 B 不该切走焦点');
      expect(
        controller.config.profiles.firstWhere((p) => p.id == 'p_b').enabled,
        isFalse,
      );

      final opened = await controller.setProfileEnabled('p_b', true);
      expect(opened, SetProfileEnabledResult.opened);
      expect(controller.config.focusedProfileId, 'p_a', reason: '开 B 也不该切走焦点');
    });

    test('重复开关返回 already，找不到返回 notFound', () async {
      final controller = await _boot(
        _FakeBrains(),
        FakeVoiceEngine(),
        FakeSegmenter(),
        config: _threeProfiles(),
      );
      addTearDown(controller.dispose);

      expect(
        await controller.setProfileEnabled('p_a', true),
        SetProfileEnabledResult.alreadyOpen,
      );
      expect(
        await controller.setProfileEnabled('p_c', false),
        SetProfileEnabledResult.alreadyClosed,
      );
      expect(
        await controller.setProfileEnabled('p_missing', true),
        SetProfileEnabledResult.notFound,
      );
    });

    test('上限只拦打开；关掉一个之后可以再开', () async {
      final controller = await _boot(
        _FakeBrains(),
        FakeVoiceEngine(),
        FakeSegmenter(),
        config: _threeProfiles(),
        maxOpenProfiles: 2,
      );
      addTearDown(controller.dispose);

      expect(controller.openProfileCount, 2);
      expect(
        await controller.setProfileEnabled('p_c', true),
        SetProfileEnabledResult.atCapacity,
      );
      expect(
        controller.config.profiles.firstWhere((p) => p.id == 'p_c').enabled,
        isFalse,
        reason: '被上限拦下时不能偷偷打开',
      );

      await controller.setProfileEnabled('p_a', false);
      expect(controller.openProfileCount, 1);
      expect(
        await controller.setProfileEnabled('p_c', true),
        SetProfileEnabledResult.opened,
      );
      expect(controller.openProfileCount, 2);
    });

    test('旧配置超过上限时加载不静默关闭，只让用户自己收敛', () async {
      const overCap = AssistantConfig(
        profiles: [
          Profile(
            id: 'p_a',
            name: 'A',
            brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: 'a'),
          ),
          Profile(
            id: 'p_b',
            name: 'B',
            brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: 'b'),
          ),
          Profile(
            id: 'p_c',
            name: 'C',
            brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: 'c'),
          ),
        ],
        focusedProfileId: 'p_a',
      );

      final controller = await _boot(
        _FakeBrains(),
        FakeVoiceEngine(),
        FakeSegmenter(),
        config: overCap,
        maxOpenProfiles: 2,
      );
      addTearDown(controller.dispose);

      expect(controller.openProfileCount, 3);
      expect(
        controller.config.profiles.every((p) => p.enabled),
        isTrue,
        reason: '加载时不能为了凑上限把用户打开的档案关掉',
      );
    });

    test('关闭且没有 runtime 的档案，清历史仍然写到盘上', () async {
      final history = MemoryMessageStore();
      await history.append('p_c', role: MessageRole.user, text: '旧消息');

      final controller = await _boot(
        _FakeBrains(),
        FakeVoiceEngine(),
        FakeSegmenter(),
        config: _threeProfiles(),
        history: history,
      );
      addTearDown(controller.dispose);

      expect(await history.loadRecent('p_c'), isNotEmpty);
      await controller.clearHistory('p_c');
      expect(
        await history.loadRecent('p_c'),
        isEmpty,
        reason: '懒建 runtime 不能让关闭档案的"清历史"静默失效',
      );
    });
  });

  group('分组', () {
    test('创建、分配、改名、移动、删除', () async {
      final controller = await _boot(
        _FakeBrains(),
        FakeVoiceEngine(),
        FakeSegmenter(),
        config: _threeProfiles(),
      );
      addTearDown(controller.dispose);

      final work = await controller.createGroup('工作');
      final home = await controller.createGroup('家庭');
      expect(controller.profileGroups.map((g) => g.name), ['工作', '家庭']);

      expect(await controller.assignProfileGroup('p_a', work.id), isTrue);
      expect(controller.groupIdOf('p_a'), work.id);

      await controller.renameGroup(work.id, '公司');
      expect(
        controller.profileGroups.firstWhere((g) => g.id == work.id).name,
        '公司',
      );

      await controller.moveGroup(home.id, 0);
      expect(controller.profileGroups.map((g) => g.id), [home.id, work.id]);

      await controller.removeGroup(work.id);
      expect(
        controller.groupIdOf('p_a'),
        isNull,
        reason: '删组后成员回到未分组，不能跟着组一起消失',
      );
      expect(controller.profileGroups.any((g) => g.id == work.id), isFalse);
    });

    test('删除档案会清掉它的分组关系，空组保留', () async {
      final controller = await _boot(
        _FakeBrains(),
        FakeVoiceEngine(),
        FakeSegmenter(),
        config: _threeProfiles(),
      );
      addTearDown(controller.dispose);

      final group = await controller.createGroup('工作');
      await controller.assignProfileGroup('p_a', group.id);
      expect(controller.groupIdOf('p_a'), group.id);

      await controller.removeProfile('p_a');

      expect(controller.groupIdOf('p_a'), isNull);
      expect(
        controller.profileGroups.any((g) => g.id == group.id),
        isTrue,
        reason: '组是用户建的，档案删光了也保留空组',
      );
    });

    test('不存在的组/档案不会假装成功', () async {
      final controller = await _boot(
        _FakeBrains(),
        FakeVoiceEngine(),
        FakeSegmenter(),
        config: _threeProfiles(),
      );
      addTearDown(controller.dispose);

      expect(await controller.assignProfileGroup('p_a', 'g_missing'), isFalse);
      expect(await controller.assignProfileGroup('p_missing', null), isFalse);
      expect(
        await controller.moveProfileToGroup('p_a', 'g_missing'),
        isFalse,
      );
      expect(
        await controller.moveProfileToGroup('p_missing', null),
        isFalse,
      );
    });

    test('拖拽落点：跨组移动并排到目标档案的位置', () async {
      final controller = await _boot(
        _FakeBrains(),
        FakeVoiceEngine(),
        FakeSegmenter(),
        config: _threeProfiles(),
      );
      addTearDown(controller.dispose);

      final work = await controller.createGroup('工作');
      final home = await controller.createGroup('家庭');
      await controller.assignProfileGroup('p_a', work.id);
      await controller.assignProfileGroup('p_b', home.id);
      expect(controller.groupIdOf('p_a'), work.id);

      // 把 A 拖到 B 上：先换到"家庭"，再排到 B 的位置。
      expect(
        await controller.moveProfileToGroup(
          'p_a',
          home.id,
          targetProfileId: 'p_b',
        ),
        isTrue,
      );
      expect(controller.groupIdOf('p_a'), home.id);
      expect(controller.config.profiles.map((p) => p.id).toList(), [
        'p_b',
        'p_a',
        'p_c',
      ]);
    });

    test('分组存进独立 key 的模型，往返后成员关系还在', () async {
      final controller = await _boot(
        _FakeBrains(),
        FakeVoiceEngine(),
        FakeSegmenter(),
        config: _threeProfiles(),
      );
      addTearDown(controller.dispose);

      final group = await controller.createGroup('工作');
      await controller.assignProfileGroup('p_b', group.id);

      // 直接读 FleetStore：验证 controller 真的把它写进了 profile_fleet_v1，
      // 而不是只改了内存。
      final stored = await FleetStore().load();
      expect(stored.groupIdOf('p_b'), group.id);
      expect(stored.sortedGroups.single.name, '工作');
    });
  });

  group('每档案状态', () {
    test('聚焦 / 打开 / 关闭三种状态各归各位', () async {
      final controller = await _boot(
        _FakeBrains(),
        FakeVoiceEngine(),
        FakeSegmenter(),
        config: _threeProfiles(),
      );
      addTearDown(controller.dispose);

      await _waitUntil(
        () => controller.profileStatuses.every(
          (s) => !s.enabled || s.authFailed || s.polling,
        ),
        reason: '开着的档案应该都进入轮询',
      );

      final Map<String, ProfileStatus> statuses = {
        for (final status in controller.profileStatuses)
          status.profile.id: status,
      };

      expect(statuses['p_a']!.focused, isTrue);
      expect(statuses['p_a']!.enabled, isTrue);
      expect(statuses['p_a']!.listening, isTrue);
      expect(statuses['p_b']!.focused, isFalse);
      expect(statuses['p_b']!.enabled, isTrue);
      expect(statuses['p_b']!.polling, isTrue);
      expect(statuses['p_c']!.focused, isFalse);
      expect(statuses['p_c']!.enabled, isFalse);
      expect(statuses['p_c']!.polling, isFalse);
      expect(statuses['p_c']!.listening, isFalse);
    });

    test('401 之后重新开始轮询会把 authFailed 复位', () async {
      final brains = _FakeBrains()..unauthorized.add('a');
      final controller = await _boot(
        brains,
        FakeVoiceEngine(),
        FakeSegmenter(),
        config: _threeProfiles(),
      );
      addTearDown(controller.dispose);

      await _waitUntil(
        () => controller.profileStatuses
            .firstWhere((s) => s.profile.id == 'p_a')
            .authFailed,
        reason: '401 之后该记下鉴权失败',
      );

      brains.unauthorized.clear();
      await controller.updateConfig(_threeProfiles());

      await _waitUntil(
        () => !controller.profileStatuses
            .firstWhere((s) => s.profile.id == 'p_a')
            .authFailed,
        reason: 'token 改对、重新轮询之后，卡片不能还写着 token 无效',
      );
    });

    test('开关和分组变化会抬 fleetRevision', () async {
      final controller = await _boot(
        _FakeBrains(),
        FakeVoiceEngine(),
        FakeSegmenter(),
        config: _threeProfiles(),
      );
      addTearDown(controller.dispose);

      var bumps = 0;
      controller.fleetRevision.addListener(() => bumps++);

      final beforeSwitch = bumps;
      await controller.setProfileEnabled('p_b', false);
      expect(bumps, greaterThan(beforeSwitch));

      final beforeGroup = bumps;
      await controller.createGroup('工作');
      expect(bumps, greaterThan(beforeGroup));
    });

    test('后台消息的 record 不会抬 fleetRevision', () async {
      final history = MemoryMessageStore();
      final brains = _FakeBrains()..idleAsEmpty = true;
      final controller = await _boot(
        brains,
        FakeVoiceEngine(),
        FakeSegmenter(),
        config: _threeProfiles(),
        history: history,
      );
      addTearDown(controller.dispose);
      await _settle();

      var bumps = 0;
      controller.fleetRevision.addListener(() => bumps++);
      final before = bumps;

      brains.queue('b', text: '后台来的一条');
      for (var i = 0; i < 50; i++) {
        if ((await history.loadRecent('p_b')).isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await _settle(1);
      }
      await _settle(20);

      expect(bumps, before, reason: 'grid 不应该被后台消息的内容刷屏重建');
      expect(
        (await history.loadRecent('p_b')).map((m) => m.text),
        contains('后台来的一条'),
      );
    });
  });
}
