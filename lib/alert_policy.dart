import 'detection_logic.dart';

// What an alert feels and sounds like. Pure data so the design can be unit
// tested and reasoned about apart from the phone hardware. See
// docs/alert_design.md for the rationale behind every number here.

class HapticSpec {
  const HapticSpec({required this.pattern, required this.amplitudes, required this.description});

  /// Android vibration pattern: [delay, on, off, on, ...] in milliseconds.
  final List<int> pattern;

  /// Strength (1-255) for each pattern segment, 0 for the off segments.
  final List<int> amplitudes;
  final String description;

  bool get isSilent => pattern.isEmpty;
  int get peakAmplitude => amplitudes.fold(0, (m, a) => a > m ? a : m);
  int get totalOnMs {
    var total = 0;
    for (var i = 1; i < pattern.length; i += 2) {
      total += pattern[i];
    }
    return total;
  }
}

class TtsSpec {
  const TtsSpec({required this.rate, required this.pitch, required this.volume});
  final double rate;
  final double pitch;
  final double volume;
}

class AlertOutput {
  const AlertOutput({
    required this.hazard,
    required this.haptic,
    required this.tts,
    required this.speech,
    required this.speak,
    this.suppressedReason,
  });

  final Candidate hazard;
  final HapticSpec haptic;
  final TtsSpec tts;
  final String speech;
  final bool speak; // false = haptic only (see suppressedReason)
  final String? suppressedReason;
}

class AlertPolicy {
  AlertPolicy({this.mediumPerMinute = 9, this.highPerMinute = 12});

  // Speech budget (utterances per rolling minute). Medium is capped below
  // high so capacity is always left for the alerts that matter; critical is
  // never limited.
  final int mediumPerMinute;
  final int highPerMinute;

  final Map<String, int> _lastDist = {};
  final Map<String, AlertTier> _lastTier = {};
  final List<DateTime> _spoken = [];

  void reset() {
    _lastDist.clear();
    _lastTier.clear();
    _spoken.clear();
  }

  /// Forget what each hazard was last announced as, but keep the speech
  /// budget. Call when something else has spoken in between (a fail-safe), so
  /// the "no change" rule cannot hide a hazard the user has not heard about
  /// since the interruption.
  void forgetAnnounced() {
    _lastDist.clear();
    _lastTier.clear();
  }

  int utterancesLastMinute(DateTime now) {
    _spoken.removeWhere((t) => now.difference(t) > const Duration(seconds: 60));
    return _spoken.length;
  }

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// Wording. Very near = urgent and distance-free (the number can't be
  /// trusted that close anyway); otherwise "Chair ahead, 8 feet."
  static String speechFor(Candidate c) {
    if (c.tag == kPathBlockedTag) return 'Path blocked ahead.';
    final label = _cap(c.label);
    if (c.tier == AlertTier.critical) {
      return c.tag == 'stairs_down' ? 'Stop. Stairs down.' : 'Stop. $label ahead.';
    }
    final side = switch (c.zone) {
      'left' => 'on your left',
      'right' => 'on your right',
      _ => null,
    };
    if (c.proximity == Proximity.veryNear) {
      return side == null ? '$label very close ahead.' : '$label very close $side.';
    }
    final dist = c.distFeet.round();
    return side == null ? '$label ahead, $dist feet.' : '$label $side, $dist feet.';
  }

  /// Tier picks the rhythm (1 / 2 / 3 pulses); proximity picks strength and
  /// how tightly the pulses are packed. Closer is always stronger.
  static HapticSpec hapticFor(AlertTier tier, Proximity p) {
    final scale = switch (p) {
      Proximity.veryNear => 1.0,
      Proximity.near => 0.75,
      Proximity.far => 0.5,
    };
    final level = switch (p) {
      Proximity.veryNear => 'STRONG',
      Proximity.near => 'MEDIUM',
      Proximity.far => 'LIGHT',
    };
    switch (tier) {
      case AlertTier.critical:
        return const HapticSpec(
          pattern: [0, 100, 60, 100, 60, 100],
          amplitudes: [0, 255, 0, 255, 0, 255],
          description: 'RAPID TRIPLE PULSE (MAX)',
        );
      case AlertTier.high:
        final on = p == Proximity.veryNear ? 300 : 220;
        final gap = p == Proximity.veryNear ? 90 : 110;
        final amp = (230 * scale).round();
        return HapticSpec(
          pattern: [0, on, gap, on],
          amplitudes: [0, amp, 0, amp],
          description: 'DOUBLE PULSE ($level)',
        );
      case AlertTier.medium:
        final on = switch (p) {
          Proximity.veryNear => 150,
          Proximity.near => 120,
          Proximity.far => 100,
        };
        final amp = (160 * scale).round();
        return HapticSpec(pattern: [0, on], amplitudes: [0, amp], description: 'SINGLE PULSE ($level)');
      case AlertTier.info:
        return const HapticSpec(pattern: [], amplitudes: [], description: 'NONE');
    }
  }

  /// Closer = faster, higher, louder.
  static TtsSpec ttsFor(AlertTier tier, Proximity p) {
    if (tier == AlertTier.critical) return const TtsSpec(rate: 0.80, pitch: 1.25, volume: 1.0);
    return switch (p) {
      Proximity.veryNear => const TtsSpec(rate: 0.80, pitch: 1.25, volume: 1.0),
      Proximity.near => const TtsSpec(rate: 0.68, pitch: 1.05, volume: 1.0),
      Proximity.far => const TtsSpec(rate: 0.58, pitch: 0.95, volume: 0.85),
    };
  }

  /// Decide what to do for one dispatched hazard. Haptics always fire (they
  /// are the quiet "still there" channel); speech is suppressed when nothing
  /// changed or when the cognitive-load budget is spent. Critical never is.
  ///
  /// [ttsBusy] = the voice is mid-sentence on something at least as important
  /// and this alert can't preempt it. It is not counted as spoken and is not
  /// marked announced, so it speaks on a later frame instead of being lost.
  AlertOutput decide(Candidate c, DateTime now, {bool ttsBusy = false}) {
    final speech = speechFor(c);
    final dist = c.distFeet.round();
    final tier = c.tier;

    String? reason;
    if (tier != AlertTier.critical) {
      final lastD = _lastDist[c.tag];
      final lastT = _lastTier[c.tag];
      if (ttsBusy) {
        reason = 'busy';
      } else if (c.tag != kPathBlockedTag && lastD != null && lastT == tier && (lastD - dist).abs() < 1) {
        // (A blocked path has no distance to compare, and it must be able to
        // repeat; its own 5 s limit and the speech budget keep it in check.)
        reason = 'no change';
      } else {
        final limit = tier == AlertTier.high ? highPerMinute : mediumPerMinute;
        if (utterancesLastMinute(now) >= limit) reason = 'budget';
      }
    }

    final speak = reason == null;
    if (speak) {
      _spoken.add(now);
      _lastDist[c.tag] = dist;
      _lastTier[c.tag] = tier;
    }

    return AlertOutput(
      hazard: c,
      haptic: hapticFor(tier, c.proximity),
      tts: ttsFor(tier, c.proximity),
      speech: speech,
      speak: speak,
      suppressedReason: reason,
    );
  }
}

/// The "Audio:" line on screen: always the last thing the app actually said
/// (or, with AUDIO off, what it would have said, marked as such). Alerts whose
/// speech was withheld never touch it, so it cannot show something stale or
/// something that was never spoken.
class SpokenLine {
  String _text = '-';
  String get text => _text;

  void record(String spoken, {required bool audible}) {
    _text = audible ? spoken : '(audio off) $spoken';
  }

  void clear() => _text = '-';
}

// ---------------------------------------------------------------------------
// Evaluation log
// ---------------------------------------------------------------------------

class LogEvent {
  const LogEvent({
    required this.tMs,
    required this.kind,
    this.tier = '',
    this.tag = '',
    this.label = '',
    this.zone = '',
    this.proximity = '',
    this.distFeet,
    this.clipped = false,
    this.conf,
    this.speech = '',
    this.spoken = false,
    this.haptic = false,
    this.reason = '',
  });

  final int tMs;
  final String kind; // alert | failsafe_on | failsafe_off
  final String tier, tag, label, zone, proximity, speech, reason;
  final double? distFeet, conf;
  final bool clipped, spoken, haptic;
}

/// Records what the app did, for measuring cognitive load and trust after a
/// session: how often it spoke, what it suppressed, how fast it responded,
/// and when it told the user it was failing.
class AlertLog {
  AlertLog({DateTime? start, this.maxEvents = 2000}) : _start = start ?? DateTime.now();

  final DateTime _start;
  final int maxEvents;
  final List<LogEvent> events = [];
  final List<int> latenciesMs = [];

  static const header = 'tMs,kind,tier,tag,label,zone,proximity,distFeet,clipped,conf,spoken,haptic,reason,speech';

  int _t(DateTime now) => now.difference(_start).inMilliseconds;

  void _add(LogEvent e) {
    events.add(e);
    if (events.length > maxEvents) events.removeAt(0);
  }

  void alert(AlertOutput out, DateTime now, {required bool hapticFired}) {
    final c = out.hazard;
    _add(LogEvent(
      tMs: _t(now),
      kind: 'alert',
      tier: c.tier.name,
      tag: c.tag,
      label: c.label,
      zone: c.zone,
      proximity: c.proximity.name,
      distFeet: c.distFeet,
      clipped: c.clipped,
      conf: c.conf,
      speech: out.speech,
      spoken: out.speak,
      haptic: hapticFired && !out.haptic.isSilent,
      reason: out.suppressedReason ?? '',
    ));
  }

  void failsafe(String name, {required bool on, required DateTime now}) {
    _add(LogEvent(tMs: _t(now), kind: on ? 'failsafe_on' : 'failsafe_off', reason: name));
  }

  void latency(int ms) {
    latenciesMs.add(ms);
    if (latenciesMs.length > maxEvents) latenciesMs.removeAt(0);
  }

  static String _csv(Object? v) {
    final s = v == null ? '' : '$v';
    return (s.contains(',') || s.contains('"') || s.contains('\n')) ? '"${s.replaceAll('"', '""')}"' : s;
  }

  String toCsv() {
    final rows = <String>[header];
    for (final e in events) {
      rows.add([
        e.tMs,
        e.kind,
        e.tier,
        e.tag,
        e.label,
        e.zone,
        e.proximity,
        e.distFeet?.toStringAsFixed(2),
        e.clipped,
        e.conf?.toStringAsFixed(2),
        e.spoken,
        e.haptic,
        e.reason,
        e.speech,
      ].map(_csv).join(','));
    }
    return rows.join('\n');
  }

  /// Most utterances in any 60 s window.
  int peakUtterancesPerMinute() {
    final times = events.where((e) => e.kind == 'alert' && e.spoken).map((e) => e.tMs).toList();
    var peak = 0;
    var lo = 0;
    for (var hi = 0; hi < times.length; hi++) {
      while (times[hi] - times[lo] > 60000) {
        lo++;
      }
      peak = peak > hi - lo + 1 ? peak : hi - lo + 1;
    }
    return peak;
  }

  int? medianLatencyMs() {
    if (latenciesMs.isEmpty) return null;
    final s = [...latenciesMs]..sort();
    return s[s.length ~/ 2];
  }

  Map<String, int> suppressionCounts() {
    final out = <String, int>{};
    for (final e in events) {
      if (e.kind == 'alert' && !e.spoken && e.reason.isNotEmpty) {
        out[e.reason] = (out[e.reason] ?? 0) + 1;
      }
    }
    return out;
  }
}
