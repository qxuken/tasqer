#import <Cocoa/Cocoa.h>

static NSString *const kCliPath = @"<APP_BIN_PATH>";
static NSString *const kCliCmd = @"<APP_COMMAND>";
static NSString *const kLogPath = @"<APP_LOG_PATH>";

static void spawnApplicationTask(NSString *path) {
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm isExecutableFileAtPath:kCliPath])
    return;

  // Open log for append (create if missing)
  if (![fm fileExistsAtPath:kLogPath]) {
    [@"" writeToFile:kLogPath
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:nil];
  }
  NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
  [log truncateFileAtOffset:0];

  NSTask *task = [[NSTask alloc] init];
  task.currentDirectoryPath = NSHomeDirectory();

  NSMutableDictionary<NSString *, NSString *> *env = [NSMutableDictionary
      dictionaryWithDictionary:NSProcessInfo.processInfo.environment];

  // Add the common locations where wezterm (and other tools) live
  env[@"PATH"] =
      @"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
  task.environment = env;

  task.executableURL = [NSURL fileURLWithPath:@"/bin/zsh"];
  task.arguments = @[
    @"-lc", [NSString stringWithFormat:@"%@ %@ %@", kCliPath, kCliCmd, path]
  ];

  task.standardOutput = log;
  task.standardError = log;
  if (@available(macOS 10.13, *)) {
    NSError *err = nil;
    [task launchAndReturnError:&err];
    if (err) {
      NSString *line = [NSString stringWithFormat:@"spawn error: %@\n", err];
      [log writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    }
  } else {
    [task launch];
  }

  // Not waiting; child continues even if we quit.
  [log closeFile];
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate
- (void)application:(NSApplication *)app
          openFiles:(NSArray<NSString *> *)files {
  for (NSString *f in files) {
    spawnApplicationTask(f);
  }
  [app replyToOpenOrPrint:NSApplicationDelegateReplySuccess];

  // Quit after dispatching opens
  [NSApp terminate:nil];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
  // Launched with no files (e.g. click app icon)
  [NSApp terminate:nil];
}
@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    AppDelegate *delegate = [AppDelegate new];
    app.delegate = delegate;
    [app run];
  }
  return 0;
}
