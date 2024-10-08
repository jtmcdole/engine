// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io' as io;

import 'package:engine_build_configs/engine_build_configs.dart';
import 'package:path/path.dart' as p;

import 'commands/flags.dart';
import 'environment.dart';
import 'label.dart';
import 'logger.dart';

/// A function that returns true or false when given a [BuilderConfig] and its
/// name.
typedef ConfigFilter = bool Function(String name, BuilderConfig config);

/// A function that returns true or false when given a [BuilderConfig] name
/// and a [Build].
typedef BuildFilter = bool Function(String configName, Build build);

/// Returns a filtered copy of [input] filtering out configs where test
/// returns false.
Map<String, BuilderConfig> filterBuilderConfigs(
    Map<String, BuilderConfig> input, ConfigFilter test) {
  return <String, BuilderConfig>{
    for (final MapEntry<String, BuilderConfig> entry in input.entries)
      if (test(entry.key, entry.value)) entry.key: entry.value,
  };
}

/// Returns a copy of [input] filtering out configs that are not runnable
/// on the current platform.
Map<String, BuilderConfig> runnableBuilderConfigs(
    Environment env, Map<String, BuilderConfig> input) {
  return filterBuilderConfigs(input, (String name, BuilderConfig config) {
    return config.canRunOn(env.platform);
  });
}

/// Returns a List of [Build] that match test.
List<Build> filterBuilds(Map<String, BuilderConfig> input, BuildFilter test) {
  return <Build>[
    for (final MapEntry<String, BuilderConfig> entry in input.entries)
      for (final Build build in entry.value.builds)
        if (test(entry.key, build)) build,
  ];
}

/// Returns a list of runnable builds.
List<Build> runnableBuilds(
    Environment env, Map<String, BuilderConfig> input, bool verbose) {
  return filterBuilds(input, (String configName, Build build) {
    return build.canRunOn(env.platform) &&
        (verbose || build.name.startsWith(env.platform.operatingSystem));
  });
}

/// Validates the list of builds.
/// Calls assert.
void debugCheckBuilds(List<Build> builds) {
  final Set<String> names = <String>{};

  for (final Build build in builds) {
    assert(!names.contains(build.name),
        'More than one build has the name ${build.name}');
    names.add(build.name);
  }
}

String _ciPrefix(Environment env) => 'ci${env.platform.pathSeparator}';
String _osPrefix(Environment env) => '${env.platform.operatingSystem}/';
const String _webTestsPrefix = 'web_tests/';

bool _doNotMangle(Environment env, String name) {
  return name.startsWith(_ciPrefix(env)) || name.startsWith(_webTestsPrefix);
}

/// Transform the name of a build into the name presented and accepted by the
/// CLI
///
/// If a name starts with '$OS/', it is a local development build, and the
/// mangled name has the '$OS/' part stripped off, where $OS is the value of
/// `platform.operatingSystem` in the passed-in `environment`.
///
/// If the name does not start with '$OS/', then it must start with 'ci/',
/// 'ci\', or 'web_tests/' in which case the name is returned unchanged.
///
/// Examples:
///   macos/host_debug -> host_debug
///   ci/ios_release -> ci/ios_release
///   ci\host_profile -> ci\host_profile
///   web_tests/artifacts -> web_tests/artifacts
String mangleConfigName(Environment env, String name) {
  final String osPrefix = _osPrefix(env);
  if (name.startsWith(osPrefix)) {
    return name.substring(osPrefix.length);
  }
  if (_doNotMangle(env, name)) {
    return name;
  }
  throw ArgumentError(
    'name argument "$name" must start with a valid platform name or "ci"',
  );
}

/// Transform the mangled (CLI) name of a build into its true name in the build
/// config json file.
///
/// This does the reverse of [mangleConfigName] taking the operating system
/// name from `environment`.
///
/// Examples:
///   host_debug -> macos/host_debug
///   ci/ios_release -> ci/ios_release
///   ci\host_profile -> ci\host_profile
///   web_tests/artifacts -> web_tests/artifacts
String demangleConfigName(Environment env, String name) {
  return _doNotMangle(env, name) ? name : '${_osPrefix(env)}$name';
}

/// Make an RbeConfig.
RbeConfig makeRbeConfig(String execStrategy) {
  switch (execStrategy) {
    case buildStrategyFlagValueAuto:
      return const RbeConfig();
    case buildStrategyFlagValueLocal:
      return const RbeConfig(execStrategy: RbeExecStrategy.local);
    case buildStrategyFlagValueRemote:
      return const RbeConfig(execStrategy: RbeExecStrategy.remote);
    default:
      throw FatalError('Unknown RBE execution strategy "$execStrategy"');
  }
}

/// Build the build target in the environment.
Future<int> runBuild(
  Environment environment,
  Build build, {
  required bool enableRbe,
  List<String> extraGnArgs = const <String>[],
  List<Label> targets = const <Label>[],
  int concurrency = 0,
  RbeConfig rbeConfig = const RbeConfig(),
}) async {
  final List<String> gnArgs = <String>[
    if (!enableRbe) '--no-rbe',
    ...extraGnArgs,
  ];

  // TODO(loic-sharma): Fetch dependencies if needed.
  final BuildRunner buildRunner = BuildRunner(
    platform: environment.platform,
    processRunner: environment.processRunner,
    abi: environment.abi,
    engineSrcDir: environment.engine.srcDir,
    build: build,
    rbeConfig: rbeConfig,
    concurrency: concurrency,
    extraGnArgs: gnArgs,
    runTests: false,
    extraNinjaArgs: <String>[
      ...targets.map((Label label) => label.toNinjaLabel()),
      // If the environment is verbose, pass the verbose flag to ninja.
      if (environment.verbose) '--verbose',
    ],
  );

  Spinner? spinner;
  void handler(RunnerEvent event) {
    switch (event) {
      case RunnerStart():
        environment.logger.info('$event: ${event.command.join(' ')}');
        environment.logger.status('$event     ', newline: false);
        spinner = environment.logger.startSpinner();
      case RunnerProgress(done: true):
        spinner?.finish();
        spinner = null;
        environment.logger.clearLine();
        environment.logger.status(event);
      case RunnerProgress(done: false):
        {
          spinner?.finish();
          spinner = null;
          final String percent = '${event.percent.toStringAsFixed(1)}%';
          final String fraction = '(${event.completed}/${event.total})';
          final String prefix = '[${event.name}] $percent $fraction ';
          final String what = event.what;
          environment.logger.clearLine();
          environment.logger.status('$prefix$what', newline: false, fit: true);
        }
      default:
        spinner?.finish();
        spinner = null;
        environment.logger.status(event);
    }
  }

  final bool buildResult = await buildRunner.run(handler);
  return buildResult ? 0 : 1;
}

/// Run a [build]'s GN step if the output directory is missing.
Future<bool> ensureBuildDir(
  Environment environment,
  Build build, {
  List<String> extraGnArgs = const <String>[],
  required bool enableRbe,
}) async {
  // TODO(matanlurey): https://github.com/flutter/flutter/issues/148442.
  final io.Directory buildDir = io.Directory(
    p.join(
      environment.engine.outDir.path,
      build.ninja.config,
    ),
  );
  if (buildDir.existsSync()) {
    return true;
  }

  final bool built = await _runGn(
    environment,
    build,
    extraGnArgs: extraGnArgs,
    enableRbe: enableRbe,
  );
  if (built && !buildDir.existsSync()) {
    environment.logger.error(
      'The specified build did not produce the expected output directory: '
      '${buildDir.path}',
    );
    return false;
  }
  return built;
}

Future<bool> _runGn(
  Environment environment,
  Build build, {
  List<String> extraGnArgs = const <String>[],
  required bool enableRbe,
}) async {
  final List<String> gnArgs = <String>[
    if (!enableRbe) '--no-rbe',
    ...extraGnArgs,
  ];

  final BuildRunner buildRunner = BuildRunner(
    platform: environment.platform,
    processRunner: environment.processRunner,
    abi: environment.abi,
    engineSrcDir: environment.engine.srcDir,
    build: build,
    extraGnArgs: gnArgs,
    runNinja: false,
    runGenerators: false,
    runTests: false,
  );

  return buildRunner.run((RunnerEvent event) {
    switch (event) {
      case RunnerResult(ok: false):
        environment.logger.error(event);
      default:
    }
  });
}
