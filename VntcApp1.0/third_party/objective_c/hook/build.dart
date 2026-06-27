// Copyright (c) 2025, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/src/cbuilder/compiler_resolver.dart';

const objCFlags = ['-x', 'objective-c', '-fobjc-arc'];

const assetName = 'objective_c.dylib';

// TODO(https://github.com/dart-lang/native/issues/2272): Remove this from the
// main build.
const testFiles = ['test/util.c'];

final logger = Logger('')
  ..level = Level.INFO
  ..onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      // Don't build any other asset types.
      return;
    }

    const supportedOSs = {OS.iOS, OS.macOS};
    final codeConfig = input.config.code;
    final os = codeConfig.targetOS;
    if (!supportedOSs.contains(os)) {
      // Nothing to do.
      return;
    }

    if (codeConfig.linkModePreference == LinkModePreference.static) {
      throw UnsupportedError('LinkModePreference.static is not supported.');
    }

    final packageName = input.packageName;
    final assetPath = input.outputDirectory.resolve(assetName);
    final srcDir = Directory.fromUri(input.packageRoot.resolve('src/'));
    final target = toTargetTriple(codeConfig);

    final cFiles = <String>[];
    final mFiles = <String>[];
    final hFiles = <String>[];
    for (final file in srcDir.listSync(recursive: true)) {
      if (file is File) {
        final path = file.path;
        if (path.endsWith('.c')) cFiles.add(path);
        if (path.endsWith('.m')) mFiles.add(path);
        if (path.endsWith('.h')) hFiles.add(path);
      }
    }

    // Only include the test utils on mac OS. They use memory functions that
    // aren't supported on iOS, like mach_vm_region. We don't need them on iOS
    // anyway since we only run memory tests on mac.
    if (os == OS.macOS) {
      cFiles.addAll(
        testFiles.map((f) => input.packageRoot.resolve(f).toFilePath()),
      );
    }

    final sysroot = sdkPath(codeConfig);
    final minVersion = minOSVersion(codeConfig);
    final cFlags = <String>[
      '-isysroot',
      sysroot,
      '-target',
      target,
      minVersion,
    ];
    final mFlags = [...cFlags, ...objCFlags];
    final linkFlags = cFlags;

    final builder = await Builder.create(input, input.packageRoot.toFilePath());

    final objectFiles = await Future.wait(<Future<String>>[
      for (final src in cFiles) builder.buildObject(src, cFlags),
      for (final src in mFiles) builder.buildObject(src, mFlags),
    ]);
    await builder.linkLib(objectFiles, assetPath.toFilePath(), linkFlags);

    output.dependencies.addAll(cFiles.map(Uri.file));
    output.dependencies.addAll(mFiles.map(Uri.file));
    output.dependencies.addAll(hFiles.map(Uri.file));

    output.assets.code.add(
      CodeAsset(
        package: packageName,
        name: assetName,
        file: assetPath,
        linkMode: DynamicLoadingBundled(),
      ),
    );
  });
}

class Builder {
  final String _comp;
  final String _rootDir;
  final Uri _tempOutDir;
  Builder._(this._comp, this._rootDir, this._tempOutDir);

  static Future<Builder> create(BuildInput input, String rootDir) async {
    final resolver = CompilerResolver(
      codeConfig: input.config.code,
      logger: logger,
    );
    return Builder._(
      (await resolver.resolveCompiler()).uri.toFilePath(),
      rootDir,
      input.outputDirectory.resolve('obj/'),
    );
  }

  Future<String> buildObject(String input, List<String> flags) async {
    assert(input.startsWith(_rootDir));
    final relativeInput = input.substring(_rootDir.length);
    final output = '${_tempOutDir.resolve(relativeInput).toFilePath()}.o';
    File(output).parent.createSync(recursive: true);
    await _compile([...flags, '-c', input, '-fpic', '-I', 'src'], output);
    return output;
  }

  Future<void> linkLib(
    List<String> objects,
    String output,
    List<String> flags,
  ) => _compile([
    '-shared',
    '-Wl,-encryptable',
    '-undefined',
    'dynamic_lookup',
    ...flags,
    ...objects,
  ], output);

  Future<void> _compile(List<String> flags, String output) async {
    final args = [...flags, '-o', output];
    logger.info('Running: $_comp ${args.join(" ")}');
    final proc = await Process.run(_comp, args);
    logger.info(proc.stdout);
    logger.info(proc.stderr);
    if (proc.exitCode != 0) {
      exitCode = proc.exitCode;
      throw Exception('Command failed: $_comp ${args.join(" ")}');
    }
    logger.info('Generated $output');
  }
}

String sdkPath(CodeConfig codeConfig) {
  final target = sdkTarget(codeConfig);
  return sdkPathFromEnvironment(target) ??
      sdkPathFromXcrun(target) ??
      sdkPathFromDeveloperDir(target) ??
      (throw StateError('Unable to locate Apple SDK path for $target.'));
}

String sdkTarget(CodeConfig codeConfig) {
  final String target;
  if (codeConfig.targetOS == OS.iOS) {
    if (codeConfig.iOS.targetSdk == IOSSdk.iPhoneOS) {
      target = 'iphoneos';
    } else {
      target = 'iphonesimulator';
    }
  } else {
    assert(codeConfig.targetOS == OS.macOS);
    target = 'macosx';
  }
  return target;
}

String? sdkPathFromEnvironment(String target) {
  final sdkRoot = Platform.environment['SDKROOT'];
  if (sdkRoot == null || sdkRoot.isEmpty) {
    return null;
  }
  final resolved = existingDirectoryPath(sdkRoot);
  if (resolved == null) {
    return null;
  }
  return sdkPathMatchesTarget(resolved, target) ? resolved : null;
}

String? sdkPathFromXcrun(String target) {
  return firstLineOfStdout('xcrun', ['--show-sdk-path', '--sdk', target]);
}

String? sdkPathFromDeveloperDir(String target) {
  for (final developerDir in developerDirs()) {
    final sdkPath = sdkPathFromSpecificDeveloperDir(developerDir, target);
    if (sdkPath != null) {
      return sdkPath;
    }
  }
  return null;
}

String? sdkPathFromSpecificDeveloperDir(String developerDir, String target) {
  final platformName = platformNameForTarget(target);
  final sdkName = sdkNameForTarget(target);
  final sdkDirectory = Directory(
    '$developerDir/Platforms/$platformName/Developer/SDKs',
  );
  if (!sdkDirectory.existsSync()) {
    return null;
  }

  final directSdk = existingDirectoryPath('${sdkDirectory.path}/$sdkName.sdk');
  if (directSdk != null) {
    return directSdk;
  }

  final candidates = sdkDirectory.listSync().whereType<Directory>().where((
    directory,
  ) {
    final name = fileName(directory.path);
    return name.startsWith(sdkName) && name.endsWith('.sdk');
  }).toList()..sort((a, b) => fileName(a.path).compareTo(fileName(b.path)));

  if (candidates.isEmpty) {
    return null;
  }
  return existingDirectoryPath(candidates.last.path);
}

List<String> developerDirs() {
  final dirs = <String>[];
  final developerDir = Platform.environment['DEVELOPER_DIR'];
  if (developerDir != null && developerDir.isNotEmpty) {
    dirs.add(developerDir);
  }
  dirs.addAll(const [
    '/Applications/Xcode-16.2.0.app/Contents/Developer',
    '/Applications/Xcode.app/Contents/Developer',
  ]);
  return dirs.toSet().toList();
}

String? firstLineOfStdout(String cmd, List<String> args) {
  final result = Process.runSync(cmd, args);
  if (result.exitCode != 0) {
    logger.warning(
      '$cmd ${args.join(" ")} failed with exit code ${result.exitCode}: '
      '${result.stderr}',
    );
    return null;
  }
  final lines = (result.stdout as String)
      .split('\n')
      .where((line) => line.isNotEmpty);
  if (lines.isEmpty) {
    logger.warning('$cmd ${args.join(" ")} returned empty stdout.');
    return null;
  }
  return lines.first;
}

String? existingDirectoryPath(String path) {
  try {
    final directory = Directory(path);
    if (!directory.existsSync()) {
      return null;
    }
    return directory.resolveSymbolicLinksSync();
  } on FileSystemException {
    return null;
  }
}

bool sdkPathMatchesTarget(String path, String target) {
  final lowerPath = path.toLowerCase();
  if (target == 'iphoneos') {
    return lowerPath.contains('iphoneos') &&
        !lowerPath.contains('iphonesimulator');
  }
  if (target == 'iphonesimulator') {
    return lowerPath.contains('iphonesimulator');
  }
  if (target == 'macosx') {
    return lowerPath.contains('macosx');
  }
  return false;
}

String platformNameForTarget(String target) {
  if (target == 'iphoneos') {
    return 'iPhoneOS.platform';
  }
  if (target == 'iphonesimulator') {
    return 'iPhoneSimulator.platform';
  }
  assert(target == 'macosx');
  return 'MacOSX.platform';
}

String sdkNameForTarget(String target) {
  if (target == 'iphoneos') {
    return 'iPhoneOS';
  }
  if (target == 'iphonesimulator') {
    return 'iPhoneSimulator';
  }
  assert(target == 'macosx');
  return 'MacOSX';
}

String fileName(String path) {
  var normalized = path;
  while (normalized.endsWith(Platform.pathSeparator)) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  final index = normalized.lastIndexOf(Platform.pathSeparator);
  if (index == -1) {
    return normalized;
  }
  return normalized.substring(index + 1);
}

String minOSVersion(CodeConfig codeConfig) {
  if (codeConfig.targetOS == OS.iOS) {
    final targetVersion = codeConfig.iOS.targetVersion;
    return '-mios-version-min=$targetVersion';
  }
  assert(codeConfig.targetOS == OS.macOS);
  final targetVersion = codeConfig.macOS.targetVersion;
  return '-mmacos-version-min=$targetVersion';
}

String toTargetTriple(CodeConfig codeConfig) {
  final architecture = codeConfig.targetArchitecture;
  if (codeConfig.targetOS == OS.iOS) {
    return appleClangIosTargetFlags[architecture]![codeConfig.iOS.targetSdk]!;
  }
  assert(codeConfig.targetOS == OS.macOS);
  return appleClangMacosTargetFlags[architecture]!;
}

const appleClangMacosTargetFlags = {
  Architecture.arm64: 'arm64-apple-darwin',
  Architecture.x64: 'x86_64-apple-darwin',
};

const appleClangIosTargetFlags = {
  Architecture.arm64: {
    IOSSdk.iPhoneOS: 'arm64-apple-ios',
    IOSSdk.iPhoneSimulator: 'arm64-apple-ios-simulator',
  },
  Architecture.x64: {IOSSdk.iPhoneSimulator: 'x86_64-apple-ios-simulator'},
};
