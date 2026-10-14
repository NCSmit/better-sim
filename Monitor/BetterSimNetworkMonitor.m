// BetterSim loads this into a simulator app through DYLD_INSERT_LIBRARIES. Every http(s) request the app makes with
// URLSession is re-issued through an internal session, recorded, and posted as JSON to BetterSim's listener on
// http://127.0.0.1:$BETTERSIM_MONITOR_PORT/events. Without that variable the library does nothing.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *const BetterSimHandledKey = @"local.bettersim.network-monitor.handled";
static const NSUInteger BetterSimRequestBodyLimit = 64 * 1024;
static const NSUInteger BetterSimResponseBodyLimit = 256 * 1024;

typedef NSURLSessionConfiguration *(*BetterSimConfigurationFactory)(id, SEL);

static NSURL *BetterSimEventsURL;
static BetterSimConfigurationFactory BetterSimOriginalDefaultConfiguration;
static BetterSimConfigurationFactory BetterSimOriginalEphemeralConfiguration;

@interface BetterSimURLProtocol : NSURLProtocol
- (void)performOnClientThread:(dispatch_block_t)block;
- (void)forwardResponse:(NSURLResponse *)response;
- (void)forwardData:(NSData *)data;
- (void)forwardRedirectTo:(NSURLRequest *)request response:(NSHTTPURLResponse *)response;
- (void)finishWithError:(NSError *)error;
@end

/// One session re-issues every captured request. Its delegate hands each callback to the protocol instance that owns
/// the task, on that instance's client thread.
@interface BetterSimTaskRouter : NSObject <NSURLSessionDataDelegate>
+ (instancetype)shared;
- (NSURLSessionDataTask *)startTaskWithRequest:(NSURLRequest *)request for:(BetterSimURLProtocol *)protocol;
@end

static NSData *BetterSimReadStream(NSInputStream *stream) {
    NSMutableData *data = [NSMutableData data];
    if (stream.streamStatus == NSStreamStatusNotOpen) [stream open];
    uint8_t buffer[16 * 1024];
    NSInteger count;
    while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    [stream close];
    return data;
}

static NSDictionary<NSString *, NSString *> *BetterSimStringHeaders(NSDictionary *headers) {
    NSMutableDictionary<NSString *, NSString *> *strings = [NSMutableDictionary dictionary];
    [headers enumerateKeysAndObjectsUsingBlock:^(id name, id value, BOOL *stop) {
        strings[[name description]] = [value description];
    }];
    return strings;
}

static NSString *BetterSimBase64Prefix(NSData *data, NSUInteger limit) {
    NSData *prefix = data.length > limit ? [data subdataWithRange:NSMakeRange(0, limit)] : data;
    return [prefix base64EncodedStringWithOptions:0];
}

static BOOL BetterSimIsEventsURL(NSURL *url) {
    return [url.host isEqualToString:BetterSimEventsURL.host] && [url.port isEqual:BetterSimEventsURL.port]
        && [url.path isEqualToString:BetterSimEventsURL.path];
}

static NSURLSession *BetterSimReportSession(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *configuration = BetterSimOriginalEphemeralConfiguration(NSURLSessionConfiguration.class, @selector(ephemeralSessionConfiguration));
        configuration.timeoutIntervalForRequest = 10;
        session = [NSURLSession sessionWithConfiguration:configuration];
    });
    return session;
}

static void BetterSimPost(NSDictionary *event) {
    if (![NSJSONSerialization isValidJSONObject:event]) return;
    NSData *body = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if (!body) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:BetterSimEventsURL];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [NSURLProtocol setProperty:@YES forKey:BetterSimHandledKey inRequest:request];
    [[BetterSimReportSession() uploadTaskWithRequest:request fromData:body completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {}] resume];
}

@implementation BetterSimURLProtocol {
    NSThread *_clientThread;
    NSArray<NSString *> *_clientModes;
    NSURLSessionDataTask *_forwardedTask;
    NSDate *_startDate;
    NSTimeInterval _startUptime;
    NSData *_requestBody;
    NSURLResponse *_response;
    NSMutableData *_responseBody;
    unsigned long long _responseBodySize;
    NSMutableData *_redirectBody;
    BOOL _redirected;
    BOOL _stopped;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *scheme = request.URL.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    if ([NSURLProtocol propertyForKey:BetterSimHandledKey inRequest:request]) return NO;
    return !BetterSimIsEventsURL(request.URL);
}

+ (BOOL)canInitWithTask:(NSURLSessionTask *)task {
    // A WebSocket upgrade can't be re-issued as a data task.
    if ([task isKindOfClass:NSURLSessionWebSocketTask.class] || !task.currentRequest) return NO;
    return [self canInitWithRequest:task.currentRequest];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    // URLProtocol clients expect every callback on the thread, and in the run loop mode, that started the load.
    _clientThread = NSThread.currentThread;
    NSString *mode = NSRunLoop.currentRunLoop.currentMode;
    _clientModes = mode && ![mode isEqualToString:NSDefaultRunLoopMode] ? @[NSDefaultRunLoopMode, mode] : @[NSDefaultRunLoopMode];
    _startDate = [NSDate date];
    _startUptime = NSProcessInfo.processInfo.systemUptime;
    _responseBody = [NSMutableData data];

    NSMutableURLRequest *request = [self.request mutableCopy];
    _requestBody = self.request.HTTPBody;
    // URLSession hands protocols the body as a stream, which can only be read once, so it's read here and resent as data.
    if (!_requestBody && self.request.HTTPBodyStream) {
        _requestBody = BetterSimReadStream(self.request.HTTPBodyStream);
        request.HTTPBody = _requestBody;
    }
    [NSURLProtocol setProperty:@YES forKey:BetterSimHandledKey inRequest:request];
    _forwardedTask = [BetterSimTaskRouter.shared startTaskWithRequest:request for:self];
}

- (void)stopLoading {
    _stopped = YES;
    [_forwardedTask cancel];
}

- (void)performOnClientThread:(dispatch_block_t)block {
    [self performSelector:@selector(runBlock:) onThread:_clientThread withObject:[block copy] waitUntilDone:NO modes:_clientModes];
}

- (void)runBlock:(dispatch_block_t)block {
    block();
}

- (void)forwardResponse:(NSURLResponse *)response {
    _response = response;
    if (!_stopped && !_redirected) [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
}

- (void)forwardData:(NSData *)data {
    _responseBodySize += data.length;
    if (_responseBody.length < BetterSimResponseBodyLimit) {
        NSUInteger room = BetterSimResponseBodyLimit - _responseBody.length;
        [_responseBody appendData:data.length <= room ? data : [data subdataWithRange:NSMakeRange(0, room)]];
    }
    if (_redirected) {
        [_redirectBody appendData:data];
    } else if (!_stopped) {
        [self.client URLProtocol:self didLoadData:data];
    }
}

/// The internal task doesn't follow redirects, the client decides. To follow, it stops this load and starts a new one
/// for the redirect, which is recorded as a request of its own. The 3xx response is held back until then, because
/// handing it over first makes the client finish the task with no response at all.
- (void)forwardRedirectTo:(NSURLRequest *)request response:(NSHTTPURLResponse *)response {
    _redirected = YES;
    _response = response;
    _redirectBody = [NSMutableData data];
    if (_stopped) return;
    NSMutableURLRequest *redirect = [request mutableCopy];
    [NSURLProtocol removePropertyForKey:BetterSimHandledKey inRequest:redirect];
    [self.client URLProtocol:self wasRedirectedToRequest:redirect redirectResponse:response];
}

- (void)finishWithError:(NSError *)error {
    BOOL followedRedirect = _redirected && [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled;
    [self postEventWithError:followedRedirect ? nil : error];
    if (_stopped) return;
    if (_redirected) {
        // A client that follows stops this load within milliseconds. One that hasn't by then refused the redirect,
        // and gets the 3xx response itself.
        [self performSelector:@selector(deliverRefusedRedirect:) withObject:error afterDelay:0.5 inModes:_clientModes];
    } else {
        [self completeWithError:error];
    }
}

- (void)deliverRefusedRedirect:(NSError *)error {
    if (_stopped) return;
    [self.client URLProtocol:self didReceiveResponse:_response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (_redirectBody.length > 0) [self.client URLProtocol:self didLoadData:_redirectBody];
    [self completeWithError:error];
}

- (void)completeWithError:(NSError *)error {
    if (error) {
        [self.client URLProtocol:self didFailWithError:error];
    } else {
        [self.client URLProtocolDidFinishLoading:self];
    }
}

- (void)postEventWithError:(NSError *)error {
    NSMutableDictionary<NSString *, id> *event = [NSMutableDictionary dictionary];
    event[@"id"] = NSUUID.UUID.UUIDString;
    // Command line tools have no bundle identifier, so they're named after their process.
    event[@"bundleID"] = NSBundle.mainBundle.bundleIdentifier ?: NSProcessInfo.processInfo.processName;
    event[@"method"] = self.request.HTTPMethod ?: @"GET";
    event[@"url"] = self.request.URL.absoluteString ?: @"";
    event[@"requestHeaders"] = BetterSimStringHeaders(self.request.allHTTPHeaderFields);
    event[@"requestBodySize"] = @(_requestBody.length);
    if (_requestBody.length > 0) event[@"requestBody"] = BetterSimBase64Prefix(_requestBody, BetterSimRequestBodyLimit);
    NSHTTPURLResponse *response = [_response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)_response : nil;
    if (response) event[@"status"] = @(response.statusCode);
    event[@"responseHeaders"] = BetterSimStringHeaders(response.allHeaderFields);
    event[@"responseBodySize"] = @(_responseBodySize);
    if (_responseBody.length > 0) event[@"responseBody"] = [_responseBody base64EncodedStringWithOptions:0];
    event[@"startedAt"] = @(_startDate.timeIntervalSince1970);
    event[@"duration"] = @(NSProcessInfo.processInfo.systemUptime - _startUptime);
    if (error) event[@"error"] = error.localizedDescription;
    BetterSimPost(event);
}

@end

@implementation BetterSimTaskRouter {
    NSURLSession *_session;
    NSMutableDictionary<NSNumber *, BetterSimURLProtocol *> *_protocols;
}

+ (instancetype)shared {
    static BetterSimTaskRouter *router;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ router = [[BetterSimTaskRouter alloc] init]; });
    return router;
}

- (instancetype)init {
    if ((self = [super init])) {
        _protocols = [NSMutableDictionary dictionary];
        NSOperationQueue *queue = [[NSOperationQueue alloc] init];
        queue.maxConcurrentOperationCount = 1;
        queue.name = @"local.bettersim.network-monitor";
        // Made with the original factory so the session's requests don't come back through the monitor.
        NSURLSessionConfiguration *configuration = BetterSimOriginalDefaultConfiguration(NSURLSessionConfiguration.class, @selector(defaultSessionConfiguration));
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:queue];
    }
    return self;
}

- (NSURLSessionDataTask *)startTaskWithRequest:(NSURLRequest *)request for:(BetterSimURLProtocol *)protocol {
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:request];
    @synchronized (self) {
        _protocols[@(task.taskIdentifier)] = protocol;
    }
    [task resume];
    return task;
}

- (BetterSimURLProtocol *)protocolForTask:(NSURLSessionTask *)task finished:(BOOL)finished {
    @synchronized (self) {
        NSNumber *key = @(task.taskIdentifier);
        BetterSimURLProtocol *protocol = _protocols[key];
        if (finished) [_protocols removeObjectForKey:key];
        return protocol;
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    BetterSimURLProtocol *protocol = [self protocolForTask:dataTask finished:NO];
    [protocol performOnClientThread:^{ [protocol forwardResponse:response]; }];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    BetterSimURLProtocol *protocol = [self protocolForTask:dataTask finished:NO];
    [protocol performOnClientThread:^{ [protocol forwardData:data]; }];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    BetterSimURLProtocol *protocol = [self protocolForTask:task finished:NO];
    [protocol performOnClientThread:^{ [protocol forwardRedirectTo:request response:response]; }];
    completionHandler(nil);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    BetterSimURLProtocol *protocol = [self protocolForTask:task finished:YES];
    [protocol performOnClientThread:^{ [protocol finishWithError:error]; }];
}

@end

/// Puts the monitor first in the configuration's protocol classes, so sessions the app makes itself are covered too.
static BetterSimConfigurationFactory BetterSimInstallMonitor(SEL selector) {
    Method method = class_getClassMethod(NSURLSessionConfiguration.class, selector);
    BetterSimConfigurationFactory original = (BetterSimConfigurationFactory)method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(^NSURLSessionConfiguration *(id configurationClass) {
        NSURLSessionConfiguration *configuration = original(configurationClass, selector);
        NSMutableArray<Class> *classes = [configuration.protocolClasses mutableCopy] ?: [NSMutableArray array];
        [classes removeObject:BetterSimURLProtocol.class];
        [classes insertObject:BetterSimURLProtocol.class atIndex:0];
        configuration.protocolClasses = classes;
        return configuration;
    }));
    return original;
}

__attribute__((constructor))
static void BetterSimNetworkMonitorLoad(void) {
    const char *port = getenv("BETTERSIM_MONITOR_PORT");
    long number = port ? strtol(port, NULL, 10) : 0;
    if (number <= 0 || number > 65535) return;
    @autoreleasepool {
        BetterSimEventsURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/events", number]];
        BetterSimOriginalDefaultConfiguration = BetterSimInstallMonitor(@selector(defaultSessionConfiguration));
        BetterSimOriginalEphemeralConfiguration = BetterSimInstallMonitor(@selector(ephemeralSessionConfiguration));
        [NSURLProtocol registerClass:BetterSimURLProtocol.class];
    }
}
