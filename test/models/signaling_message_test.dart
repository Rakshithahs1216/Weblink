import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:weblink/models/signaling_message.dart';

void main() {
  test('offer is encoded per contract', () {
    expect(jsonDecode(const OfferMessage('v=0...').encode()), {
      'type': 'offer',
      'sdp': 'v=0...',
    });
  });

  test('ice candidates use snake_case sdp_mid / sdp_m_line_index', () {
    const message = IceMessage(
      IceCandidateData(
        candidate: 'candidate:1 1 UDP 2122252543 10.0.0.2 54321 typ host',
        sdpMid: '0',
        sdpMLineIndex: 0,
      ),
    );
    expect(jsonDecode(message.encode()), {
      'type': 'ice',
      'candidate': {
        'candidate': 'candidate:1 1 UDP 2122252543 10.0.0.2 54321 typ host',
        'sdp_mid': '0',
        'sdp_m_line_index': 0,
      },
    });
  });

  test('bye is encoded per contract', () {
    expect(const ByeMessage().encode(), '{"type":"bye"}');
  });

  test('parses server answer, ice and error messages', () {
    final answer = SignalingMessage.parse('{"type":"answer","sdp":"v=0"}');
    expect(answer, isA<AnswerMessage>());
    expect((answer as AnswerMessage).sdp, 'v=0');

    final ice = SignalingMessage.parse(
      '{"type":"ice","candidate":{"candidate":"c","sdp_mid":null,'
      '"sdp_m_line_index":null}}',
    );
    expect(ice, isA<IceMessage>());
    final candidate = (ice as IceMessage).candidate;
    expect(candidate.candidate, 'c');
    expect(candidate.sdpMid, isNull);
    expect(candidate.sdpMLineIndex, isNull);

    final error = SignalingMessage.parse('{"type":"error","message":"boom"}');
    expect((error as ErrorMessage).message, 'boom');
  });

  test('malformed frames become UnknownSignalingMessage', () {
    expect(SignalingMessage.parse('nope'), isA<UnknownSignalingMessage>());
    expect(
      SignalingMessage.parse('{"type":"answer"}'),
      isA<UnknownSignalingMessage>(),
    );
    expect(
      SignalingMessage.parse('{"type":"wat"}'),
      isA<UnknownSignalingMessage>(),
    );
  });
}
