// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:core';
import 'dart:io' as io;
import 'dart:math' show max;

import 'package:analysis_server/protocol/protocol.dart';
import 'package:analysis_server/protocol/protocol_constants.dart'
    show PROTOCOL_VERSION;
import 'package:analysis_server/protocol/protocol_generated.dart'
    hide AnalysisOptions;
import 'package:analysis_server/src/analysis_server_abstract.dart';
import 'package:analysis_server/src/channel/channel.dart';
import 'package:analysis_server/src/computer/computer_highlights.dart';
import 'package:analysis_server/src/context_manager.dart';
import 'package:analysis_server/src/domain_analysis.dart';
import 'package:analysis_server/src/domain_analytics.dart';
import 'package:analysis_server/src/domain_completion.dart';
import 'package:analysis_server/src/domain_diagnostic.dart';
import 'package:analysis_server/src/domain_execution.dart';
import 'package:analysis_server/src/domain_kythe.dart';
import 'package:analysis_server/src/domain_server.dart';
import 'package:analysis_server/src/domains/analysis/macro_files.dart';
import 'package:analysis_server/src/domains/analysis/occurrences.dart';
import 'package:analysis_server/src/domains/analysis/occurrences_dart.dart';
import 'package:analysis_server/src/edit/edit_domain.dart';
import 'package:analysis_server/src/flutter/flutter_domain.dart';
import 'package:analysis_server/src/flutter/flutter_notifications.dart';
import 'package:analysis_server/src/operation/operation_analysis.dart';
import 'package:analysis_server/src/plugin/notification_manager.dart';
import 'package:analysis_server/src/protocol_server.dart' as server;
import 'package:analysis_server/src/search/search_domain.dart';
import 'package:analysis_server/src/server/crash_reporting_attachments.dart';
import 'package:analysis_server/src/server/detachable_filesystem_manager.dart';
import 'package:analysis_server/src/server/diagnostic_server.dart';
import 'package:analysis_server/src/server/error_notifier.dart';
import 'package:analysis_server/src/server/features.dart';
import 'package:analysis_server/src/server/sdk_configuration.dart';
import 'package:analysis_server/src/services/flutter/widget_descriptions.dart';
import 'package:analysis_server/src/utilities/process.dart';
import 'package:analysis_server/src/utilities/request_statistics.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/exception/exception.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/instrumentation/instrumentation.dart';
import 'package:analyzer/src/dart/analysis/driver.dart' as analysis;
import 'package:analyzer/src/dart/analysis/status.dart' as analysis;
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/sdk.dart';
import 'package:analyzer/src/util/file_paths.dart' as file_paths;
import 'package:analyzer_plugin/protocol/protocol_common.dart' hide Element;
import 'package:analyzer_plugin/src/utilities/navigation/navigation.dart';
import 'package:analyzer_plugin/utilities/analyzer_converter.dart';
import 'package:analyzer_plugin/utilities/navigation/navigation_dart.dart';
import 'package:http/http.dart' as http;
import 'package:telemetry/crash_reporting.dart';
import 'package:telemetry/telemetry.dart' as telemetry;
import 'package:watcher/watcher.dart';

typedef OptionUpdater = void Function(AnalysisOptionsImpl options);

/// Instances of the class [AnalysisServer] implement a server that listens on a
/// [CommunicationChannel] for analysis requests and process them.
class AnalysisServer extends AbstractAnalysisServer {
  /// The channel from which requests are received and to which responses should
  /// be sent.
  final ServerCommunicationChannel channel;

  /// A flag indicating the value of the 'analyzing' parameter sent in the last
  /// status message to the client.
  bool statusAnalyzing = false;

  /// A list of the request handlers used to handle the requests sent to this
  /// server.
  late List<RequestHandler> handlers;

  /// A set of the [ServerService]s to send notifications for.
  Set<ServerService> serverServices = HashSet<ServerService>();

  /// A set of the [GeneralAnalysisService]s to send notifications for.
  Set<GeneralAnalysisService> generalAnalysisServices =
      HashSet<GeneralAnalysisService>();

  /// A table mapping [AnalysisService]s to the file paths for which these
  /// notifications should be sent.
  Map<AnalysisService, Set<String>> analysisServices =
      HashMap<AnalysisService, Set<String>>();

  /// A table mapping [FlutterService]s to the file paths for which these
  /// notifications should be sent.
  Map<FlutterService, Set<String>> flutterServices = {};

  /// The support for Flutter properties.
  WidgetDescriptions flutterWidgetDescriptions = WidgetDescriptions();

  /// The [Completer] that completes when analysis is complete.
  Completer<void>? _onAnalysisCompleteCompleter;

  /// The controller that is notified when analysis is started.
  final StreamController<bool> _onAnalysisStartedController =
      StreamController.broadcast();

  /// If the "analysis.analyzedFiles" notification is currently being subscribed
  /// to (see [generalAnalysisServices]), and at least one such notification has
  /// been sent since the subscription was enabled, the set of analyzed files
  /// that was delivered in the most recently sent notification.  Otherwise
  /// `null`.
  Set<String>? prevAnalyzedFiles;

  /// The controller for [onAnalysisSetChanged].
  final StreamController _onAnalysisSetChangedController =
      StreamController.broadcast(sync: true);

  final DetachableFileSystemManager? detachableFileSystemManager;

  /// Initialize a newly created server to receive requests from and send
  /// responses to the given [channel].
  ///
  /// If [rethrowExceptions] is true, then any exceptions thrown by analysis are
  /// propagated up the call stack.  The default is true to allow analysis
  /// exceptions to show up in unit tests, but it should be set to false when
  /// running a full analysis server.
  AnalysisServer(
    this.channel,
    ResourceProvider baseResourceProvider,
    AnalysisServerOptions options,
    DartSdkManager sdkManager,
    CrashReportingAttachmentsBuilder crashReportingAttachmentsBuilder,
    InstrumentationService instrumentationService, {
    http.Client? httpClient,
    ProcessRunner? processRunner,
    RequestStatisticsHelper? requestStatistics,
    DiagnosticServer? diagnosticServer,
    this.detachableFileSystemManager,
    // Disable to avoid using this in unit tests.
    bool enableBazelWatcher = false,
  }) : super(
          options,
          sdkManager,
          diagnosticServer,
          crashReportingAttachmentsBuilder,
          baseResourceProvider,
          instrumentationService,
          httpClient,
          processRunner,
          NotificationManager(channel, baseResourceProvider.pathContext),
          requestStatistics: requestStatistics,
          enableBazelWatcher: enableBazelWatcher,
        ) {
    var contextManagerCallbacks =
        ServerContextManagerCallbacks(this, resourceProvider);
    contextManager.callbacks = contextManagerCallbacks;

    analysisDriverScheduler.status.listen(sendStatusNotificationNew);
    analysisDriverScheduler.start();

    onAnalysisStarted.first.then((_) {
      onAnalysisComplete.then((_) {
        performance = performanceAfterStartup = ServerPerformance();
      });
    });
    var notification =
        ServerConnectedParams(PROTOCOL_VERSION, io.pid).toNotification();
    channel.sendNotification(notification);
    channel.listen(handleRequest, onDone: done, onError: error);
    handlers = <server.RequestHandler>[
      ServerDomainHandler(this),
      AnalysisDomainHandler(this),
      EditDomainHandler(this),
      SearchDomainHandler(this),
      CompletionDomainHandler(this),
      ExecutionDomainHandler(this),
      DiagnosticDomainHandler(this),
      AnalyticsDomainHandler(this),
      KytheDomainHandler(this),
      FlutterDomainHandler(this)
    ];
  }

  /// The analytics instance; note, this object can be `null`.
  telemetry.Analytics? get analytics => options.analytics;

  /// The [Future] that completes when analysis is complete.
  Future<void> get onAnalysisComplete {
    if (isAnalysisComplete()) {
      return Future.value();
    }
    var completer = _onAnalysisCompleteCompleter ??= Completer<void>();
    return completer.future;
  }

  /// The stream that is notified when the analysis set is changed - this might
  /// be a change to a file, external via a watch event, or internal via
  /// overlay. This means that the resolved world might have changed.
  ///
  /// The type of produced elements is not specified and should not be used.
  Stream get onAnalysisSetChanged => _onAnalysisSetChangedController.stream;

  /// The stream that is notified with `true` when analysis is started.
  Stream<bool> get onAnalysisStarted {
    return _onAnalysisStartedController.stream;
  }

  String get sdkPath {
    return sdkManager.defaultSdkDirectory;
  }

  /// The socket from which requests are being read has been closed.
  void done() {}

  /// There was an error related to the socket from which requests are being
  /// read.
  void error(argument) {}

  /// Return the cached analysis result for the file with the given [path].
  /// If there is no cached result, return `null`.
  ResolvedUnitResult? getCachedResolvedUnit(String path) {
    if (!file_paths.isDart(resourceProvider.pathContext, path)) {
      return null;
    }

    var driver = getAnalysisDriver(path);
    return driver?.getCachedResult(path);
  }

  /// Handle a [request] that was read from the communication channel.
  void handleRequest(Request request) {
    performance.logRequestTiming(request.clientRequestTime);
    runZonedGuarded(() {
      var count = handlers.length;
      for (var i = 0; i < count; i++) {
        try {
          var response = handlers[i].handleRequest(request);
          if (response == Response.DELAYED_RESPONSE) {
            return;
          }
          if (response != null) {
            channel.sendResponse(response);
            return;
          }
        } on RequestFailure catch (exception) {
          channel.sendResponse(exception.response);
          return;
        } catch (exception, stackTrace) {
          var error =
              RequestError(RequestErrorCode.SERVER_ERROR, exception.toString());
          error.stackTrace = stackTrace.toString();
          var response = Response(request.id, error: error);
          channel.sendResponse(response);
          return;
        }
      }
      channel.sendResponse(Response.unknownRequest(request));
    }, (exception, stackTrace) {
      instrumentationService.logException(
        FatalException(
          'Failed to handle request: ${request.method}',
          exception,
          stackTrace,
        ),
        null,
        crashReportingAttachmentsBuilder.forException(exception),
      );
    });
  }

  /// Return `true` if the [path] is both absolute and normalized.
  bool isAbsoluteAndNormalized(String path) {
    var pathContext = resourceProvider.pathContext;
    return pathContext.isAbsolute(path) && pathContext.normalize(path) == path;
  }

  /// Return `true` if analysis is complete.
  bool isAnalysisComplete() {
    return !analysisDriverScheduler.isAnalyzing;
  }

  /// Return `true` if the given path is a valid `FilePath`.
  ///
  /// This means that it is absolute and normalized.
  bool isValidFilePath(String path) {
    return resourceProvider.pathContext.isAbsolute(path) &&
        resourceProvider.pathContext.normalize(path) == path;
  }

  @override
  void notifyFlutterWidgetDescriptions(String path) {
    flutterWidgetDescriptions.flush();
  }

  /// Send the given [notification] to the client.
  void sendNotification(Notification notification) {
    channel.sendNotification(notification);
  }

  /// Send the given [response] to the client.
  void sendResponse(Response response) {
    channel.sendResponse(response);
  }

  /// If the [path] is not a valid file path, that is absolute and normalized,
  /// send an error response, and return `true`. If OK then return `false`.
  bool sendResponseErrorIfInvalidFilePath(Request request, String path) {
    if (!isAbsoluteAndNormalized(path)) {
      sendResponse(Response.invalidFilePathFormat(request, path));
      return true;
    }
    return false;
  }

  /// Sends a `server.error` notification.
  @override
  void sendServerErrorNotification(
    String message,
    dynamic exception,
    /*StackTrace*/ stackTrace, {
    bool fatal = false,
  }) {
    var msg = exception == null ? message : '$message: $exception';
    if (stackTrace != null && exception is! CaughtException) {
      stackTrace = StackTrace.current;
    }

    // send the notification
    channel.sendNotification(
        ServerErrorParams(fatal, msg, '$stackTrace').toNotification());

    // remember the last few exceptions
    if (exception is CaughtException) {
      stackTrace ??= exception.stackTrace;
    }

    exceptions.add(ServerException(
      message,
      exception,
      stackTrace is StackTrace ? stackTrace : StackTrace.current,
      fatal,
    ));
  }

  /// Send status notification to the client. The state of analysis is given by
  /// the [status] information.
  void sendStatusNotificationNew(analysis.AnalysisStatus status) {
    if (status.isAnalyzing) {
      _onAnalysisStartedController.add(true);
    }
    var onAnalysisCompleteCompleter = _onAnalysisCompleteCompleter;
    if (onAnalysisCompleteCompleter != null && !status.isAnalyzing) {
      onAnalysisCompleteCompleter.complete();
      _onAnalysisCompleteCompleter = null;
    }
    // Perform on-idle actions.
    if (!status.isAnalyzing) {
      if (generalAnalysisServices
          .contains(GeneralAnalysisService.ANALYZED_FILES)) {
        sendAnalysisNotificationAnalyzedFiles(this);
      }
      _scheduleAnalysisImplementedNotification();
    }
    // Only send status when subscribed.
    if (!serverServices.contains(ServerService.STATUS)) {
      return;
    }
    // Only send status when it changes
    if (statusAnalyzing == status.isAnalyzing) {
      return;
    }
    statusAnalyzing = status.isAnalyzing;
    var analysis = AnalysisStatus(status.isAnalyzing);
    channel.sendNotification(
        ServerStatusParams(analysis: analysis).toNotification());
  }

  /// Implementation for `analysis.setAnalysisRoots`.
  ///
  /// TODO(scheglov) implement complete projects/contexts semantics.
  ///
  /// The current implementation is intentionally simplified and expected
  /// that only folders are given each given folder corresponds to the exactly
  /// one context.
  ///
  /// So, we can start working in parallel on adding services and improving
  /// projects/contexts support.
  void setAnalysisRoots(String requestId, List<String> includedPaths,
      List<String> excludedPaths) {
    notificationManager.setAnalysisRoots(includedPaths, excludedPaths);
    try {
      contextManager.setRoots(includedPaths, excludedPaths);
    } on UnimplementedError catch (e) {
      throw RequestFailure(Response.unsupportedFeature(
          requestId, e.message ?? 'Unsupported feature.'));
    }
    analysisDriverScheduler.transitionToAnalyzingToIdleIfNoFilesToAnalyze();
  }

  /// Implementation for `analysis.setSubscriptions`.
  void setAnalysisSubscriptions(
      Map<AnalysisService, Set<String>> subscriptions) {
    notificationManager.setSubscriptions(subscriptions);
    analysisServices = subscriptions;
    _sendSubscriptions(analysis: true);
  }

  /// Implementation for `flutter.setSubscriptions`.
  void setFlutterSubscriptions(Map<FlutterService, Set<String>> subscriptions) {
    flutterServices = subscriptions;
    _sendSubscriptions(flutter: true);
  }

  /// Implementation for `analysis.setGeneralSubscriptions`.
  void setGeneralAnalysisSubscriptions(
      List<GeneralAnalysisService> subscriptions) {
    var newServices = subscriptions.toSet();
    if (newServices.contains(GeneralAnalysisService.ANALYZED_FILES) &&
        !generalAnalysisServices
            .contains(GeneralAnalysisService.ANALYZED_FILES) &&
        isAnalysisComplete()) {
      sendAnalysisNotificationAnalyzedFiles(this);
    } else if (!newServices.contains(GeneralAnalysisService.ANALYZED_FILES) &&
        generalAnalysisServices
            .contains(GeneralAnalysisService.ANALYZED_FILES)) {
      prevAnalyzedFiles = null;
    }
    generalAnalysisServices = newServices;
  }

  /// Set the priority files to the given [files].
  void setPriorityFiles(String requestId, List<String> files) {
    bool isPubspec(String filePath) =>
        file_paths.isPubspecYaml(resourceProvider.pathContext, filePath);

    // When pubspecs are opened, trigger pre-loading of pub package names and
    // versions.
    final pubspecs = files.where(isPubspec).toList();
    if (pubspecs.isNotEmpty) {
      pubPackageService.beginCachePreloads(pubspecs);
    }

    priorityFiles.clear();
    priorityFiles.addAll(files);
    // Set priority files in drivers.
    driverMap.values.forEach((driver) {
      driver.priorityFiles = files;
    });
  }

  @override
  Future<void> shutdown() {
    super.shutdown();

    pubApi.close();

    var analytics = options.analytics;
    if (analytics != null) {
      analytics.waitForLastPing(timeout: Duration(milliseconds: 200)).then((_) {
        analytics.close();
      });
    }

    detachableFileSystemManager?.dispose();

    // Defer closing the channel and shutting down the instrumentation server so
    // that the shutdown response can be sent and logged.
    Future(() {
      instrumentationService.shutdown();
      channel.close();
    });

    return Future.value();
  }

  /// Implementation for `analysis.updateContent`.
  void updateContent(String id, Map<String, dynamic> changes) {
    _onAnalysisSetChangedController.add(null);
    changes.forEach((file, change) {
      // Prepare the old overlay contents.
      String? oldContents;
      try {
        if (resourceProvider.hasOverlay(file)) {
          oldContents = resourceProvider.getFile(file).readAsStringSync();
        }
      } catch (_) {}

      // Prepare the new contents.
      String? newContents;
      if (change is AddContentOverlay) {
        newContents = change.content;
      } else if (change is ChangeContentOverlay) {
        if (oldContents == null) {
          // The client may only send a ChangeContentOverlay if there is
          // already an existing overlay for the source.
          throw RequestFailure(Response(id,
              error: RequestError(RequestErrorCode.INVALID_OVERLAY_CHANGE,
                  'Invalid overlay change')));
        }
        try {
          newContents = SourceEdit.applySequence(oldContents, change.edits);
        } on RangeError {
          throw RequestFailure(Response(id,
              error: RequestError(RequestErrorCode.INVALID_OVERLAY_CHANGE,
                  'Invalid overlay change')));
        }
      } else if (change is RemoveContentOverlay) {
        newContents = null;
      } else {
        // Protocol parsing should have ensured that we never get here.
        throw AnalysisException('Illegal change type');
      }

      if (newContents != null) {
        resourceProvider.setOverlay(
          file,
          content: newContents,
          modificationStamp: overlayModificationStamp++,
        );
      } else {
        resourceProvider.removeOverlay(file);
      }

      driverMap.values.forEach((driver) {
        driver.changeFile(file);
      });

      // If the file did not exist, and is "overlay only", it still should be
      // analyzed. Add it to driver to which it should have been added.
      contextManager.getDriverFor(file)?.addFile(file);

      notifyDeclarationsTracker(file);
      notifyFlutterWidgetDescriptions(file);

      // TODO(scheglov) implement other cases
    });
  }

  /// Use the given updaters to update the values of the options in every
  /// existing analysis context.
  void updateOptions(List<OptionUpdater> optionUpdaters) {
    // TODO(scheglov) implement for the new analysis driver
//    //
//    // Update existing contexts.
//    //
//    for (AnalysisContext context in analysisContexts) {
//      AnalysisOptionsImpl options =
//          new AnalysisOptionsImpl.from(context.analysisOptions);
//      optionUpdaters.forEach((OptionUpdater optionUpdater) {
//        optionUpdater(options);
//      });
//      context.analysisOptions = options;
//      // TODO(brianwilkerson) As far as I can tell, this doesn't cause analysis
//      // to be scheduled for this context.
//    }
//    //
//    // Update the defaults used to create new contexts.
//    //
//    optionUpdaters.forEach((OptionUpdater optionUpdater) {
//      optionUpdater(defaultContextOptions);
//    });
  }

  /// Returns `true` if there is a subscription for the given [service] and
  /// [file].
  bool _hasAnalysisServiceSubscription(AnalysisService service, String file) {
    return analysisServices[service]?.contains(file) ?? false;
  }

  bool _hasFlutterServiceSubscription(FlutterService service, String file) {
    return flutterServices[service]?.contains(file) ?? false;
  }

  Future<void> _scheduleAnalysisImplementedNotification() async {
    var files = analysisServices[AnalysisService.IMPLEMENTED];
    if (files != null) {
      scheduleImplementedNotification(this, files);
    }
  }

  void _sendSubscriptions({bool analysis = false, bool flutter = false}) {
    var files = <String>{};

    if (analysis) {
      analysisServices.values.forEach((serviceFiles) {
        files.addAll(serviceFiles);
      });
    }

    if (flutter) {
      flutterServices.values.forEach((serviceFiles) {
        files.addAll(serviceFiles);
      });
    }

    for (var file in files) {
      // The result will be produced by the "results" stream with
      // the fully resolved unit, and processed with sending analysis
      // notifications as it happens after content changes.
      if (file_paths.isDart(resourceProvider.pathContext, file)) {
        getResolvedUnit(file, sendCachedToStream: true);
      }
    }
  }
}

/// Various IDE options.
class AnalysisServerOptions {
  String? newAnalysisDriverLog;

  String? clientId;
  String? clientVersion;

  /// Base path where to cache data.
  String? cacheFolder;

  /// The analytics instance; note, this object can be `null`, and should be
  /// accessed via a null-aware operator.
  telemetry.Analytics? analytics;

  /// The crash report sender instance; note, this object can be `null`, and
  /// should be accessed via a null-aware operator.
  CrashReportSender? crashReportSender;

  /// An optional set of configuration overrides specified by the SDK.
  ///
  /// These overrides can provide new values for configuration settings, and are
  /// generally used in specific SDKs (like the internal google3 one).
  SdkConfiguration? configurationOverrides;

  /// Whether to use the Language Server Protocol.
  bool useLanguageServerProtocol = false;

  /// The set of enabled features.
  FeatureSet featureSet = FeatureSet();
}

class ServerContextManagerCallbacks extends ContextManagerCallbacks {
  final AnalysisServer analysisServer;

  /// The [ResourceProvider] by which paths are converted into [Resource]s.
  final ResourceProvider resourceProvider;

  /// The set of files for which notifications were sent.
  final Set<String> filesToFlush = {};

  ServerContextManagerCallbacks(this.analysisServer, this.resourceProvider);

  AbstractNotificationManager get _notificationManager =>
      analysisServer.notificationManager;

  @override
  void afterContextsCreated() {
    analysisServer.addContextsToDeclarationsTracker();
    analysisServer._sendSubscriptions(analysis: true, flutter: true);
  }

  @override
  void afterContextsDestroyed() {
    sendAnalysisNotificationFlushResults(
      analysisServer,
      filesToFlush.toList(),
    );
    filesToFlush.clear();
  }

  @override
  void afterWatchEvent(WatchEvent event) {
    analysisServer._onAnalysisSetChangedController.add(null);
  }

  @override
  void applyFileRemoved(String file) {
    sendAnalysisNotificationFlushResults(analysisServer, [file]);
    filesToFlush.remove(file);
  }

  @override
  void broadcastWatchEvent(WatchEvent event) {
    analysisServer.notifyDeclarationsTracker(event.path);
    analysisServer.notifyFlutterWidgetDescriptions(event.path);
    analysisServer.pluginManager.broadcastWatchEvent(event);
  }

  @override
  void listenAnalysisDriver(analysis.AnalysisDriver analysisDriver) {
    analysisDriver.results.listen((result) {
      if (result is FileResult) {
        _handleFileResult(result);
      }
    });
    analysisDriver.exceptions.listen(analysisServer.logExceptionResult);
    analysisDriver.priorityFiles = analysisServer.priorityFiles.toList();
  }

  @override
  void pubspecChanged(String pubspecPath) {
    analysisServer.pubPackageService.fetchPackageVersionsViaPubOutdated(
        pubspecPath,
        pubspecWasModified: true);
  }

  @override
  void pubspecRemoved(String pubspecPath) {
    analysisServer.pubPackageService.flushPackageCaches(pubspecPath);
  }

  @override
  void recordAnalysisErrors(String path, List<AnalysisError> errors) {
    filesToFlush.add(path);
    _notificationManager.recordAnalysisErrors(
        NotificationManager.serverId, path, errors);
  }

  List<HighlightRegion> _computeHighlightRegions(CompilationUnit unit) {
    return DartUnitHighlightsComputer(unit).compute();
  }

  server.AnalysisNavigationParams _computeNavigationParams(
      String path, CompilationUnit unit) {
    var collector = NavigationCollectorImpl();
    computeDartNavigation(resourceProvider, collector, unit, null, null,
        analyzerConverter: AnalyzerConverter(
            locationProvider:
                MacroElementLocationProvider(MacroFiles(resourceProvider))));
    collector.createRegions();
    return server.AnalysisNavigationParams(
        path, collector.regions, collector.targets, collector.files);
  }

  List<Occurrences> _computeOccurrences(CompilationUnit unit) {
    var collector = OccurrencesCollectorImpl();
    addDartOccurrences(collector, unit);
    return collector.allOccurrences;
  }

  void _handleFileResult(FileResult result) {
    var path = result.path;
    filesToFlush.add(path);

    if (result is AnalysisResultWithErrors) {
      if (analysisServer.isAnalyzed(path)) {
        _notificationManager.recordAnalysisErrors(NotificationManager.serverId,
            path, server.doAnalysisError_listFromEngine(result));
      }
    }

    if (result is ResolvedUnitResult) {
      _handleResolvedUnitResult(result);
    }
  }

  void _handleResolvedUnitResult(ResolvedUnitResult result) {
    var path = result.path;

    analysisServer.getDocumentationCacheFor(result)?.cacheFromResult(result);
    analysisServer.getExtensionCacheFor(result)?.cacheFromResult(result);

    var unit = result.unit;
    if (analysisServer._hasAnalysisServiceSubscription(
        AnalysisService.HIGHLIGHTS, path)) {
      _runDelayed(() {
        _notificationManager.recordHighlightRegions(
            NotificationManager.serverId, path, _computeHighlightRegions(unit));
      });
    }
    if (analysisServer._hasAnalysisServiceSubscription(
        AnalysisService.NAVIGATION, path)) {
      _runDelayed(() {
        _notificationManager.recordNavigationParams(
            NotificationManager.serverId,
            path,
            _computeNavigationParams(path, unit));
      });
    }
    if (analysisServer._hasAnalysisServiceSubscription(
        AnalysisService.OCCURRENCES, path)) {
      _runDelayed(() {
        _notificationManager.recordOccurrences(
            NotificationManager.serverId, path, _computeOccurrences(unit));
      });
    }
    // if (analysisServer._hasAnalysisServiceSubscription(
    //     AnalysisService.OUTLINE, path)) {
    //   _runDelayed(() {
    //     // TODO(brianwilkerson) Change NotificationManager to store params
    //     // so that fileKind and libraryName can be recorded / passed along.
    //     notificationManager.recordOutlines(NotificationManager.serverId, path,
    //         _computeOutlineParams(path, unit, result.lineInfo));
    //   });
    // }
    if (analysisServer._hasAnalysisServiceSubscription(
        AnalysisService.CLOSING_LABELS, path)) {
      _runDelayed(() {
        sendAnalysisNotificationClosingLabels(
            analysisServer, path, result.lineInfo, unit);
      });
    }
    if (analysisServer._hasAnalysisServiceSubscription(
        AnalysisService.FOLDING, path)) {
      _runDelayed(() {
        sendAnalysisNotificationFolding(
            analysisServer, path, result.lineInfo, unit);
      });
    }
    if (analysisServer._hasAnalysisServiceSubscription(
        AnalysisService.OUTLINE, path)) {
      _runDelayed(() {
        sendAnalysisNotificationOutline(analysisServer, result);
      });
    }
    if (analysisServer._hasAnalysisServiceSubscription(
        AnalysisService.OVERRIDES, path)) {
      _runDelayed(() {
        sendAnalysisNotificationOverrides(analysisServer, path, unit);
      });
    }
    if (analysisServer._hasFlutterServiceSubscription(
        FlutterService.OUTLINE, path)) {
      _runDelayed(() {
        sendFlutterNotificationOutline(analysisServer, result);
      });
    }
  }

  /// Run [f] in a new [Future].
  ///
  /// This method is used to delay sending notifications. If there is a more
  /// important consumer of an analysis results, specifically a code completion
  /// computer, we want it to run before spending time of sending notifications.
  ///
  /// TODO(scheglov) Consider replacing this with full priority based scheduler.
  ///
  /// TODO(scheglov) Alternatively, if code completion work in a way that does
  /// not produce (at first) fully resolved unit, but only part of it - a single
  /// method, or a top-level declaration, we would not have this problem - the
  /// completion computer would be the only consumer of the partial analysis
  /// result.
  void _runDelayed(Function() f) {
    Future(f);
  }
}

/// Used to record server exceptions.
class ServerException {
  final String message;
  final dynamic exception;
  final StackTrace stackTrace;
  final bool fatal;

  ServerException(this.message, this.exception, this.stackTrace, this.fatal);

  @override
  String toString() => message;
}

/// A class used by [AnalysisServer] to record performance information
/// such as request latency.
class ServerPerformance {
  /// The creation time and the time when performance information
  /// started to be recorded here.
  final int startTime = DateTime.now().millisecondsSinceEpoch;

  /// The number of requests.
  int requestCount = 0;

  /// The number of requests that recorded latency information.
  int latencyCount = 0;

  /// The total latency (milliseconds) for all recorded requests.
  int requestLatency = 0;

  /// The maximum latency (milliseconds) for all recorded requests.
  int maxLatency = 0;

  /// The number of requests with latency > 150 milliseconds.
  int slowRequestCount = 0;

  /// Log timing information for a request.
  void logRequestTiming(int? clientRequestTime) {
    ++requestCount;
    if (clientRequestTime != null) {
      var latency = DateTime.now().millisecondsSinceEpoch - clientRequestTime;
      ++latencyCount;
      requestLatency += latency;
      maxLatency = max(maxLatency, latency);
      if (latency > 150) {
        ++slowRequestCount;
      }
    }
  }
}
