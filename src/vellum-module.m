// vellum-module.m --- A WKWebView laid over an Emacs window
//
// The module is deliberately small.  It owns web views, places them over
// rectangles of an Emacs frame, runs JavaScript in them, and passes their
// messages back to Emacs through a pipe.  Everything about PDFs lives in
// web/ (the viewer) and vellum.el (the mode).
//
// The views never take keyboard focus: keys always belong to Emacs.

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <emacs-module.h>
#include <unistd.h>

int plugin_is_GPL_compatible;

static NSString *const kScheme = @"vellum";

#pragma mark - Serving the viewer and the PDFs

// vellum://app/<path>   a file of the viewer, under the assets directory
// vellum://file/<path>  a PDF anywhere on disk
@interface VellumSchemeHandler : NSObject <WKURLSchemeHandler>
@property (copy) NSString *assets;
@end

@implementation VellumSchemeHandler

static NSString *VellumMimeType(NSString *path) {
  static NSDictionary *types;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    types = @{
      @"html": @"text/html", @"css": @"text/css",
      @"js": @"text/javascript", @"mjs": @"text/javascript",
      @"json": @"application/json", @"svg": @"image/svg+xml",
      @"png": @"image/png", @"gif": @"image/gif",
      @"wasm": @"application/wasm", @"pdf": @"application/pdf",
      @"ftl": @"text/plain",
    };
  });
  return types[path.pathExtension.lowercaseString] ?: @"application/octet-stream";
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
  NSURL *url = task.request.URL;
  NSString *path = nil;
  if ([url.host isEqualToString:@"app"]) {
    path = [[self.assets stringByAppendingPathComponent:url.path] stringByStandardizingPath];
    if (![path hasPrefix:self.assets]) path = nil;
  } else if ([url.host isEqualToString:@"file"]) {
    if ([url.path.pathExtension.lowercaseString isEqualToString:@"pdf"]) path = url.path;
  }
  NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
  if (!data) {
    [task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                               code:NSURLErrorFileDoesNotExist
                                           userInfo:nil]];
    return;
  }
  NSDictionary *headers = @{
    @"Content-Type": VellumMimeType(path),
    @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)data.length],
    @"Access-Control-Allow-Origin": @"*",
    @"Cache-Control": @"no-store",
  };
  NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url
                                                            statusCode:200
                                                           HTTPVersion:@"HTTP/1.1"
                                                          headerFields:headers];
  [task didReceiveResponse:response];
  [task didReceiveData:data];
  [task didFinish];
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
}

@end

#pragma mark - The view

@interface VellumWebView : WKWebView
@end

@implementation VellumWebView
// Keys stay with Emacs; the mouse and the trackpad are all this view hears.
- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)becomeFirstResponder { return NO; }
- (void)willOpenMenu:(NSMenu *)menu withEvent:(NSEvent *)event { [menu removeAllItems]; }
@end

@interface VellumView : NSObject <WKScriptMessageHandler, WKNavigationDelegate>
@property (copy) NSString *ident;
@property (strong) VellumWebView *webView;
@property (strong) VellumSchemeHandler *handler;
@property int fd;
@end

@implementation VellumView

- (void)send:(NSDictionary *)message {
  if (self.fd < 0) return;
  NSMutableDictionary *m = [message mutableCopy];
  m[@"id"] = self.ident;
  NSData *json = [NSJSONSerialization dataWithJSONObject:m options:0 error:nil];
  if (!json) return;
  NSMutableData *line = [json mutableCopy];
  [line appendBytes:"\n" length:1];
  const char *bytes = line.bytes;
  size_t left = line.length;
  while (left > 0) {
    ssize_t n = write(self.fd, bytes, left);
    if (n <= 0) break;
    bytes += n;
    left -= (size_t)n;
  }
}

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
  if ([message.body isKindOfClass:[NSDictionary class]]) [self send:message.body];
}

// The viewer is the only page this view shows; any other link is Emacs's to open.
- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)action
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decide {
  NSURL *url = action.request.URL;
  if ([url.scheme isEqualToString:kScheme] || [url.scheme isEqualToString:@"about"]) {
    decide(WKNavigationActionPolicyAllow);
  } else {
    [self send:@{@"type": @"link", @"url": url.absoluteString ?: @""}];
    decide(WKNavigationActionPolicyCancel);
  }
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
  [self send:@{@"type": @"crashed"}];
}

@end

static NSMutableDictionary<NSString *, VellumView *> *views;

#pragma mark - Finding Emacs's own view

static NSView *VellumFindEmacsView(NSView *view) {
  if ([NSStringFromClass([view class]) isEqualToString:@"EmacsView"]) return view;
  for (NSView *sub in view.subviews) {
    NSView *found = VellumFindEmacsView(sub);
    if (found) return found;
  }
  return nil;
}

// The Emacs frame whose outer edges are nearest LEFT, TOP, WIDTH, HEIGHT
// (in Emacs's screen coordinates: origin at the primary display's top left).
static NSView *VellumEmacsViewAt(double left, double top, double width, double height) {
  CGFloat primary = NSScreen.screens.firstObject.frame.size.height;
  NSView *best = nil;
  double bestDistance = INFINITY;
  for (NSWindow *window in NSApp.windows) {
    if (!window.isVisible || window.parentWindow) continue;
    NSView *view = VellumFindEmacsView(window.contentView);
    if (!view) continue;
    NSRect f = window.frame;
    double distance = fabs(f.origin.x - left) + fabs((primary - NSMaxY(f)) - top)
      + fabs(f.size.width - width) + fabs(f.size.height - height);
    if (distance < bestDistance) {
      bestDistance = distance;
      best = view;
    }
  }
  return best;
}

#pragma mark - Lisp helpers

static NSString *VellumString(emacs_env *env, emacs_value value) {
  ptrdiff_t size = 0;
  if (!env->copy_string_contents(env, value, NULL, &size)) {
    env->non_local_exit_clear(env);
    return @"";
  }
  char *buffer = malloc((size_t)size);
  env->copy_string_contents(env, value, buffer, &size);
  NSString *string = [NSString stringWithUTF8String:buffer] ?: @"";
  free(buffer);
  return string;
}

static double VellumNumber(emacs_env *env, emacs_value value) {
  emacs_value type = env->type_of(env, value);
  if (env->eq(env, type, env->intern(env, "float"))) return env->extract_float(env, value);
  return (double)env->extract_integer(env, value);
}

static emacs_value Qnil(emacs_env *env) { return env->intern(env, "nil"); }
static emacs_value Qt(emacs_env *env) { return env->intern(env, "t"); }

#pragma mark - Lisp functions

// (vellum-module-create ID ASSETS URL CHANNEL)
static emacs_value Fcreate(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data) {
  @autoreleasepool {
    NSString *ident = VellumString(env, args[0]);
    NSString *assets = [VellumString(env, args[1]) stringByStandardizingPath];
    NSString *url = VellumString(env, args[2]);
    int fd = env->open_channel(env, args[3]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return) return Qnil(env);

    VellumView *view = [VellumView new];
    view.ident = ident;
    view.fd = fd;
    view.handler = [VellumSchemeHandler new];
    view.handler.assets = assets;

    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    [config setURLSchemeHandler:view.handler forURLScheme:kScheme];
    [config.userContentController addScriptMessageHandler:view name:@"vellum"];
    config.suppressesIncrementalRendering = YES;

    view.webView = [[VellumWebView alloc] initWithFrame:NSMakeRect(0, 0, 600, 800)
                                         configuration:config];
    view.webView.navigationDelegate = view;
    view.webView.allowsMagnification = NO;   // the viewer zooms the PDF itself
    view.webView.hidden = YES;
    // Nothing of the web view shows until the page has painted: Emacs's own
    // background stands in for it.
    [view.webView setValue:@NO forKey:@"drawsBackground"];
    if (@available(macOS 13.3, *)) view.webView.inspectable = YES;

    VellumView *old = views[ident];
    if (old) {
      [old.webView removeFromSuperview];
      if (old.fd >= 0) close(old.fd);
    }
    views[ident] = view;
    [view.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
    return Qt(env);
  }
}

// (vellum-module-place ID FRAME-LEFT FRAME-TOP FRAME-WIDTH FRAME-HEIGHT X Y WIDTH HEIGHT)
static emacs_value Fplace(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data) {
  @autoreleasepool {
    VellumView *view = views[VellumString(env, args[0])];
    if (!view) return Qnil(env);
    double n[8];
    for (int i = 0; i < 8; i++) n[i] = VellumNumber(env, args[i + 1]);
    NSView *emacs = VellumEmacsViewAt(n[0], n[1], n[2], n[3]);
    if (!emacs) return Qnil(env);
    NSRect rect = NSMakeRect(n[4], n[5], n[6], n[7]);
    if (!emacs.isFlipped) rect.origin.y = emacs.bounds.size.height - n[5] - n[7];
    if (view.webView.superview != emacs) {
      [view.webView removeFromSuperview];
      [emacs addSubview:view.webView];
    }
    if (!NSEqualRects(view.webView.frame, rect)) view.webView.frame = rect;
    view.webView.hidden = NO;
    return Qt(env);
  }
}

// (vellum-module-hide ID)
static emacs_value Fhide(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data) {
  @autoreleasepool {
    VellumView *view = views[VellumString(env, args[0])];
    if (!view) return Qnil(env);
    view.webView.hidden = YES;
    return Qt(env);
  }
}

// (vellum-module-destroy ID)
static emacs_value Fdestroy(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data) {
  @autoreleasepool {
    NSString *ident = VellumString(env, args[0]);
    VellumView *view = views[ident];
    if (!view) return Qnil(env);
    [view.webView.configuration.userContentController
        removeScriptMessageHandlerForName:@"vellum"];
    [view.webView removeFromSuperview];
    if (view.fd >= 0) close(view.fd);
    view.fd = -1;
    [views removeObjectForKey:ident];
    return Qt(env);
  }
}

// (vellum-module-eval ID JAVASCRIPT)
static emacs_value Feval(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data) {
  @autoreleasepool {
    VellumView *view = views[VellumString(env, args[0])];
    if (!view) return Qnil(env);
    NSString *script = VellumString(env, args[1]);
    __weak VellumView *weak = view;
    [view.webView evaluateJavaScript:script
                   completionHandler:^(id result, NSError *error) {
      if (error) {
        [weak send:@{@"type": @"error",
                     @"message": error.localizedDescription ?: @"JavaScript error",
                     @"detail": [error.userInfo[@"WKJavaScriptExceptionMessage"] description] ?: @""}];
      }
    }];
    return Qt(env);
  }
}

// (vellum-module-snapshot ID FILE)  -- a PNG of the view, for tests
static emacs_value Fsnapshot(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data) {
  @autoreleasepool {
    VellumView *view = views[VellumString(env, args[0])];
    if (!view) return Qnil(env);
    NSString *file = VellumString(env, args[1]);
    __weak VellumView *weak = view;
    [view.webView takeSnapshotWithConfiguration:nil
                              completionHandler:^(NSImage *image, NSError *error) {
      BOOL ok = NO;
      if (image) {
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:image.TIFFRepresentation];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        ok = [png writeToFile:file atomically:YES];
      }
      [weak send:@{@"type": @"snapshot", @"file": file, @"ok": @(ok)}];
    }];
    return Qt(env);
  }
}

#pragma mark - Init

static void VellumDefun(emacs_env *env, const char *name, ptrdiff_t arity,
                        emacs_value (*fn)(emacs_env *, ptrdiff_t, emacs_value *, void *),
                        const char *doc) {
  emacs_value args[] = {env->intern(env, name),
                        env->make_function(env, arity, arity, fn, doc, NULL)};
  env->funcall(env, env->intern(env, "defalias"), 2, args);
}

int emacs_module_init(struct emacs_runtime *runtime) {
  if (runtime->size < (ptrdiff_t)sizeof(*runtime)) return 1;
  emacs_env *env = runtime->get_environment(runtime);
  if (env->size < (ptrdiff_t)sizeof(struct emacs_env_28)) return 2;

  views = [NSMutableDictionary new];

  VellumDefun(env, "vellum-module-create", 4, Fcreate,
              "Create the web view ID showing URL.\n"
              "ASSETS is the viewer's directory; messages go to the pipe process CHANNEL.\n\n"
              "(fn ID ASSETS URL CHANNEL)");
  VellumDefun(env, "vellum-module-place", 9, Fplace,
              "Show the web view ID over a rectangle of an Emacs frame.\n"
              "The frame is the one whose outer edges are FRAME-LEFT, FRAME-TOP,\n"
              "FRAME-WIDTH and FRAME-HEIGHT; X, Y, WIDTH and HEIGHT are in the\n"
              "frame's native pixels.\n\n"
              "(fn ID FRAME-LEFT FRAME-TOP FRAME-WIDTH FRAME-HEIGHT X Y WIDTH HEIGHT)");
  VellumDefun(env, "vellum-module-hide", 1, Fhide, "Hide the web view ID.\n\n(fn ID)");
  VellumDefun(env, "vellum-module-destroy", 1, Fdestroy,
              "Destroy the web view ID.\n\n(fn ID)");
  VellumDefun(env, "vellum-module-eval", 2, Feval,
              "Run JAVASCRIPT in the web view ID.\n\n(fn ID JAVASCRIPT)");
  VellumDefun(env, "vellum-module-snapshot", 2, Fsnapshot,
              "Write a PNG of the web view ID to FILE.\n\n(fn ID FILE)");

  emacs_value feature[] = {env->intern(env, "vellum-module")};
  env->funcall(env, env->intern(env, "provide"), 1, feature);
  return 0;
}
