// Run the detector self-test. From the project root:
//
//   dart tools/eval/run_eval.dart --init        create the label folders
//   dart tools/eval/run_eval.dart --plan        count the API calls, make none
//   dart tools/eval/run_eval.dart               show the plan, ask, then run
//
// See tools/eval/README.md. Writes tools/eval/report.md and results.csv.
import 'dart:io';

import 'eval_core.dart';

const _usage = '''
Options:
  --init               create tools/eval/images/<label>/ folders and exit
  --plan               print how many API calls a run needs, make none, exit
  --yes                do not ask for confirmation before making live calls
  --modes M            auto (default), street, indoor, or both
  --resize N           shrink photos so the longest side is N px (default: send as-is)
  --send-upright       re-encode every photo from its decoded, already-rotated pixels so no
                       EXIF rotation tag reaches the server. The app does NOT do this today;
                       use it to test whether that matters (it costs new calls: different bytes)
  --max-calls N        refuse to run if more than N NEW live calls are needed
  --min-per-label N    photos needed per label before judging it (default $kMinPerLabel)
  --images DIR         photo folder (default tools/eval/images)
  --cache DIR          response cache (default tools/eval/cache)
  --out DIR            where report.md and results.csv go (default tools/eval)
  --help
''';

Future<void> main(List<String> args) async {
  final opts = _parse(args);
  if (opts == null || opts.containsKey('help')) {
    stdout.write(_usage);
    exit(opts == null ? 64 : 0);
  }

  final scriptDir = File.fromUri(Platform.script).parent;
  final root = scriptDir.parent.parent;
  final imagesDir = Directory(opts['images'] ?? '${scriptDir.path}${Platform.pathSeparator}images');
  final cacheDir = Directory(opts['cache'] ?? '${scriptDir.path}${Platform.pathSeparator}cache');
  final outDir = Directory(opts['out'] ?? scriptDir.path);
  final minPerLabel = int.tryParse(opts['min-per-label'] ?? '') ?? kMinPerLabel;
  final resize = int.tryParse(opts['resize'] ?? '') ?? 0;
  final upright = opts.containsKey('send-upright');
  final modes = ModesOption.values.firstWhere(
    (m) => m.name == (opts['modes'] ?? 'auto'),
    orElse: () {
      stderr.writeln('Unknown --modes value. Use auto, street, indoor or both.');
      exit(64);
    },
  );

  if (opts.containsKey('init')) {
    for (final l in kCoreLabels) {
      final d = Directory('${imagesDir.path}${Platform.pathSeparator}$l')..createSync(recursive: true);
      final keep = File('${d.path}${Platform.pathSeparator}.gitkeep');
      if (!keep.existsSync()) keep.writeAsStringSync('');
    }
    stdout.writeln('Created folders under ${imagesDir.path}: ${kCoreLabels.join(', ')}');
    stdout.writeln('Other supported labels: ${(kLabels.keys.toSet()..removeAll(kCoreLabels)).join(', ')}');
    return;
  }

  // Reading main.dart means the harness follows the app's real settings.
  final mainFile = File('${root.path}${Platform.pathSeparator}lib${Platform.pathSeparator}main.dart');
  final settings = readAppSettings(mainFile.existsSync() ? mainFile.readAsStringSync() : null);
  for (final n in settings.notes) {
    stdout.writeln('WARNING: $n');
  }

  final scan = scanImages(imagesDir, modes);
  for (final u in scan.unknownDirs) {
    stdout.writeln('WARNING: folder "$u" is not a known label and was skipped. Known: ${kLabels.keys.join(', ')}');
  }
  if (scan.strayFiles.isNotEmpty) {
    stdout.writeln('WARNING: ${scan.strayFiles.length} image file(s) sit directly in the images folder and were ignored; put them in a label folder.');
  }

  if (scan.entries.isEmpty) {
    _noImages(imagesDir, scan, modes, minPerLabel);
    outDir.createSync(recursive: true);
    File('${outDir.path}${Platform.pathSeparator}report.md').writeAsStringSync(buildNoDataReport(minPerLabel: minPerLabel));
    stdout.writeln('Wrote ${outDir.path}${Platform.pathSeparator}report.md saying no results exist.');
    exit(2);
  }

  final cache = EvalCache(cacheDir);
  stdout.writeln('Reading and preparing ${scan.entries.length} photo(s)...');
  final plan = buildPlan(scan: scan, settings: settings, cache: cache, resize: resize, upright: upright);
  stdout.write(describePlan(plan, modes, resize: resize, upright: upright));
  if (plan.unreadable > 0) {
    for (final e in plan.entries.where((e) => e.loadError != null)) {
      stdout.writeln('  unreadable: ${e.rel}: ${e.loadError}');
    }
  }
  final big = plan.entries.where((e) => e.info != null && (e.info!.width > 1600 || e.info!.height > 1600)).length;
  if (big > 0 && resize == 0) {
    stdout.writeln('NOTE: $big photo(s) are larger than 1600 px. The app sends a much smaller camera frame; '
        'consider --resize (use the "Server saw" size from the app\'s debug panel).');
  }

  if (opts.containsKey('plan')) {
    stdout.writeln('--plan: no calls made.');
    return;
  }

  final maxCalls = int.tryParse(opts['max-calls'] ?? '');
  if (maxCalls != null && plan.callsToMake > maxCalls) {
    stderr.writeln('Refusing to run: ${plan.callsToMake} new calls needed, more than --max-calls $maxCalls.');
    exit(3);
  }

  var apiKey = '';
  if (plan.callsToMake > 0) {
    if (!opts.containsKey('yes')) {
      // Anything other than an explicit "yes" typed at a real terminal counts
      // as "not confirmed". That includes the terminal being unusable.
      var answer = '';
      var asked = false;
      try {
        if (stdin.hasTerminal) {
          stdout.write('Type "yes" to make ${plan.callsToMake} live API calls: ');
          asked = true;
          answer = (stdin.readLineSync() ?? '').trim().toLowerCase();
        }
      } on StdinException {
        asked = false;
      }
      if (!asked) {
        stderr.writeln('\nThis run needs ${plan.callsToMake} NEW live API calls and cannot ask for confirmation '
            '(no usable terminal). Nothing was called. Re-run with --yes to confirm.');
        exit(3);
      }
      if (answer != 'yes') {
        stdout.writeln('Not confirmed. Nothing was called.');
        exit(3);
      }
    }
    apiKey = _readKey(root) ?? '';
    if (apiKey.isEmpty) {
      stderr.writeln('No API key found. Set the ROBOFLOW_API_KEY environment variable, or put it in lib/config.dart.');
      exit(4);
    }
  } else {
    stdout.writeln('Every response is already cached: this run makes no live calls.');
  }

  final client = EvalClient(cache: cache, apiKey: apiKey);
  final out = await runEval(
    plan: plan,
    settings: settings,
    client: client,
    resize: resize,
    upright: upright,
    log: stdout.writeln,
    abortAfterFailures: 5,
  );

  outDir.createSync(recursive: true);
  final report = buildReport(ReportInput(
    generated: DateTime.now(),
    command: 'dart tools/eval/run_eval.dart ${args.join(' ')}'.trim(),
    rows: out.rows,
    calls: out.calls,
    settings: settings,
    modes: modes,
    resize: resize,
    scan: scan,
    client: client,
    minPerLabel: minPerLabel,
    upright: upright,
    entries: plan.entries,
    abortReason: out.abortReason,
  ));
  final sep = Platform.pathSeparator;
  File('${outDir.path}${sep}report.md').writeAsStringSync(report);
  File('${outDir.path}${sep}results.csv').writeAsStringSync(buildCsv(out.rows));

  stdout.writeln('');
  stdout.writeln('Live calls this run: ${client.liveCalls} (${client.liveFailures} failed), cache hits: ${client.cacheHits}');
  if (client.lastError != null) stdout.writeln('Last call error: ${client.lastError}');
  if (out.abortReason != null) stdout.writeln('STOPPED EARLY: ${out.abortReason}');
  stdout.writeln('Wrote ${outDir.path}${sep}report.md and results.csv');
}

void _noImages(Directory imagesDir, ScanResult scan, ModesOption modes, int minPerLabel) {
  stdout.writeln('No photos found under ${imagesDir.path}.');
  if (!imagesDir.existsSync()) stdout.writeln('(the folder does not exist yet; run with --init to create the label folders)');
  if (scan.emptyLabelDirs.isNotEmpty) stdout.writeln('Empty label folders: ${scan.emptyLabelDirs.join(', ')}');
  final counts = {for (final l in kCoreLabels) l: minPerLabel};
  final total = counts.values.fold(0, (a, b) => a + b);
  stdout.writeln('');
  stdout.writeln('Add at least $minPerLabel photos to EACH folder (more is better), including some from your own phone');
  stdout.writeln('held upright at chest height, like the app: ${kCoreLabels.join(', ')}.');
  stdout.writeln('That is $total photos, which would need about ${estimateCalls(counts, modes)} live API calls the first time '
      '(--modes ${modes.name}); reruns cost nothing because responses are cached.');
  stdout.writeln('No results were produced and no API calls were made.');
}

/// ROBOFLOW_API_KEY wins; otherwise the same key the app uses. Never printed.
String? _readKey(Directory root) {
  final env = Platform.environment['ROBOFLOW_API_KEY'];
  if (env != null && env.trim().isNotEmpty) return env.trim();
  final f = File('${root.path}${Platform.pathSeparator}lib${Platform.pathSeparator}config.dart');
  if (!f.existsSync()) return null;
  final m = RegExp(r'roboflowApiKey\s*=\s*"([^"]+)"').firstMatch(f.readAsStringSync());
  return m?.group(1);
}

Map<String, String>? _parse(List<String> args) {
  final out = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (!a.startsWith('--')) return null;
    final name = a.substring(2);
    const flags = {'init', 'plan', 'yes', 'help', 'send-upright'};
    if (flags.contains(name)) {
      out[name] = 'true';
    } else {
      if (i + 1 >= args.length) return null;
      out[name] = args[++i];
    }
  }
  return out;
}
