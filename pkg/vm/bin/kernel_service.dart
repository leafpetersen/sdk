// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// This is an interface to the Dart Kernel parser and Kernel binary generator.
///
/// It is used by the kernel-isolate to load Dart source code and generate
/// Kernel binary format.
///
/// This is either invoked as the root script of the Kernel isolate when used
/// as a part of
///
///         dart --dfe=pkg/vm/bin/kernel_service.dart ...
///
/// invocation or it is invoked as a standalone script to perform training for
/// the app-jit snapshot
///
///         dart pkg/vm/bin/kernel_service.dart --train <source-file>
///
///
library runtime.tools.kernel_service;

import 'dart:async' show Future, ZoneSpecification, runZoned;
import 'dart:io' show Platform, stderr hide FileSystemEntity;
import 'dart:isolate';
import 'dart:typed_data' show Uint8List;

import 'package:front_end/src/api_prototype/file_system.dart';
import 'package:front_end/src/api_prototype/front_end.dart';
import 'package:front_end/src/api_prototype/incremental_kernel_generator.dart';
import 'package:front_end/src/api_prototype/memory_file_system.dart';
import 'package:front_end/src/api_prototype/standard_file_system.dart';
import 'package:front_end/src/compute_platform_binaries_location.dart'
    show computePlatformBinariesLocation;
import 'package:front_end/src/fasta/kernel/utils.dart';
import 'package:front_end/src/testing/hybrid_file_system.dart';
import 'package:kernel/kernel.dart' show Program;
import 'package:kernel/target/targets.dart' show TargetFlags;
import 'package:kernel/target/vm.dart' show VmTarget;

const bool verbose = const bool.fromEnvironment('DFE_VERBOSE');
const String platformKernelFile = 'virtual_platform_kernel.dill';

abstract class Compiler {
  final FileSystem fileSystem;
  final bool strongMode;
  final List<String> errors = new List<String>();

  CompilerOptions options;

  Compiler(this.fileSystem, Uri platformKernelPath,
      {this.strongMode: false,
      bool suppressWarnings: false,
      bool syncAsync: false}) {
    Uri packagesUri = (Platform.packageConfig != null)
        ? Uri.parse(Platform.packageConfig)
        : null;

    if (verbose) {
      print("DFE: Platform.packageConfig: ${Platform.packageConfig}");
      print("DFE: packagesUri: ${packagesUri}");
      print("DFE: Platform.resolvedExecutable: ${Platform.resolvedExecutable}");
      print("DFE: platformKernelPath: ${platformKernelPath}");
      print("DFE: strongMode: ${strongMode}");
      print("DFE: syncAsync: ${syncAsync}");
    }

    options = new CompilerOptions()
      ..strongMode = strongMode
      ..fileSystem = fileSystem
      ..target = new VmTarget(
          new TargetFlags(strongMode: strongMode, syncAsync: syncAsync))
      ..packagesFileUri = packagesUri
      ..sdkSummary = platformKernelPath
      ..verbose = verbose
      ..onProblem =
          (message, Severity severity, String formatted, int line, int column) {
        switch (severity) {
          case Severity.error:
          case Severity.errorLegacyWarning:
          case Severity.internalProblem:
            // TODO(sigmund): support emitting code with errors as long as they
            // are handled in the generated code (issue #30194).
            errors.add(formatted);
            stderr.writeln(formatted);
            break;
          case Severity.nit:
            break;
          case Severity.warning:
            if (!suppressWarnings) stderr.writeln(formatted);
            break;
        }
      };
  }

  Future<Program> compile(Uri script) {
    return runWithPrintToStderr(() => compileInternal(script));
  }

  Future<Program> compileInternal(Uri script);
}

class IncrementalCompiler extends Compiler {
  IncrementalKernelGenerator generator;

  IncrementalCompiler(FileSystem fileSystem, Uri platformKernelPath,
      {bool strongMode: false, bool suppressWarnings: false, syncAsync: false})
      : super(fileSystem, platformKernelPath,
            strongMode: strongMode,
            suppressWarnings: suppressWarnings,
            syncAsync: syncAsync);

  @override
  Future<Program> compileInternal(Uri script) async {
    if (generator == null) {
      generator = new IncrementalKernelGenerator(options, script);
    }
    return await generator.computeDelta();
  }

  void invalidate(Uri uri) {
    generator.invalidate(uri);
  }
}

class SingleShotCompiler extends Compiler {
  final bool requireMain;

  SingleShotCompiler(FileSystem fileSystem, Uri platformKernelPath,
      {this.requireMain: false,
      bool strongMode: false,
      bool suppressWarnings: false,
      bool syncAsync: false})
      : super(fileSystem, platformKernelPath,
            strongMode: strongMode,
            suppressWarnings: suppressWarnings,
            syncAsync: syncAsync);

  @override
  Future<Program> compileInternal(Uri script) async {
    return requireMain
        ? kernelForProgram(script, options)
        : kernelForBuildUnit([script], options..chaseDependencies = true);
  }
}

final Map<int, Compiler> isolateCompilers = new Map<int, Compiler>();

Future<Compiler> lookupOrBuildNewIncrementalCompiler(int isolateId,
    List sourceFiles, Uri platformKernelPath, List<int> platformKernel,
    {bool strongMode: false,
    bool suppressWarnings: false,
    bool syncAsync: false}) async {
  IncrementalCompiler compiler;
  if (isolateCompilers.containsKey(isolateId)) {
    compiler = isolateCompilers[isolateId];
    final HybridFileSystem fileSystem = compiler.fileSystem;
    if (sourceFiles != null) {
      for (int i = 0; i < sourceFiles.length ~/ 2; i++) {
        Uri uri = Uri.parse(sourceFiles[i * 2]);
        fileSystem.memory
            .entityForUri(uri)
            .writeAsBytesSync(sourceFiles[i * 2 + 1]);
        compiler.invalidate(uri);
      }
    }
  } else {
    final FileSystem fileSystem = sourceFiles == null && platformKernel == null
        ? StandardFileSystem.instance
        : _buildFileSystem(sourceFiles, platformKernel);

    // TODO(aam): IncrementalCompiler instance created below have to be
    // destroyed when corresponding isolate is shut down. To achieve that kernel
    // isolate needs to receive a message indicating that particular
    // isolate was shut down. Message should be handled here in this script.
    compiler = new IncrementalCompiler(fileSystem, platformKernelPath,
        strongMode: strongMode,
        suppressWarnings: suppressWarnings,
        syncAsync: syncAsync);
    isolateCompilers[isolateId] = compiler;
  }
  return compiler;
}

Future _processLoadRequest(request) async {
  if (verbose) print("DFE: request: $request");

  int tag = request[0];
  final SendPort port = request[1];
  final String inputFileUri = request[2];
  final bool incremental = request[4];
  final bool strong = request[5];
  final int isolateId = request[6];
  final List sourceFiles = request[7];
  final bool suppressWarnings = request[8];
  final bool syncAsync = request[9];

  final Uri script = Uri.base.resolve(inputFileUri);
  Uri platformKernelPath = null;
  List<int> platformKernel = null;
  if (request[3] is String) {
    platformKernelPath = Uri.base.resolveUri(new Uri.file(request[3]));
  } else if (request[3] is List<int>) {
    platformKernelPath = Uri.parse(platformKernelFile);
    platformKernel = request[3];
  } else {
    platformKernelPath = computePlatformBinariesLocation()
        .resolve(strong ? 'vm_platform_strong.dill' : 'vm_platform.dill');
  }

  Compiler compiler;
  // TODO(aam): There should be no need to have an option to choose
  // one compiler or another. We should always use an incremental
  // compiler as its functionality is a super set of the other one. We need to
  // watch the performance though.
  if (incremental) {
    compiler = await lookupOrBuildNewIncrementalCompiler(
        isolateId, sourceFiles, platformKernelPath, platformKernel,
        suppressWarnings: suppressWarnings, syncAsync: syncAsync);
  } else {
    final FileSystem fileSystem = sourceFiles == null && platformKernel == null
        ? StandardFileSystem.instance
        : _buildFileSystem(sourceFiles, platformKernel);
    compiler = new SingleShotCompiler(fileSystem, platformKernelPath,
        requireMain: sourceFiles == null,
        strongMode: strong,
        suppressWarnings: suppressWarnings,
        syncAsync: syncAsync);
  }

  CompilationResult result;
  try {
    if (verbose) {
      print("DFE: scriptUri: ${script}");
    }

    Program program = await compiler.compile(script);

    if (compiler.errors.isNotEmpty) {
      // TODO(sigmund): the compiler prints errors to the console, so we
      // shouldn't print those messages again here.
      result = new CompilationResult.errors(compiler.errors);
    } else {
      // We serialize the program excluding vm_platform.dill because the VM has
      // these sources built-in. Everything loaded as a summary in
      // [kernelForProgram] is marked `external`, so we can use that bit to
      // decide what to exclude.
      result = new CompilationResult.ok(
          serializeProgram(program, filter: (lib) => !lib.isExternal));
    }
  } catch (error, stack) {
    result = new CompilationResult.crash(error, stack);
  }

  if (verbose) print("DFE:> ${result}");

  // Check whether this is a Loader request or a bootstrapping request from
  // KernelIsolate::CompileToKernel.
  final isBootstrapRequest = tag == null;
  if (isBootstrapRequest) {
    port.send(result.toResponse());
  } else {
    // See loader.cc for the code that handles these replies.
    if (result.status != Status.ok) {
      tag = -tag;
    }
    port.send([tag, inputFileUri, inputFileUri, null, result.payload]);
  }
}

/// Creates a file system containing the files specified in [namedSources] and
/// that delegates to the underlying file system for any other file request.
/// The [namedSources] list interleaves file name string and
/// raw file content Uint8List.
///
/// The result can be used instead of StandardFileSystem.instance by the
/// frontend.
FileSystem _buildFileSystem(List namedSources, List<int> platformKernel) {
  MemoryFileSystem fileSystem = new MemoryFileSystem(Uri.parse('file:///'));
  if (namedSources != null) {
    for (int i = 0; i < namedSources.length ~/ 2; i++) {
      fileSystem
          .entityForUri(Uri.parse(namedSources[i * 2]))
          .writeAsBytesSync(namedSources[i * 2 + 1]);
    }
  }
  if (platformKernel != null) {
    fileSystem
        .entityForUri(Uri.parse(platformKernelFile))
        .writeAsBytesSync(platformKernel);
  }
  return new HybridFileSystem(fileSystem);
}

train(String scriptUri, String platformKernelPath) {
  // TODO(28532): Enable on Windows.
  if (Platform.isWindows) return;

  var tag = 1;
  var responsePort = new RawReceivePort();
  responsePort.handler = (response) {
    if (response[0] == tag) {
      // Success.
      responsePort.close();
    } else if (response[0] == -tag) {
      // Compilation error.
      throw response[4];
    } else {
      throw "Unexpected response: $response";
    }
  };
  var request = [
    tag,
    responsePort.sendPort,
    scriptUri,
    platformKernelPath,
    false /* incremental */,
    false /* strong */,
    1 /* isolateId chosen randomly */,
    null /* source files */,
    false /* suppress warnings */,
    false /* synchronous async */,
  ];
  _processLoadRequest(request);
}

main([args]) {
  if ((args?.length ?? 0) > 1 && args[0] == '--train') {
    // This entry point is used when creating an app snapshot. The argument
    // provides a script to compile to warm-up generated code.
    train(args[1], args.length > 2 ? args[2] : null);
  } else {
    // Entry point for the Kernel isolate.
    return new RawReceivePort()..handler = _processLoadRequest;
  }
}

/// Compilation status codes.
///
/// Note: The [index] property of these constants must match
/// `Dart_KernelCompilationStatus` in
/// [dart_api.h](../../../../runtime/include/dart_api.h).
enum Status {
  /// Compilation was successful.
  ok,

  /// Compilation failed with a compile time error.
  error,

  /// Compiler crashed.
  crash,
}

abstract class CompilationResult {
  CompilationResult._();

  factory CompilationResult.ok(Uint8List bytes) = _CompilationOk;

  factory CompilationResult.errors(List<String> errors) = _CompilationError;

  factory CompilationResult.crash(Object exception, StackTrace stack) =
      _CompilationCrash;

  Status get status;

  get payload;

  List toResponse() => [status.index, payload];
}

class _CompilationOk extends CompilationResult {
  final Uint8List bytes;

  _CompilationOk(this.bytes) : super._();

  @override
  Status get status => Status.ok;

  @override
  get payload => bytes;

  String toString() => "_CompilationOk(${bytes.length} bytes)";
}

abstract class _CompilationFail extends CompilationResult {
  _CompilationFail() : super._();

  String get errorString;

  @override
  get payload => errorString;
}

class _CompilationError extends _CompilationFail {
  final List<String> errors;

  _CompilationError(this.errors);

  @override
  Status get status => Status.error;

  @override
  String get errorString => errors.take(10).join('\n');

  String toString() => "_CompilationError(${errorString})";
}

class _CompilationCrash extends _CompilationFail {
  final Object exception;
  final StackTrace stack;

  _CompilationCrash(this.exception, this.stack);

  @override
  Status get status => Status.crash;

  @override
  String get errorString => "${exception}\n${stack}";

  String toString() => "_CompilationCrash(${errorString})";
}

Future<T> runWithPrintToStderr<T>(Future<T> f()) {
  return runZoned(() => new Future<T>(f),
      zoneSpecification: new ZoneSpecification(
          print: (_1, _2, _3, String line) => stderr.writeln(line)));
}
