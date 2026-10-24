import 'dart:io';

/// Portable state follows the executable; it never depends on the launch cwd.
/// DPAPI encryption remains bound to the current Windows user and machine.
Future<Directory> windowsDataDirectory() async {
  final override = Platform.environment['NOZELT_DATA_DIR'];
  final directory = Directory(
    override ??
        '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}portable-data',
  );
  await directory.create(recursive: true);
  return directory;
}
