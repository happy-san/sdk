// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:pedantic/pedantic.dart';
import 'package:vm_service/vm_service.dart' as vm;

import '../exceptions.dart';
import '../logging.dart';
import '../protocol_generated.dart';
import '../protocol_stream.dart';
import 'dart.dart';

/// A DAP Debug Adapter for running and debugging Dart CLI scripts.
class DartCliDebugAdapter extends DartDebugAdapter<DartLaunchRequestArguments,
    DartAttachRequestArguments> {
  Process? _process;

  /// Process IDs to terminate during shutdown.
  ///
  /// This may be populated with pids from the VM Service to ensure we clean up
  /// properly where signals may not be passed through the shell to the
  /// underlying VM process.
  /// https://github.com/Dart-Code/Dart-Code/issues/907
  final pidsToTerminate = <int>{};

  @override
  final parseLaunchArgs = DartLaunchRequestArguments.fromJson;

  @override
  final parseAttachArgs = DartAttachRequestArguments.fromJson;

  DartCliDebugAdapter(
    ByteStreamServerChannel channel, {
    bool ipv6 = false,
    bool enableDds = true,
    bool enableAuthCodes = true,
    Logger? logger,
  }) : super(
          channel,
          ipv6: ipv6,
          enableDds: enableDds,
          enableAuthCodes: enableAuthCodes,
          logger: logger,
        ) {
    channel.closed.then((_) => shutdown());
  }

  /// Whether the VM Service closing should be used as a signal to terminate the
  /// debug session.
  ///
  /// If we have a process, we will instead use its termination as a signal to
  /// terminate the debug session. Otherwise, we will use the VM Service close.
  bool get terminateOnVmServiceClose => _process == null;

  Future<void> debuggerConnected(vm.VM vmInfo) async {
    if (!isAttach) {
      // Capture the PID from the VM Service so that we can terminate it when
      // cleaning up. Terminating the process might not be enough as it could be
      // just a shell script (e.g. pub on Windows) and may not pass the
      // signal on correctly.
      // See: https://github.com/Dart-Code/Dart-Code/issues/907
      final pid = vmInfo.pid;
      if (pid != null) {
        pidsToTerminate.add(pid);
      }
    }
  }

  /// Called by [disconnectRequest] to request that we forcefully shut down the
  /// app being run (or in the case of an attach, disconnect).
  Future<void> disconnectImpl() async {
    // TODO(dantup): In Dart-Code DAP, we first try again with sigint and wait
    // for a few seconds before sending sigkill.
    pidsToTerminate.forEach(
      (pid) => Process.killPid(pid, ProcessSignal.sigkill),
    );
  }

  /// Waits for [vmServiceInfoFile] to exist and become valid before returning
  /// the VM Service URI contained within.
  Future<Uri> waitForVmServiceInfoFile(File vmServiceInfoFile) async {
    final completer = Completer<Uri>();
    late final StreamSubscription<FileSystemEvent> vmServiceInfoFileWatcher;

    Uri? tryParseServiceInfoFile(FileSystemEvent event) {
      final uri = _readVmServiceInfoFile(vmServiceInfoFile);
      if (uri != null && !completer.isCompleted) {
        vmServiceInfoFileWatcher.cancel();
        completer.complete(uri);
      }
    }

    vmServiceInfoFileWatcher = vmServiceInfoFile.parent
        .watch(events: FileSystemEvent.all)
        .where((event) => event.path == vmServiceInfoFile.path)
        .listen(
          tryParseServiceInfoFile,
          onError: (e) => logger?.call('Ignoring exception from watcher: $e'),
        );

    // After setting up the watcher, also check if the file already exists to
    // ensure we don't miss it if it was created right before we set the
    // watched up.
    final uri = _readVmServiceInfoFile(vmServiceInfoFile);
    if (uri != null && !completer.isCompleted) {
      unawaited(vmServiceInfoFileWatcher.cancel());
      completer.complete(uri);
    }

    return completer.future;
  }

  /// Called by [launchRequest] to request that we actually start the app to be
  /// run/debugged.
  ///
  /// For debugging, this should start paused, connect to the VM Service, set
  /// breakpoints, and resume.
  Future<void> launchImpl() async {
    final args = this.args as DartLaunchRequestArguments;
    final vmPath = Platform.resolvedExecutable;
    File? vmServiceInfoFile;

    final debug = !(args.noDebug ?? false);
    if (debug) {
      // Create a temp folder for the VM to write the service-info-file into.
      // Using tmpDir.createTempory() is flakey on Windows+Linux (at least
      // on GitHub Actions) complaining the file does not exist when creating a
      // watcher. Creating/watching a folder and writing the file into it seems
      // to be reliable.
      final serviceInfoFilePath = path.join(
        Directory.systemTemp.createTempSync('dart-vm-service').path,
        'vm.json',
      );

      vmServiceInfoFile = File(serviceInfoFilePath);
      unawaited(waitForVmServiceInfoFile(vmServiceInfoFile)
          .then((uri) => connectDebugger(uri, resumeIfStarting: true)));
    }

    final vmArgs = <String>[
      if (debug) ...[
        '--enable-vm-service=${args.vmServicePort ?? 0}${ipv6 ? '/::1' : ''}',
        '--pause_isolates_on_start=true',
        if (!enableAuthCodes) '--disable-service-auth-codes'
      ],
      '--disable-dart-dev',
      if (debug && vmServiceInfoFile != null) ...[
        '-DSILENT_OBSERVATORY=true',
        '--write-service-info=${Uri.file(vmServiceInfoFile.path)}'
      ],
      // Default to asserts on, this seems like the most useful behaviour for
      // editor-spawned debug sessions.
      if (args.enableAsserts ?? true) '--enable-asserts'
    ];
    final processArgs = [
      ...vmArgs,
      args.program,
      ...?args.args,
    ];

    // Find the package_config file for this script.
    // TODO(dantup): Remove this once
    //   https://github.com/dart-lang/sdk/issues/45530 is done as it will not be
    //   necessary.
    var possibleRoot = path.isAbsolute(args.program)
        ? path.dirname(args.program)
        : path.dirname(path.normalize(path.join(args.cwd ?? '', args.program)));
    final packageConfig = _findPackageConfigFile(possibleRoot);
    if (packageConfig != null) {
      this.usePackageConfigFile(packageConfig);
    }

    // If the client supports runInTerminal and args.console is set to either
    // 'terminal' or 'runInTerminal' we won't run the process ourselves, but
    // instead call the client to run it for us (this allows it to run in a
    // terminal where the user can interact with `stdin`).
    final canRunInTerminal =
        initializeArgs?.supportsRunInTerminalRequest ?? false;

    // The terminal kinds used by DAP are 'integrated' and 'external'.
    final terminalKind = canRunInTerminal
        ? args.console == 'terminal'
            ? 'integrated'
            : args.console == 'externalTerminal'
                ? 'external'
                : null
        : null;

    // TODO(dantup): Support passing env to both of these.

    if (terminalKind != null) {
      await launchInEditorTerminal(debug, terminalKind, vmPath, processArgs);
    } else {
      await launchAsProcess(vmPath, processArgs);
    }
  }

  /// Called by [attachRequest] to request that we actually connect to the app
  /// to be debugged.
  Future<void> attachImpl() async {
    final args = this.args as DartAttachRequestArguments;
    final vmServiceUri = args.vmServiceUri;
    final vmServiceInfoFile = args.vmServiceInfoFile;

    if ((vmServiceUri == null) == (vmServiceInfoFile == null)) {
      throw DebugAdapterException(
        'To attach, provide exactly one of vmServiceUri/vmServiceInfoFile',
      );
    }

    // Find the package_config file for this script.
    // TODO(dantup): Remove this once
    //   https://github.com/dart-lang/sdk/issues/45530 is done as it will not be
    //   necessary.
    final cwd = args.cwd;
    if (cwd != null) {
      final packageConfig = _findPackageConfigFile(cwd);
      if (packageConfig != null) {
        this.usePackageConfigFile(packageConfig);
      }
    }

    final uri = vmServiceUri != null
        ? Uri.parse(vmServiceUri)
        : await waitForVmServiceInfoFile(File(vmServiceInfoFile!));

    unawaited(connectDebugger(uri, resumeIfStarting: false));
  }

  /// Calls the client (via a `runInTerminal` request) to spawn the process so
  /// that it can run in a local terminal that the user can interact with.
  Future<void> launchInEditorTerminal(
    bool debug,
    String terminalKind,
    String vmPath,
    List<String> processArgs,
  ) async {
    final args = this.args as DartLaunchRequestArguments;
    logger?.call('Spawning $vmPath with $processArgs in ${args.cwd}'
        ' via client ${terminalKind} terminal');

    // runInTerminal is a DAP request that goes from server-to-client that
    // allows the DA to ask the client editor to run the debugee for us. In this
    // case we will have no access to the process (although we get the PID) so
    // for debugging will rely on the process writing the service-info file that
    // we can detect with the normal watching code.
    final requestArgs = RunInTerminalRequestArguments(
      args: [vmPath, ...processArgs],
      cwd: args.cwd ?? path.dirname(args.program),
      kind: terminalKind,
      title: args.name ?? 'Dart',
    );
    try {
      final response = await sendRequest(requestArgs);
      final body =
          RunInTerminalResponseBody.fromJson(response as Map<String, Object?>);
      logger?.call(
        'Client spawned process'
        ' (proc: ${body.processId}, shell: ${body.shellProcessId})',
      );
    } catch (e) {
      logger?.call('Client failed to spawn process $e');
      sendOutput('console', '\nFailed to spawn process: $e');
      handleSessionTerminate();
    }

    // When using `runInTerminal` and `noDebug`, we will not connect to the VM
    // Service so we will have no way of knowing when the process completes, so
    // we just send the termination event right away.
    if (!debug) {
      handleSessionTerminate();
    }
  }

  /// Launches the program as a process controlled by the debug adapter.
  ///
  /// Output to `stdout`/`stderr` will be sent to the editor using
  /// [OutputEvent]s.
  Future<void> launchAsProcess(String vmPath, List<String> processArgs) async {
    logger?.call('Spawning $vmPath with $processArgs in ${args.cwd}');
    final process = await Process.start(
      vmPath,
      processArgs,
      workingDirectory: args.cwd,
    );
    _process = process;
    pidsToTerminate.add(process.pid);

    process.stdout.listen(_handleStdout);
    process.stderr.listen(_handleStderr);
    unawaited(process.exitCode.then(_handleExitCode));
  }

  /// Find the `package_config.json` file for the program being launched.
  ///
  /// TODO(dantup): Remove this once
  ///   https://github.com/dart-lang/sdk/issues/45530 is done as it will not be
  ///   necessary.
  File? _findPackageConfigFile(String possibleRoot) {
    File? packageConfig;
    while (true) {
      packageConfig =
          File(path.join(possibleRoot, '.dart_tool', 'package_config.json'));

      // If this packageconfig exists, use it.
      if (packageConfig.existsSync()) {
        break;
      }

      final parent = path.dirname(possibleRoot);

      // If we can't go up anymore, the search failed.
      if (parent == possibleRoot) {
        packageConfig = null;
        break;
      }

      possibleRoot = parent;
    }

    return packageConfig;
  }

  /// Called by [terminateRequest] to request that we gracefully shut down the
  /// app being run (or in the case of an attach, disconnect).
  Future<void> terminateImpl() async {
    pidsToTerminate.forEach(
      (pid) => Process.killPid(pid, ProcessSignal.sigint),
    );
    await _process?.exitCode;
  }

  void _handleExitCode(int code) {
    final codeSuffix = code == 0 ? '' : ' ($code)';
    logger?.call('Process exited ($code)');
    handleSessionTerminate(codeSuffix);
  }

  void _handleStderr(List<int> data) {
    sendOutput('stderr', utf8.decode(data));
  }

  void _handleStdout(List<int> data) {
    sendOutput('stdout', utf8.decode(data));
  }

  /// Attempts to read VM Service info from a watcher event.
  ///
  /// If successful, returns the URI. Otherwise, returns null.
  Uri? _readVmServiceInfoFile(File file) {
    try {
      final content = file.readAsStringSync();
      final json = jsonDecode(content);
      return Uri.parse(json['uri']);
    } catch (e) {
      // It's possible we tried to read the file before it was completely
      // written so ignore and try again on the next event.
      logger?.call('Ignoring error parsing vm-service-info file: $e');
    }
  }
}
