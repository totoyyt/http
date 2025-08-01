// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:http/http.dart';
import 'package:http_profile/http_profile.dart';
import 'package:objective_c/objective_c.dart';

import 'cupertino_api.dart';

final _digitRegex = RegExp(r'^\d+$');

const _nsurlErrorCancelled = -999;

/// A [ClientException] generated from an [NSError].
class NSErrorClientException extends ClientException {
  final NSError error;

  NSErrorClientException(this.error, [Uri? uri])
      : super(error.localizedDescription.toDartString(), uri);

  @override
  String toString() {
    final b = StringBuffer(
        'NSErrorClientException: ${error.localizedDescription.toDartString()} '
        '[domain=${error.domain.toDartString()}, code=${error.code}]');

    if (uri != null) {
      b.write(', uri=$uri');
    }
    return b.toString();
  }
}

/// This class can be removed when `package:http` v2 is released.
class _StreamedResponseWithUrl extends StreamedResponse
    implements BaseResponseWithUrl {
  @override
  final Uri url;

  _StreamedResponseWithUrl(super.stream, super.statusCode,
      {required this.url,
      super.contentLength,
      super.request,
      super.headers,
      super.isRedirect,
      super.reasonPhrase});
}

class _TaskTracker {
  final responseCompleter = Completer<URLResponse>();
  final BaseRequest request;
  final StreamController<Uint8List> responseController;

  /// Whether the response stream subscription has been cancelled.
  bool responseListenerCancelled = false;
  bool requestAborted = false;
  final HttpClientRequestProfile? profile;
  int numRedirects = 0;
  Uri? lastUrl; // The last URL redirected to.

  _TaskTracker(this.request, this.responseController, this.profile);

  void close() {
    responseController.close();
  }
}

/// A HTTP [Client] based on the
/// [Foundation URL Loading System](https://developer.apple.com/documentation/foundation/url_loading_system).
///
/// For example:
/// ```
/// void main() async {
///   var client = CupertinoClient.defaultSessionConfiguration();
///   final response = await client.get(
///       Uri.https('www.googleapis.com', '/books/v1/volumes', {'q': '{http}'}));
///   if (response.statusCode != 200) {
///     throw HttpException('bad response: ${response.statusCode}');
///   }
///
///   final decodedResponse =
///       jsonDecode(utf8.decode(response.bodyBytes)) as Map;
///
///   final itemCount = decodedResponse['totalItems'];
///   print('Number of books about http: $itemCount.');
///   for (var i = 0; i < min(itemCount, 10); ++i) {
///     print(decodedResponse['items'][i]['volumeInfo']['title']);
///   }
/// }
/// ```
class CupertinoClient extends BaseClient {
  static final Map<URLSessionTask, _TaskTracker> _tasks = {};

  URLSession? _urlSession;

  CupertinoClient._(this._urlSession);

  String? _findReasonPhrase(int statusCode) {
    switch (statusCode) {
      case HttpStatus.continue_:
        return 'Continue';
      case HttpStatus.switchingProtocols:
        return 'Switching Protocols';
      case HttpStatus.ok:
        return 'OK';
      case HttpStatus.created:
        return 'Created';
      case HttpStatus.accepted:
        return 'Accepted';
      case HttpStatus.nonAuthoritativeInformation:
        return 'Non-Authoritative Information';
      case HttpStatus.noContent:
        return 'No Content';
      case HttpStatus.resetContent:
        return 'Reset Content';
      case HttpStatus.partialContent:
        return 'Partial Content';
      case HttpStatus.multipleChoices:
        return 'Multiple Choices';
      case HttpStatus.movedPermanently:
        return 'Moved Permanently';
      case HttpStatus.found:
        return 'Found';
      case HttpStatus.seeOther:
        return 'See Other';
      case HttpStatus.notModified:
        return 'Not Modified';
      case HttpStatus.useProxy:
        return 'Use Proxy';
      case HttpStatus.temporaryRedirect:
        return 'Temporary Redirect';
      case HttpStatus.badRequest:
        return 'Bad Request';
      case HttpStatus.unauthorized:
        return 'Unauthorized';
      case HttpStatus.paymentRequired:
        return 'Payment Required';
      case HttpStatus.forbidden:
        return 'Forbidden';
      case HttpStatus.notFound:
        return 'Not Found';
      case HttpStatus.methodNotAllowed:
        return 'Method Not Allowed';
      case HttpStatus.notAcceptable:
        return 'Not Acceptable';
      case HttpStatus.proxyAuthenticationRequired:
        return 'Proxy Authentication Required';
      case HttpStatus.requestTimeout:
        return 'Request Time-out';
      case HttpStatus.conflict:
        return 'Conflict';
      case HttpStatus.gone:
        return 'Gone';
      case HttpStatus.lengthRequired:
        return 'Length Required';
      case HttpStatus.preconditionFailed:
        return 'Precondition Failed';
      case HttpStatus.requestEntityTooLarge:
        return 'Request Entity Too Large';
      case HttpStatus.requestUriTooLong:
        return 'Request-URI Too Long';
      case HttpStatus.unsupportedMediaType:
        return 'Unsupported Media Type';
      case HttpStatus.requestedRangeNotSatisfiable:
        return 'Requested range not satisfiable';
      case HttpStatus.expectationFailed:
        return 'Expectation Failed';
      case HttpStatus.internalServerError:
        return 'Internal Server Error';
      case HttpStatus.notImplemented:
        return 'Not Implemented';
      case HttpStatus.badGateway:
        return 'Bad Gateway';
      case HttpStatus.serviceUnavailable:
        return 'Service Unavailable';
      case HttpStatus.gatewayTimeout:
        return 'Gateway Time-out';
      case HttpStatus.httpVersionNotSupported:
        return 'Http Version not supported';
      default:
        return null;
    }
  }

  static _TaskTracker _tracker(URLSessionTask task) => _tasks[task]!;

  static void _onComplete(
      URLSession session, URLSessionTask task, NSError? error) {
    final taskTracker = _tracker(task);

    // There are two ways that the request can be cancelled:
    // 1. The user calls `StreamedResponse.stream.cancel()`, which can only
    //    happen if the response has already been received.
    // 2. The user aborts the request, which can happen at any point in the
    //    request lifecycle and causes `CupertinoClient.send` to throw
    //    a `RequestAbortedException` exception.
    final isCancelError = error?.domain.toDartString() == 'NSURLErrorDomain' &&
        error?.code == _nsurlErrorCancelled;
    if (error != null &&
        !(isCancelError && taskTracker.responseListenerCancelled)) {
      final Exception exception;
      if (isCancelError) {
        exception = RequestAbortedException();
      } else {
        exception = NSErrorClientException(error, taskTracker.request.url);
      }
      if (taskTracker.profile != null &&
          taskTracker.profile!.requestData.endTime == null) {
        // Error occurred during the request.
        taskTracker.profile!.requestData.closeWithError(exception.toString());
      } else {
        // Error occurred during the response.
        taskTracker.profile?.responseData.closeWithError(exception.toString());
      }
      if (taskTracker.responseCompleter.isCompleted) {
        taskTracker.responseController.addError(exception);
      } else {
        taskTracker.responseCompleter.completeError(exception);
      }
    } else {
      assert(error == null || taskTracker.responseListenerCancelled);
      assert(taskTracker.profile == null ||
          taskTracker.profile!.requestData.endTime != null);

      taskTracker.profile?.responseData.close();
      if (!taskTracker.responseCompleter.isCompleted) {
        taskTracker.responseCompleter.completeError(
            StateError('task completed without an error or response'));
      }
    }
    taskTracker.close();
    _tasks.remove(task);
  }

  static void _onData(URLSession session, URLSessionTask task, NSData data) {
    final taskTracker = _tracker(task);
    if (taskTracker.responseListenerCancelled || taskTracker.requestAborted) {
      return;
    }
    taskTracker.responseController.add(data.toList());
    taskTracker.profile?.responseData.bodySink.add(data.toList());
  }

  static URLRequest? _onRedirect(URLSession session, URLSessionTask task,
      HTTPURLResponse response, URLRequest request) {
    final taskTracker = _tracker(task);
    ++taskTracker.numRedirects;
    if (taskTracker.request.followRedirects &&
        taskTracker.numRedirects <= taskTracker.request.maxRedirects) {
      taskTracker.profile?.responseData.addRedirect(HttpProfileRedirectData(
          statusCode: response.statusCode,
          method: request.httpMethod,
          location: request.url!.toString()));
      taskTracker.lastUrl = request.url;
      return request;
    }
    return null;
  }

  static NSURLSessionResponseDisposition _onResponse(
      URLSession session, URLSessionTask task, URLResponse response) {
    final taskTracker = _tracker(task);
    taskTracker.responseCompleter.complete(response);
    unawaited(taskTracker.profile?.requestData.close());

    return NSURLSessionResponseDisposition.NSURLSessionResponseAllow;
  }

  /// A [Client] with the default configuration.
  factory CupertinoClient.defaultSessionConfiguration() {
    final config = URLSessionConfiguration.defaultSessionConfiguration();
    return CupertinoClient.fromSessionConfiguration(config);
  }

  /// A [Client] configured with a [URLSessionConfiguration].
  factory CupertinoClient.fromSessionConfiguration(
      URLSessionConfiguration config) {
    final session = URLSession.sessionWithConfiguration(config,
        onComplete: _onComplete,
        onData: _onData,
        onRedirect: _onRedirect,
        onResponse: _onResponse);
    return CupertinoClient._(session);
  }

  @override
  void close() {
    _urlSession?.finishTasksAndInvalidate();
    _urlSession = null;
  }

  /// Returns true if [stream] includes at least one list with an element.
  ///
  /// Since [_hasData] consumes [stream], returns a new stream containing the
  /// equivalent data.
  static Future<(bool, Stream<List<int>>)> _hasData(
      Stream<List<int>> stream) async {
    final queue = StreamQueue(stream);
    while (await queue.hasNext && (await queue.peek).isEmpty) {
      await queue.next;
    }

    return (await queue.hasNext, queue.rest);
  }

  HttpClientRequestProfile? _createProfile(BaseRequest request) =>
      HttpClientRequestProfile.profile(
          requestStartTime: DateTime.now(),
          requestMethod: request.method,
          requestUri: request.url.toString());

  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    // The expected success case flow (without redirects) is:
    // 1. send is called by BaseClient
    // 2. send starts the request with UrlSession.dataTaskWithRequest and waits
    //    on a Completer
    // 3. _onResponse is called with the HTTP headers, status code, etc.
    // 4. _onResponse calls complete on the Completer that send is waiting on.
    // 5. send continues executing and returns a StreamedResponse.
    //    StreamedResponse contains a Stream<UInt8List>.
    // 6. _onData is called one or more times and adds that to the
    //    StreamController that controls the Stream<UInt8List>
    // 7. _onComplete is called after all the data is read and closes the
    //    StreamController
    if (_urlSession == null) {
      throw ClientException(
          'HTTP request failed. Client is already closed.', request.url);
    }
    final urlSession = _urlSession!;

    final stream = request.finalize();

    final profile = _createProfile(request);
    profile?.connectionInfo = {
      'package': 'package:cupertino_http',
      'client': 'CupertinoClient',
      'configuration': _urlSession!.configuration.toString(),
    };
    profile?.requestData
      ?..contentLength = request.contentLength
      ..followRedirects = request.followRedirects
      ..headersCommaValues = request.headers
      ..maxRedirects = request.maxRedirects;

    final urlRequest = MutableURLRequest.fromUrl(request.url)
      ..httpMethod = request.method;

    if (request.contentLength != null) {
      profile?.requestData.headersListValues = {
        'Content-Length': ['${request.contentLength}'],
        ...profile.requestData.headers!
      };
      urlRequest.setValueForHttpHeaderField(
          'Content-Length', '${request.contentLength}');
    }

    NSInputStream? nsStream;
    if (request is Request) {
      // Optimize the (typical) `Request` case since assigning to
      // `httpBodyStream` requires a lot of expensive setup and data passing.
      urlRequest.httpBody = request.bodyBytes.toNSData();
      profile?.requestData.bodySink.add(request.bodyBytes);
    } else if (await _hasData(stream) case (true, final s)) {
      // If the request is supposed to be bodyless (e.g. GET requests)
      // then setting `httpBodyStream` will cause the request to fail -
      // even if the stream is empty.
      if (profile == null) {
        nsStream = s.toNSInputStream();
        urlRequest.httpBodyStream = nsStream;
      } else {
        final splitter = StreamSplitter(s);
        nsStream = splitter.split().toNSInputStream();
        urlRequest.httpBodyStream = nsStream;
        unawaited(profile.requestData.bodySink.addStream(splitter.split()));
      }
    }

    // This will preserve Apple default headers - is that what we want?
    request.headers.forEach(urlRequest.setValueForHttpHeaderField);
    final task = urlSession.dataTaskWithRequest(urlRequest);
    if (request case Abortable(:final abortTrigger?)) {
      unawaited(abortTrigger.whenComplete(() {
        final taskTracker = _tasks[task];
        if (taskTracker == null) return;
        taskTracker.requestAborted = true;
        task.cancel();
      }));
    }

    final subscription = StreamController<Uint8List>(onCancel: () {
      final taskTracker = _tasks[task];
      if (taskTracker == null) return;
      taskTracker.responseListenerCancelled = true;
      task.cancel();
    });
    final taskTracker = _TaskTracker(request, subscription, profile);
    _tasks[task] = taskTracker;
    task.resume();

    final maxRedirects = request.followRedirects ? request.maxRedirects : 0;

    late URLResponse result;
    try {
      result = await taskTracker.responseCompleter.future;
    } finally {
      // If the request is aborted before the `NSUrlSessionTask` opens the
      // `NSInputStream` attached to `NSMutableURLRequest.HTTPBodyStream`, then
      // the task will not close the `NSInputStream`.
      //
      // This will cause the Dart portion of the `NSInputStream` implementation
      // to hang waiting for a close message.
      //
      // See https://github.com/dart-lang/native/issues/2333
      if (nsStream?.streamStatus != NSStreamStatus.NSStreamStatusClosed) {
        nsStream?.close();
      }
    }

    final response = result as HTTPURLResponse;

    if (request.followRedirects && taskTracker.numRedirects > maxRedirects) {
      throw ClientException('Redirect limit exceeded', request.url);
    }

    final responseHeaders = response.allHeaderFields
        .map((key, value) => MapEntry(key.toLowerCase(), value));

    if (responseHeaders['content-length'] case final contentLengthHeader?
        when !_digitRegex.hasMatch(contentLengthHeader)) {
      throw ClientException(
        'Invalid content-length header [$contentLengthHeader].',
        request.url,
      );
    }

    final contentLength = response.expectedContentLength == -1
        ? null
        : response.expectedContentLength;
    final isRedirect = !request.followRedirects && taskTracker.numRedirects > 0;
    profile?.responseData
      ?..contentLength = contentLength
      ..headersCommaValues = responseHeaders
      ..isRedirect = isRedirect
      ..reasonPhrase = _findReasonPhrase(response.statusCode)
      ..startTime = DateTime.now()
      ..statusCode = response.statusCode;

    return _StreamedResponseWithUrl(
      taskTracker.responseController.stream,
      response.statusCode,
      url: taskTracker.lastUrl ?? request.url,
      contentLength: contentLength,
      reasonPhrase: _findReasonPhrase(response.statusCode),
      request: request,
      isRedirect: isRedirect,
      headers: responseHeaders,
    );
  }
}

/// A test-only class that makes the [HttpClientRequestProfile] data available.
class CupertinoClientWithProfile extends CupertinoClient {
  HttpClientRequestProfile? profile;

  @override
  HttpClientRequestProfile? _createProfile(BaseRequest request) =>
      profile = super._createProfile(request);

  CupertinoClientWithProfile._(super._urlSession) : super._();

  factory CupertinoClientWithProfile.defaultSessionConfiguration() {
    final config = URLSessionConfiguration.defaultSessionConfiguration();
    final session = URLSession.sessionWithConfiguration(config,
        onComplete: CupertinoClient._onComplete,
        onData: CupertinoClient._onData,
        onRedirect: CupertinoClient._onRedirect,
        onResponse: CupertinoClient._onResponse);
    return CupertinoClientWithProfile._(session);
  }
}
