/// A read-only live probe for the Ham account tools.
///
/// Run it after renewing the Ham authorisation to confirm the tools this app
/// depends on still answer:
///
/// ```powershell
/// dart run tool/ham_center_live.dart
/// ```
///
/// It reads the token the app already stored (this machine's app-support
/// `shared_preferences.json`), calls the same repository the UI uses, and prints
/// **counts and aggregates only** — never the nickname, the comments or the
/// token. Nothing is written.
library;

import 'dart:convert';
import 'dart:io';

import 'package:campus_atlas/core/result.dart';
import 'package:campus_atlas/features/grades_query/ham/ham_center_repository.dart';
import 'package:campus_atlas/features/grades_query/ham/ham_grades_repository.dart';
import 'package:campus_atlas/features/grades_query/ham/ham_mcp_client.dart';

String _describe<T>(Result<T> result, String Function(T value) onSuccess) =>
    result.isSuccess
        ? onSuccess(result.requireValue)
        : 'FAILED ${result.errorOrNull?.message}';

Future<void> main() async {
  final appData = Platform.environment['APPDATA'];
  if (appData == null) {
    stderr.writeln('APPDATA is not set — this probe expects a Windows profile.');
    exit(2);
  }
  final prefsFile = File(
    '$appData${Platform.pathSeparator}com.example'
    '${Platform.pathSeparator}campus_atlas'
    '${Platform.pathSeparator}shared_preferences.json',
  );
  if (!prefsFile.existsSync()) {
    stderr.writeln('No stored preferences at ${prefsFile.path}.');
    exit(2);
  }

  final prefs = jsonDecode(prefsFile.readAsStringSync());
  final token = prefs is Map ? prefs['flutter.ham.token.access'] : null;
  if (token is! String || token.isEmpty) {
    stderr.writeln('No Ham token is stored. Authorise in the app first.');
    exit(2);
  }

  final client = HamMcpClient(apiKey: token);
  final grades = HamGradesRepository(client: client);
  final center = HamCenterRepository(gateway: HamMcpGateway(client));

  final scores = await grades.search(query: '高等数学A1');
  final first = scores.isSuccess && scores.requireValue.isNotEmpty
      ? scores.requireValue.first
      : null;

  stdout.writeln('grade stats: ${_describe(scores, (list) => '${list.length} team(s)')}');
  stdout.writeln('course_table_id present: ${first?.courseTableId.isNotEmpty ?? false}');

  final user = await center.userInfo();
  stdout.writeln('user info: ${_describe(user, (_) => 'ok')}');

  final id = first?.courseTableId ?? '';
  if (id.isNotEmpty) {
    final comments = await center.comments(id);
    stdout.writeln('comments: ${_describe(
      comments,
      (page) => '${page.comments.length} of ${page.total}',
    )}');

    final stat = await center.semesterStat(
      courseTableId: id,
      year: 2025,
      semester: 1,
    );
    stdout.writeln('semester 2025-1: ${_describe(
      stat,
      (s) => 'avg=${s.course.average} median=${s.course.median} '
          'n=${s.course.total} bands=${s.course.buckets.length}',
    )}');
  }

  final rank = await center.scoreRank();
  stdout.writeln('rank: ${_describe(
    rank,
    (section) => '${section.items.length} of ${section.total}',
  )}');

  final wants = await center.wantList();
  stdout.writeln('want list: ${_describe(
    wants,
    (section) => '${section.items.length} of ${section.total}',
  )}');

  final mine = await center.myComments();
  stdout.writeln('my comments: ${_describe(
    mine,
    (page) => '${page.comments.length} of ${page.total}',
  )}');

  center.close();
}

