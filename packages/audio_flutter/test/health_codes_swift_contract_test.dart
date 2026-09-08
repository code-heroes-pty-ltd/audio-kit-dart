import 'dart:io';

import 'package:audio_flutter/audio_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

/// The health-code constants are only worth having if they provably match
/// the strings the darwin implementation emits: a rename on either side must
/// fail here, not silently orphan a host's handler.
void main() {
  late String nativeSources;

  setUpAll(() {
    // Test runners differ on the working directory (the package when run
    // directly, the repo root under tool/verify.sh), so probe both.
    const sourcesPath =
        'audio_flutter_darwin/darwin/audio_flutter_darwin/Sources/'
        'audio_flutter_darwin';
    final darwinSources =
        [
          Directory('../$sourcesPath'),
          Directory('packages/$sourcesPath'),
        ].firstWhere(
          (candidate) => candidate.existsSync(),
          orElse: () => Directory('../$sourcesPath'),
        );
    expect(
      darwinSources.existsSync(),
      isTrue,
      reason:
          'the contract test needs the sibling darwin package checkout at '
          '${darwinSources.path}',
    );
    // Windows emits its own codes, and a constant that names one must be
    // matched against the sources that emit it. Grepping darwin alone made a
    // Windows-only code look like drift, and — worse — let a code the darwin
    // side emits go unimplemented on Windows without anything noticing.
    const windowsPath = 'audio_flutter_windows/windows';
    final windowsSources =
        [
          Directory('../$windowsPath'),
          Directory('packages/$windowsPath'),
        ].firstWhere(
          (candidate) => candidate.existsSync(),
          orElse: () => Directory('../$windowsPath'),
        );
    expect(
      windowsSources.existsSync(),
      isTrue,
      reason:
          'the contract test needs the sibling windows package checkout at '
          '${windowsSources.path}',
    );
    nativeSources = [
      ...darwinSources.listSync().whereType<File>().where(
        (file) => file.path.endsWith('.swift'),
      ),
      ...windowsSources.listSync().whereType<File>().where(
        (file) => file.path.endsWith('.cpp') || file.path.endsWith('.h'),
      ),
    ].map((file) => file.readAsStringSync()).join('\n');
  });

  test('every constant appears verbatim in a native source', () {
    for (final code in AudioCaptureHealthCodes.all) {
      expect(
        nativeSources.contains('"$code"'),
        isTrue,
        reason:
            'AudioCaptureHealthCodes declares "$code" but no native source '
            'emits it — the contract has drifted',
      );
    }
  });

  test('the classified sets are drawn from the declared codes', () {
    // A set built from a literal rather than the constants would drift
    // silently: the code would still be emitted, just never classified.
    for (final code in {
      ...AudioCaptureHealthCodes.fatal,
      ...AudioCaptureHealthCodes.deviceChange,
    }) {
      expect(
        AudioCaptureHealthCodes.all,
        contains(code),
        reason: '"$code" is classified but not declared',
      );
    }
    expect(
      AudioCaptureHealthCodes.fatal.intersection(
        AudioCaptureHealthCodes.deviceChange,
      ),
      isEmpty,
      reason: 'a code cannot both end a capture and be survivable',
    );
  });

  test('the all list carries no duplicates', () {
    expect(
      AudioCaptureHealthCodes.all.toSet().length,
      AudioCaptureHealthCodes.all.length,
    );
  });
}
