import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vnt_app/chat/chat_audio_service.dart';

class _FakeChatAudioBackend implements ChatAudioBackend {
  @override
  ChatAudioCapabilities capabilities = const ChatAudioCapabilities(
    voiceNotes: true,
    directCalls: true,
    channelPtt: true,
    headsetRecommended: true,
  );

  @override
  bool isIncomingStreamPlaying = false;

  @override
  bool isStreamingMic = false;

  @override
  bool isVoicePlaying = false;

  @override
  bool isVoiceRecording = false;

  @override
  String? lastError;

  @override
  int? liveInputSampleRate = 48000;

  @override
  int? liveOutputSampleRate = 48000;

  @override
  String get name => 'fake';

  @override
  String get preferredVoiceCodecLabel => 'wav/pcm16/mono/16khz';

  @override
  String get preferredVoiceFileExtension => '.wav';

  int voiceNoteStartCalls = 0;
  int micStartCalls = 0;
  int playbackCalls = 0;

  @override
  Future<void> cancelVoiceNoteRecording() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> init() async {}

  @override
  Future<void> playIncomingPcm(Uint8List bytes) async {}

  @override
  Future<void> playVoiceFile(String filePath) async {
    playbackCalls++;
  }

  @override
  Future<void> startIncomingStreamPlayback() async {
    isIncomingStreamPlaying = true;
  }

  @override
  Future<void> startMicrophoneStream(
    void Function(Uint8List bytes) onAudioBytes,
  ) async {
    micStartCalls++;
    isStreamingMic = true;
  }

  @override
  Future<void> startVoiceNoteRecording(String targetPath) async {
    voiceNoteStartCalls++;
    isVoiceRecording = true;
  }

  @override
  Future<void> stopIncomingStreamPlayback() async {
    isIncomingStreamPlaying = false;
  }

  @override
  Future<void> stopMicrophoneStream() async {
    isStreamingMic = false;
  }

  @override
  Future<String?> stopVoiceNoteRecording() async {
    isVoiceRecording = false;
    return 'voice.wav';
  }

  @override
  Future<void> stopVoicePlayback() async {
    isVoicePlaying = false;
  }
}

void main() {
  group('ChatAudioService', () {
    tearDown(() {
      ChatAudioService.resetForTest(backend: _FakeChatAudioBackend());
    });

    test('delegates to backend and exposes wav defaults', () async {
      final backend = _FakeChatAudioBackend();
      ChatAudioService.resetForTest(backend: backend);
      final service = ChatAudioService.instance;

      expect(service.preferredVoiceFileExtension, '.wav');
      expect(service.preferredVoiceCodecLabel, 'wav/pcm16/mono/16khz');
      expect(service.headsetRecommended, isTrue);

      await service.startVoiceNoteRecording('voice.wav');
      expect(backend.voiceNoteStartCalls, 1);

      await service.startMicrophoneStream((_) {});
      expect(backend.micStartCalls, 1);

      await service.playVoiceFile('voice.wav');
      expect(backend.playbackCalls, 1);
    });

    test('returns backend user message for audio exceptions', () {
      final backend = _FakeChatAudioBackend();
      ChatAudioService.resetForTest(backend: backend);
      final service = ChatAudioService.instance;

      const error = ChatAudioException(
        code: 'MIC_PERMISSION',
        message: 'raw',
        userMessage: '请打开麦克风权限',
      );

      expect(
        service.userMessageForError(error, action: '接听语音'),
        '请打开麦克风权限',
      );
    });
  });
}
