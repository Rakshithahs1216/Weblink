import 'dart:convert';

/// An ICE candidate as it travels over the signaling socket. Field names are
/// snake_case per ARCHITECTURE.md §3 (`sdp_mid`, `sdp_m_line_index`).
class IceCandidateData {
  const IceCandidateData({
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });

  factory IceCandidateData.fromJson(Map<String, dynamic> json) {
    final candidate = json['candidate'];
    if (candidate is! String) {
      throw const FormatException('ICE candidate is missing "candidate"');
    }
    final index = json['sdp_m_line_index'];
    return IceCandidateData(
      candidate: candidate,
      sdpMid: json['sdp_mid'] as String?,
      sdpMLineIndex: index is num ? index.toInt() : null,
    );
  }

  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;

  Map<String, dynamic> toJson() => {
    'candidate': candidate,
    'sdp_mid': sdpMid,
    'sdp_m_line_index': sdpMLineIndex,
  };
}

/// Messages exchanged on `/ws/signaling`.
sealed class SignalingMessage {
  const SignalingMessage();

  Map<String, dynamic> toJson();

  String encode() => jsonEncode(toJson());

  /// Parses a text frame. Unrecognised or malformed frames become
  /// [UnknownSignalingMessage] instead of throwing.
  static SignalingMessage parse(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return UnknownSignalingMessage(raw);
      final type = json['type'];
      switch (type) {
        case 'offer':
          return OfferMessage(json['sdp'] as String);
        case 'answer':
          return AnswerMessage(json['sdp'] as String);
        case 'ice':
          return IceMessage(
            IceCandidateData.fromJson(
              json['candidate'] as Map<String, dynamic>,
            ),
          );
        case 'bye':
          return const ByeMessage();
        case 'error':
          return ErrorMessage(json['message']?.toString() ?? 'Unknown error');
      }
    } on FormatException {
      // fall through
    } on TypeError {
      // a field had the wrong type – treat as unknown
    }
    return UnknownSignalingMessage(raw);
  }
}

class OfferMessage extends SignalingMessage {
  const OfferMessage(this.sdp);
  final String sdp;

  @override
  Map<String, dynamic> toJson() => {'type': 'offer', 'sdp': sdp};
}

class AnswerMessage extends SignalingMessage {
  const AnswerMessage(this.sdp);
  final String sdp;

  @override
  Map<String, dynamic> toJson() => {'type': 'answer', 'sdp': sdp};
}

class IceMessage extends SignalingMessage {
  const IceMessage(this.candidate);
  final IceCandidateData candidate;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'ice',
    'candidate': candidate.toJson(),
  };
}

class ByeMessage extends SignalingMessage {
  const ByeMessage();

  @override
  Map<String, dynamic> toJson() => {'type': 'bye'};
}

class ErrorMessage extends SignalingMessage {
  const ErrorMessage(this.message);
  final String message;

  @override
  Map<String, dynamic> toJson() => {'type': 'error', 'message': message};
}

class UnknownSignalingMessage extends SignalingMessage {
  const UnknownSignalingMessage(this.raw);
  final String raw;

  @override
  Map<String, dynamic> toJson() => {'type': 'unknown', 'raw': raw};
}
