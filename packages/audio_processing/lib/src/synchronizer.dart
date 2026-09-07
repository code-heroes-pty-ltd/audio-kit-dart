import 'dart:collection';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';

/// One fixed-duration timeline block containing every configured track.
///
/// Missing samples are represented as zeroes and marked with an
/// [AudioDiscontinuity] on that track's frame. No chronological merge happens
/// implicitly: callers must opt into this synchronizer.
final class SynchronizedAudioBlock {
  SynchronizedAudioBlock({
    required this.sequence,
    required this.timestamp,
    required this.format,
    required Map<String, AudioFrame> frames,
  }) : frames = UnmodifiableMapView<String, AudioFrame>(
         Map<String, AudioFrame>.of(frames),
       );

  /// Monotonically increasing block sequence.
  final int sequence;

  /// Common monotonic timestamp of the block's first sample frame.
  final Duration timestamp;

  /// Common format shared by every track frame.
  final AudioFormat format;

  /// Track ID to aligned frame. Every configured track is present.
  final Map<String, AudioFrame> frames;

  /// Number of sample frames in this block.
  int get frameCount => frames.values.first.frameCount;
}

/// Raised when bounded timeline alignment cannot continue safely.
final class AudioSynchronizationFailure implements Exception {
  const AudioSynchronizationFailure({
    required this.code,
    required this.message,
    this.trackId,
  });

  /// Stable machine-readable failure code.
  final String code;

  /// Safe diagnostic message.
  final String message;

  /// Track involved in the failure, when applicable.
  final String? trackId;

  @override
  String toString() =>
      'AudioSynchronizationFailure(code: $code, trackId: $trackId, '
      'message: $message)';
}

/// Aligns independent tracks onto explicit fixed-size timeline blocks.
///
/// Frames must share one monotonic [AudioFrame.clockId]. Timestamp alignment
/// is used for the first frame (and after discontinuities); contiguous
/// [AudioFrame.sampleOffset] deltas preserve exact sample continuity
/// afterwards. A bounded lateness window prevents one silent track from
/// blocking every other track indefinitely.
final class AudioTimelineSynchronizer {
  AudioTimelineSynchronizer({
    required this.format,
    required Set<String> trackIds,
    required this.blockFrameCount,
    this.maxLatenessBlocks = 2,
    this.maxTimelineGapBlocks = 256,
    this.maxBufferedBlocks = 512,
  }) : trackIds = Set<String>.unmodifiable(trackIds) {
    if (trackIds.isEmpty) {
      throw ArgumentError.value(trackIds, 'trackIds', 'Must not be empty.');
    }
    if (trackIds.any((String id) => id.trim().isEmpty)) {
      throw ArgumentError.value(
        trackIds,
        'trackIds',
        'Track IDs must not be empty.',
      );
    }
    if (blockFrameCount <= 0) {
      throw ArgumentError.value(
        blockFrameCount,
        'blockFrameCount',
        'Must be positive.',
      );
    }
    if (maxLatenessBlocks < 0) {
      throw ArgumentError.value(
        maxLatenessBlocks,
        'maxLatenessBlocks',
        'Must not be negative.',
      );
    }
    if (maxTimelineGapBlocks < 0) {
      throw ArgumentError.value(
        maxTimelineGapBlocks,
        'maxTimelineGapBlocks',
        'Must not be negative.',
      );
    }
    if (maxBufferedBlocks <= 0) {
      throw ArgumentError.value(
        maxBufferedBlocks,
        'maxBufferedBlocks',
        'Must be positive.',
      );
    }
    if (maxBufferedBlocks < maxLatenessBlocks + 1) {
      throw ArgumentError.value(
        maxBufferedBlocks,
        'maxBufferedBlocks',
        'Must accommodate the configured lateness window.',
      );
    }
    for (final String trackId in trackIds) {
      _tracks[trackId] = _TrackTimeline();
    }
  }

  /// Fixed format accepted from every track.
  final AudioFormat format;

  /// Required logical tracks.
  final Set<String> trackIds;

  /// Number of sample frames in each emitted block.
  final int blockFrameCount;

  /// Blocks one track may trail the global watermark before silence is used.
  final int maxLatenessBlocks;

  /// Largest accepted distance from the next output block to an input block.
  ///
  /// This fails a corrupted or reset timeline before the synchronizer
  /// materializes a potentially enormous run of silence. A legitimate clock
  /// reset must be handled by starting a new synchronizer.
  final int maxTimelineGapBlocks;

  /// Maximum number of timeline block positions materialized at once.
  ///
  /// Every position holds at most one fixed-size PCM block per configured
  /// track. Frames spanning more positions than this limit fail before any
  /// samples are copied, which bounds additional PCM memory.
  final int maxBufferedBlocks;

  final Map<String, _TrackTimeline> _tracks = <String, _TrackTimeline>{};
  final Map<int, Map<String, _TrackBlock>> _blocks =
      <int, Map<String, _TrackBlock>>{};
  String? _clockId;
  int? _originBlockIndex;
  int? _nextBlockIndex;
  int? _lastEmittedBlockIndex;
  int? _globalLatestEnd;
  bool _flushed = false;

  /// Adds one source frame and returns every block newly safe to emit.
  List<SynchronizedAudioBlock> add(AudioFrame frame) {
    if (_flushed) {
      throw StateError('Cannot add frames after flush.');
    }
    if (frame.format != format) {
      throw ArgumentError.value(
        frame.format,
        'frame',
        'Frame format must match $format.',
      );
    }
    final _TrackTimeline? track = _tracks[frame.trackId];
    if (track == null) {
      throw ArgumentError.value(
        frame.trackId,
        'frame',
        'Frame track is not configured.',
      );
    }
    if (track.ended) {
      throw AudioSynchronizationFailure(
        code: 'track_already_ended',
        trackId: frame.trackId,
        message: 'A frame arrived after the track ended.',
      );
    }
    final String? establishedClock = _clockId;
    if (establishedClock != null && establishedClock != frame.clockId) {
      throw AudioSynchronizationFailure(
        code: 'clock_domain_mismatch',
        trackId: frame.trackId,
        message: 'Tracks require an explicit clock-domain conversion.',
      );
    }
    final int timestampSample = _durationToSample(frame.timestamp);
    final bool resetAnchor =
        track.anchorSample == null ||
        frame.discontinuity != null ||
        track.sourceId != frame.sourceId ||
        track.clockId != frame.clockId;
    final int anchorSample = resetAnchor
        ? timestampSample
        : track.anchorSample!;
    final int anchorOffset = resetAnchor
        ? frame.sampleOffset
        : track.anchorOffset!;
    final int absoluteStart = anchorSample + frame.sampleOffset - anchorOffset;
    final int absoluteEnd = absoluteStart + frame.frameCount;
    if (track.latestEnd != null && absoluteStart < track.latestEnd!) {
      throw AudioSynchronizationFailure(
        code: 'overlapping_frame',
        trackId: frame.trackId,
        message: 'A frame overlaps audio already accepted for this track.',
      );
    }

    final int firstBlock = absoluteStart ~/ blockFrameCount;
    final int lastBlock = (absoluteEnd - 1) ~/ blockFrameCount;
    _validateAdmission(
      trackId: frame.trackId,
      firstBlock: firstBlock,
      lastBlock: lastBlock,
    );
    final int? nextBlock = _nextBlockIndex;
    if (nextBlock != null && firstBlock < nextBlock) {
      if (_lastEmittedBlockIndex == null) {
        // Callback order does not define chronology. Until the first aligned
        // block is actually emitted, an earlier track may move the buffered
        // origin backwards without making already-observed output stale.
        _originBlockIndex = firstBlock;
        _nextBlockIndex = firstBlock;
      } else {
        throw AudioSynchronizationFailure(
          code: 'late_frame',
          trackId: frame.trackId,
          message: 'A frame arrived after its timeline block was emitted.',
        );
      }
    }
    _originBlockIndex = _originBlockIndex == null
        ? firstBlock
        : _minimum(_originBlockIndex!, firstBlock);
    _nextBlockIndex ??= firstBlock;
    _clockId ??= frame.clockId;
    if (resetAnchor) {
      track
        ..anchorSample = anchorSample
        ..anchorOffset = anchorOffset
        ..sourceId = frame.sourceId
        ..clockId = frame.clockId;
    }

    var sourceFrameOffset = 0;
    for (
      var blockIndex = firstBlock;
      blockIndex <= lastBlock;
      blockIndex += 1
    ) {
      final int blockStart = blockIndex * blockFrameCount;
      final int destinationStart = absoluteStart > blockStart
          ? absoluteStart - blockStart
          : 0;
      final int copyFrames = _minimum(
        frame.frameCount - sourceFrameOffset,
        blockFrameCount - destinationStart,
      );
      final Map<String, _TrackBlock> blockTracks = _blocks.putIfAbsent(
        blockIndex,
        () => <String, _TrackBlock>{},
      );
      final _TrackBlock block = blockTracks.putIfAbsent(
        frame.trackId,
        () => _TrackBlock(format, blockFrameCount),
      );
      block.write(
        frame: frame,
        sourceFrameOffset: sourceFrameOffset,
        destinationFrameOffset: destinationStart,
        frameCount: copyFrames,
      );
      sourceFrameOffset += copyFrames;
    }

    track.latestEnd = absoluteEnd;
    _globalLatestEnd = _maximum(_globalLatestEnd, absoluteEnd);
    return _drainReady();
  }

  void _validateAdmission({
    required String trackId,
    required int firstBlock,
    required int lastBlock,
  }) {
    final int? nextBlock = _nextBlockIndex;
    if (nextBlock != null) {
      final int distance = (firstBlock - nextBlock).abs();
      if (distance > maxTimelineGapBlocks) {
        throw AudioSynchronizationFailure(
          code: 'timeline_gap_exceeded',
          trackId: trackId,
          message: 'The frame exceeds the configured timeline gap limit.',
        );
      }
    }

    final int incomingBlockCount = lastBlock - firstBlock + 1;
    if (incomingBlockCount > maxBufferedBlocks) {
      throw AudioSynchronizationFailure(
        code: 'frame_exceeds_buffer_limit',
        trackId: trackId,
        message: 'The frame exceeds the configured synchronization buffer.',
      );
    }
    var newBlockCount = incomingBlockCount;
    for (final int blockIndex in _blocks.keys) {
      if (blockIndex >= firstBlock && blockIndex <= lastBlock) {
        newBlockCount -= 1;
      }
    }
    if (_blocks.length + newBlockCount > maxBufferedBlocks) {
      throw AudioSynchronizationFailure(
        code: 'synchronizer_buffer_overflow',
        trackId: trackId,
        message: 'The bounded synchronization buffer is full.',
      );
    }
  }

  /// Marks one track complete and emits blocks no longer waiting on it.
  List<SynchronizedAudioBlock> endTrack(String trackId) {
    if (_flushed) {
      return const <SynchronizedAudioBlock>[];
    }
    final _TrackTimeline? track = _tracks[trackId];
    if (track == null) {
      throw ArgumentError.value(trackId, 'trackId', 'Track is not configured.');
    }
    track.ended = true;
    return _drainReady();
  }

  /// Ends every track and emits all remaining partial blocks with silence.
  List<SynchronizedAudioBlock> flush() {
    if (_flushed) {
      return const <SynchronizedAudioBlock>[];
    }
    _flushed = true;
    for (final _TrackTimeline track in _tracks.values) {
      track.ended = true;
    }
    return _drainReady(force: true);
  }

  List<SynchronizedAudioBlock> _drainReady({bool force = false}) {
    final List<SynchronizedAudioBlock> output = <SynchronizedAudioBlock>[];
    final int? initialBlock = _nextBlockIndex;
    final int? globalEnd = _globalLatestEnd;
    if (initialBlock == null || globalEnd == null) {
      return output;
    }
    var next = initialBlock;
    final int finalKnownBlock = (globalEnd - 1) ~/ blockFrameCount;
    while (next <= finalKnownBlock && (force || _isReady(next))) {
      output.add(_takeBlock(next));
      _lastEmittedBlockIndex = next;
      next += 1;
      _nextBlockIndex = next;
    }

    final int retainedBlocks = finalKnownBlock - next + 1;
    final int maximumRetained = maxLatenessBlocks + 1;
    if (!force && retainedBlocks > maximumRetained) {
      throw const AudioSynchronizationFailure(
        code: 'synchronizer_overflow',
        message: 'The bounded synchronization window overflowed.',
      );
    }
    return output;
  }

  bool _isReady(int blockIndex) {
    final int blockEnd = (blockIndex + 1) * blockFrameCount;
    final int latenessBoundary = blockEnd + maxLatenessBlocks * blockFrameCount;
    final int globalEnd = _globalLatestEnd ?? 0;
    for (final _TrackTimeline track in _tracks.values) {
      if (track.ended || (track.latestEnd ?? -1) >= blockEnd) {
        continue;
      }
      if (globalEnd >= latenessBoundary) {
        continue;
      }
      return false;
    }
    return true;
  }

  SynchronizedAudioBlock _takeBlock(int blockIndex) {
    final Map<String, _TrackBlock> available =
        _blocks.remove(blockIndex) ?? <String, _TrackBlock>{};
    final int origin = _originBlockIndex ?? blockIndex;
    final int relativeSequence = blockIndex - origin;
    final int relativeSampleOffset = relativeSequence * blockFrameCount;
    final Duration timestamp = format.durationForFrames(
      blockIndex * blockFrameCount,
    );
    final Map<String, AudioFrame> frames = <String, AudioFrame>{};
    for (final String trackId in trackIds) {
      final _TrackTimeline timeline = _tracks[trackId]!;
      final _TrackBlock block =
          available[trackId] ?? _TrackBlock(format, blockFrameCount);
      final int missing = block.missingFrameCount;
      frames[trackId] = AudioFrame.owned(
        format: format,
        samples: block.samples,
        sourceId:
            block.sourceId ?? timeline.sourceId ?? 'synchronizer.$trackId',
        trackId: trackId,
        clockId: timeline.clockId ?? _clockId ?? 'synchronizer.timeline',
        sequence: relativeSequence,
        sampleOffset: relativeSampleOffset,
        timestamp: timestamp,
        discontinuity: _materializedDiscontinuity(
          block.discontinuity,
          missingFrameCount: missing,
        ),
      );
    }
    return SynchronizedAudioBlock(
      sequence: relativeSequence,
      timestamp: timestamp,
      format: format,
      frames: frames,
    );
  }

  AudioDiscontinuity? _materializedDiscontinuity(
    AudioDiscontinuity? input, {
    required int missingFrameCount,
  }) {
    if (input == null && missingFrameCount == 0) {
      return null;
    }
    return AudioDiscontinuity(
      reason: input?.reason ?? AudioDiscontinuityReason.unknown,
      previousSequence: input?.previousSequence,
      description: missingFrameCount == 0
          ? 'The synchronizer normalized a source discontinuity onto its '
                'materialized output timeline.'
          : 'The synchronizer materialized $missingFrameCount unavailable '
                'sample frames as silence.',
    );
  }

  /// Timestamp of the first block this timeline has not yet emitted, or null
  /// before anything has been emitted.
  ///
  /// A frame that lands before this is rejected as `late_frame`, because the
  /// audio it belongs beside has already been written. Exposing the boundary
  /// lets a caller place such a frame at the head — misaligned by less than one
  /// block — instead of discarding it. Dropping is the costlier choice: the
  /// head only moves forward, so a track that falls behind it stays behind it,
  /// and one late frame silently ends the recording of that source.
  Duration? get nextBlockStart {
    final int? nextBlock = _nextBlockIndex;
    if (nextBlock == null) {
      return null;
    }
    return _sampleToDuration(nextBlock * blockFrameCount);
  }

  Duration _sampleToDuration(int sample) => Duration(
    microseconds:
        (sample * Duration.microsecondsPerSecond) ~/ format.sampleRate,
  );

  int _durationToSample(Duration duration) =>
      ((duration.inMicroseconds * format.sampleRate) +
          (Duration.microsecondsPerSecond ~/ 2)) ~/
      Duration.microsecondsPerSecond;
}

final class _TrackTimeline {
  int? anchorSample;
  int? anchorOffset;
  int? latestEnd;
  String? sourceId;
  String? clockId;
  bool ended = false;
}

final class _TrackBlock {
  _TrackBlock(AudioFormat format, int frameCount)
    : _channels = format.channels,
      samples = Float32List(frameCount * format.channels),
      _coverage = Uint8List(frameCount);

  final int _channels;
  final Uint8List _coverage;
  final Float32List samples;
  String? sourceId;
  AudioDiscontinuity? discontinuity;

  int get missingFrameCount {
    var missing = 0;
    for (final int value in _coverage) {
      if (value == 0) {
        missing += 1;
      }
    }
    return missing;
  }

  void write({
    required AudioFrame frame,
    required int sourceFrameOffset,
    required int destinationFrameOffset,
    required int frameCount,
  }) {
    for (var index = 0; index < frameCount; index += 1) {
      final int destinationFrame = destinationFrameOffset + index;
      if (_coverage[destinationFrame] != 0) {
        throw AudioSynchronizationFailure(
          code: 'overlapping_frame',
          trackId: frame.trackId,
          message: 'Two frames occupy the same synchronized sample range.',
        );
      }
      _coverage[destinationFrame] = 1;
      final int sourceSample = (sourceFrameOffset + index) * _channels;
      final int destinationSample = destinationFrame * _channels;
      for (var channel = 0; channel < _channels; channel += 1) {
        samples[destinationSample + channel] =
            frame.samples[sourceSample + channel];
      }
    }
    sourceId ??= frame.sourceId;
    discontinuity ??= frame.discontinuity;
  }
}

int _minimum(int left, int right) => left < right ? left : right;

int _maximum(int? left, int right) =>
    left == null || right > left ? right : left;
