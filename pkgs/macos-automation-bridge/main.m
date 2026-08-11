#import <Cocoa/Cocoa.h>
#import <CoreWLAN/CoreWLAN.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static NSString *const SketchyBarPath = @"@sketchybar@";
static const NSTimeInterval LeadDwell = 0.70;
static const NSTimeInterval ReturnHold = 0.14;
static const NSTimeInterval SettleHold = 0.20;
static const CGFloat LiftGuard = 4.0;
static const CGFloat MenuBarBand = 44.0;
static const NSTimeInterval PrimeDelay = 4.0;

@interface AutomationBridge : NSObject <NSApplicationDelegate, CWEventDelegate>
@property(nonatomic) NSRect primaryFrame;
@property(nonatomic) BOOL approach;
@property(nonatomic) BOOL hover;
@property(nonatomic) BOOL menu;
@property(nonatomic) BOOL emitted;
@property(nonatomic) BOOL lifted;
@property(nonatomic) uint64_t sequence;
@property(nonatomic, strong) NSTimer *pointerTimer;
@property(nonatomic, strong) NSTimer *leadTimer;
@property(nonatomic, strong) NSTimer *returnTimer;
@property(nonatomic, strong) NSTimer *settleTimer;
@property(nonatomic, strong) CWWiFiClient *wifiClient;
@property(nonatomic) CFRunLoopSourceRef powerSource;
@end

static void PowerChanged(void *context) {
  AutomationBridge *bridge = (__bridge AutomationBridge *)context;
  [bridge performSelectorOnMainThread:@selector(emitBattery)
                           withObject:nil
                        waitUntilDone:NO];
}

@implementation AutomationBridge

- (void)runEvent:(NSString *)event arguments:(NSArray<NSString *> *)arguments {
  NSTask *task = [[NSTask alloc] init];
  task.executableURL = [NSURL fileURLWithPath:SketchyBarPath];
  NSMutableArray<NSString *> *argv = [NSMutableArray arrayWithObjects:@"--trigger", event, nil];
  [argv addObjectsFromArray:arguments];
  task.arguments = argv;
  task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
  task.standardError = [NSFileHandle fileHandleWithNullDevice];
  NSError *error = nil;
  if (![task launchAndReturnError:&error]) {
    NSLog(@"unable to launch SketchyBar event %@: %@", event, error.localizedDescription);
  }
}

- (void)sendStateEvent:(NSString *)event state:(BOOL)state {
  self.sequence += 1;
  [self runEvent:event
       arguments:@[
         [NSString stringWithFormat:@"STATE=%d", state ? 1 : 0],
         [NSString stringWithFormat:@"SEQ=%llu", self.sequence]
       ]];
}

- (void)emitDown:(BOOL)down force:(BOOL)force {
  if (!force && down == self.emitted) return;
  [self sendStateEvent:@"menubar_duck" state:down];
  self.emitted = down;
}

- (void)lift:(BOOL)up force:(BOOL)force {
  if (!force && up == self.lifted) return;
  [self sendStateEvent:@"menubar_lift" state:up];
  self.lifted = up;
}

- (BOOL)onPrimary:(NSPoint)point {
  return !NSIsEmptyRect(self.primaryFrame) && NSPointInRect(point, self.primaryFrame);
}

- (CGFloat)distanceFromTop:(NSPoint)point {
  return NSMaxY(self.primaryFrame) - point.y;
}

- (BOOL)inLiftGuard:(NSPoint)point {
  return [self onPrimary:point] && [self distanceFromTop:point] <= LiftGuard;
}

- (BOOL)inMenuBarBand:(NSPoint)point {
  return [self onPrimary:point] && [self distanceFromTop:point] <= MenuBarBand;
}

- (BOOL)onPrimaryEdge:(NSPoint)point {
  return [self onPrimary:point] && [self distanceFromTop:point] <= 1.0;
}

- (void)refreshPrimary {
  NSArray<NSScreen *> *screens = NSScreen.screens;
  self.primaryFrame = screens.count > 0 ? screens.firstObject.frame : NSZeroRect;
}

- (void)stopTimer:(NSTimer * __strong *)timer {
  [*timer invalidate];
  *timer = nil;
}

- (void)stopLead { [self stopTimer:&_leadTimer]; }
- (void)stopReturn { [self stopTimer:&_returnTimer]; }
- (void)stopSettle { [self stopTimer:&_settleTimer]; }

- (BOOL)liftTarget { return self.approach || self.menu; }

- (void)beginSettle {
  if (!self.lifted || self.emitted || [self liftTarget] || self.settleTimer) return;
  __weak AutomationBridge *weakSelf = self;
  self.settleTimer = [NSTimer scheduledTimerWithTimeInterval:SettleHold repeats:NO block:^(NSTimer *timer) {
    (void)timer;
    AutomationBridge *strongSelf = weakSelf;
    strongSelf.settleTimer = nil;
    if (strongSelf && ![strongSelf liftTarget]) [strongSelf lift:NO force:NO];
  }];
}

- (void)beginReturn {
  if (!self.emitted || self.menu || self.returnTimer) return;
  __weak AutomationBridge *weakSelf = self;
  self.returnTimer = [NSTimer scheduledTimerWithTimeInterval:ReturnHold repeats:NO block:^(NSTimer *timer) {
    (void)timer;
    AutomationBridge *strongSelf = weakSelf;
    strongSelf.returnTimer = nil;
    if (!strongSelf) return;
    strongSelf.hover = NO;
    if (!strongSelf.menu) [strongSelf emitDown:NO force:NO];
    [strongSelf beginSettle];
  }];
}

- (void)beginLead {
  if (self.menu || self.emitted || self.leadTimer) return;
  __weak AutomationBridge *weakSelf = self;
  self.leadTimer = [NSTimer scheduledTimerWithTimeInterval:LeadDwell repeats:NO block:^(NSTimer *timer) {
    (void)timer;
    AutomationBridge *strongSelf = weakSelf;
    strongSelf.leadTimer = nil;
    if (!strongSelf) return;
    strongSelf.hover = YES;
    [strongSelf emitDown:YES force:NO];
  }];
}

- (void)pollPointer:(NSTimer *)timer {
  (void)timer;
  NSPoint point = NSEvent.mouseLocation;
  BOOL guarded = [self inLiftGuard:point];
  BOOL band = [self inMenuBarBand:point];

  if (guarded != self.approach) {
    self.approach = guarded;
    if (guarded) {
      [self stopSettle];
      [self lift:YES force:NO];
    } else {
      [self beginSettle];
    }
  }

  if ([self onPrimaryEdge:point]) {
    [self stopReturn];
    [self beginLead];
  } else if (band) {
    [self stopLead];
    [self stopReturn];
  } else {
    [self stopLead];
    [self beginReturn];
    [self beginSettle];
  }
}

- (void)reconcile {
  [self stopLead];
  [self stopReturn];
  [self stopSettle];
  [self refreshPrimary];
  NSPoint point = NSEvent.mouseLocation;
  self.approach = [self inLiftGuard:point];
  self.hover = [self inMenuBarBand:point];
  [self emitDown:(self.menu || self.hover) force:YES];
  [self lift:[self liftTarget] force:NO];
}

- (void)screenChanged:(NSNotification *)notification {
  (void)notification;
  [self reconcile];
}

- (void)systemWoke:(NSNotification *)notification {
  (void)notification;
  [self reconcile];
  [self emitNetwork];
  [self emitBattery];
}

- (void)menuBegan:(NSNotification *)notification {
  (void)notification;
  self.menu = YES;
  [self stopLead];
  [self stopReturn];
  [self stopSettle];
  [self lift:YES force:NO];
  [self emitDown:YES force:NO];
}

- (void)menuEnded:(NSNotification *)notification {
  (void)notification;
  self.menu = NO;
  NSPoint point = NSEvent.mouseLocation;
  self.approach = [self inLiftGuard:point];
  self.hover = [self inMenuBarBand:point];
  if (self.hover) {
    [self stopReturn];
    if (self.approach) [self stopSettle];
  } else {
    [self beginReturn];
    [self beginSettle];
  }
}

- (void)emitNetwork {
  // Association changes are the signal; SSID text is deliberately not read,
  // so this helper needs no Location grant and exports no network identifier.
  [self runEvent:@"network_change" arguments:@[]];
}

- (void)linkDidChangeForWiFiInterfaceWithName:(NSString *)interfaceName {
  (void)interfaceName;
  [self performSelectorOnMainThread:@selector(emitNetwork)
                         withObject:nil
                      waitUntilDone:NO];
}

- (void)emitBattery {
  CFTypeRef info = IOPSCopyPowerSourcesInfo();
  if (!info) {
    [self runEvent:@"battery_change" arguments:@[]];
    return;
  }
  CFArrayRef sources = IOPSCopyPowerSourcesList(info);
  NSMutableArray<NSString *> *arguments = [NSMutableArray array];
  if (sources) {
    for (id source in (__bridge NSArray *)sources) {
      CFDictionaryRef raw = IOPSGetPowerSourceDescription(info, (__bridge CFTypeRef)source);
      NSDictionary *description = (__bridge NSDictionary *)raw;
      if (![description[@kIOPSTypeKey] isEqualToString:@kIOPSInternalBatteryType]) continue;
      NSNumber *current = description[@kIOPSCurrentCapacityKey];
      NSNumber *maximum = description[@kIOPSMaxCapacityKey];
      NSNumber *charging = description[@kIOPSIsChargingKey];
      if (current && maximum.doubleValue > 0.0) {
        NSInteger percent = (NSInteger)llround(100.0 * current.doubleValue / maximum.doubleValue);
        [arguments addObject:[NSString stringWithFormat:@"PERCENT=%ld", (long)percent]];
      }
      if (charging) {
        [arguments addObject:[NSString stringWithFormat:@"CHARGING=%d", charging.boolValue ? 1 : 0]];
      }
      break;
    }
    CFRelease(sources);
  }
  CFRelease(info);
  [self runEvent:@"battery_change" arguments:arguments];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;
  self.sequence = (uint64_t)(NSProcessInfo.processInfo.systemUptime * 1000.0);
  [self refreshPrimary];

  NSNotificationCenter *workspaceCenter = NSWorkspace.sharedWorkspace.notificationCenter;
  [workspaceCenter addObserver:self selector:@selector(systemWoke:)
                          name:NSWorkspaceDidWakeNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(screenChanged:)
                                              name:NSApplicationDidChangeScreenParametersNotification object:nil];
  NSDistributedNotificationCenter *distributed = NSDistributedNotificationCenter.defaultCenter;
  [distributed addObserver:self selector:@selector(menuBegan:)
                       name:@"com.apple.HIToolbox.beginMenuTrackingNotification" object:nil];
  [distributed addObserver:self selector:@selector(menuEnded:)
                       name:@"com.apple.HIToolbox.endMenuTrackingNotification" object:nil];

  self.wifiClient = CWWiFiClient.sharedWiFiClient;
  self.wifiClient.delegate = self;
  NSError *wifiError = nil;
  if (![self.wifiClient startMonitoringEventWithType:CWEventTypeLinkDidChange error:&wifiError]) {
    NSLog(@"unable to monitor Wi-Fi link changes: %@", wifiError.localizedDescription);
  }

  CFRunLoopSourceContext powerContext = {0, (__bridge void *)self, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL};
  self.powerSource = IOPSNotificationCreateRunLoopSource(PowerChanged, &powerContext);
  if (self.powerSource) {
    CFRunLoopAddSource(CFRunLoopGetMain(), self.powerSource, kCFRunLoopCommonModes);
  }

  // Polling the public global mouse position avoids an Accessibility or Input
  // Monitoring grant entirely. The helper receives no key events and cannot
  // synthesize input; 30 Hz is well inside the four-pixel lead guard.
  self.pointerTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 30.0)
                                                       target:self
                                                     selector:@selector(pollPointer:)
                                                     userInfo:nil
                                                      repeats:YES];
  [self reconcile];
  [self emitNetwork];
  [self emitBattery];

  __weak AutomationBridge *weakSelf = self;
  [NSTimer scheduledTimerWithTimeInterval:PrimeDelay repeats:NO block:^(NSTimer *timer) {
    (void)timer;
    AutomationBridge *strongSelf = weakSelf;
    if (!strongSelf) return;
    NSPoint point = NSEvent.mouseLocation;
    strongSelf.approach = [strongSelf inLiftGuard:point];
    strongSelf.hover = [strongSelf inMenuBarBand:point];
    [strongSelf emitDown:(strongSelf.menu || strongSelf.hover || strongSelf.emitted) force:YES];
    [strongSelf lift:[strongSelf liftTarget] force:YES];
    [strongSelf emitNetwork];
    [strongSelf emitBattery];
  }];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  (void)notification;
  [self.pointerTimer invalidate];
  [self stopLead];
  [self stopReturn];
  [self stopSettle];
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
  [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
  [self.wifiClient stopMonitoringAllEventsAndReturnError:nil];
  if (self.powerSource) {
    CFRunLoopRemoveSource(CFRunLoopGetMain(), self.powerSource, kCFRunLoopCommonModes);
    CFRelease(self.powerSource);
    self.powerSource = NULL;
  }
}

@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
      puts("atyrode-automation-bridge 1.0.0");
      return 0;
    }
    NSApplication *application = NSApplication.sharedApplication;
    AutomationBridge *delegate = [[AutomationBridge alloc] init];
    application.delegate = delegate;
    [application run];
  }
  return 0;
}
