#import "BrowserGamepadBridge.h"

#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>

#import "BrowserWebView.h"

static NSUInteger const kBrowserGamepadMaxSlots = 4;
static CFTimeInterval const kBrowserGamepadHeartbeatInterval = 0.5;
static CFTimeInterval const kBrowserGamepadPageUsageTimeout = 2.0;
static CFTimeInterval const kBrowserGamepadPressMatchInterval = 0.25;
static float const kBrowserGamepadStickActivityThreshold = 0.3f;

static __weak BrowserGamepadBridge *sActiveBridge;

static NSArray *BrowserGamepadButtonEntry(GCControllerButtonInput *button) {
    if (button == nil) {
        return @[@NO, @0];
    }
    return @[@(button.isPressed), @(button.value)];
}

@interface BrowserGamepadBridge ()

@property (nonatomic) NSMutableArray *slots;
@property (nonatomic, nullable) CADisplayLink *displayLink;
@property (nonatomic, copy, nullable) NSString *lastSentPayload;
@property (nonatomic) CFTimeInterval lastSendTimestamp;
@property (nonatomic) CFTimeInterval lastActivityTimestamp;
@property (nonatomic) CFTimeInterval lastPageUsageTimestamp;
@property (nonatomic, nullable) NSArray *lastSnapshot;
@property (nonatomic, weak, nullable) BrowserWebView *lastWebView;
@property (nonatomic) NSHashTable<UIPress *> *suppressedPresses;
@property (nonatomic) BOOL started;

@end

@implementation BrowserGamepadBridge

+ (BrowserGamepadBridge *)activeBridge {
    return sActiveBridge;
}

+ (NSString *)userScriptSource {
    return @"(function() {"
        "if (window.__tvosGamepadShimInstalled) { return; }"
        "window.__tvosGamepadShimInstalled = true;"
        "var MAX = 4;"
        "var pads = [null, null, null, null];"
        "var signatures = [];"
        "var lastLocalPoll = 0;"
        "var lastUsageReport = 0;"
        "var isTop = (window.top === window);"
        "function now() { return (window.performance && performance.now) ? performance.now() : Date.now(); }"
        "function makeButton(entry) {"
            "var value = +entry[1] || 0;"
            "var pressed = !!entry[0];"
            "return { pressed: pressed, touched: pressed || value > 0, value: value };"
        "}"
        "function makePad(state) {"
            "return { id: String(state.id), index: state.index, connected: true, mapping: 'standard',"
                "timestamp: now(), axes: state.axes.slice(0), buttons: state.buttons.map(makeButton),"
                "vibrationActuator: null, hapticActuators: [] };"
        "}"
        "function dispatch(type, pad) {"
            "var event = null;"
            "try { event = new GamepadEvent(type, { gamepad: pad }); } catch (e) { event = null; }"
            "if (!event) {"
                "event = document.createEvent('Event');"
                "event.initEvent(type, false, false);"
                "try { Object.defineProperty(event, 'gamepad', { value: pad }); } catch (e) { event.gamepad = pad; }"
            "}"
            "window.dispatchEvent(event);"
            "var handlerName = 'on' + type;"
            "if (!(handlerName in Window.prototype) && typeof window[handlerName] === 'function') {"
                "try { window[handlerName](event); } catch (e) {}"
            "}"
        "}"
        "function forward(states) {"
            "for (var i = 0; i < window.frames.length; i++) {"
                "try { window.frames[i].postMessage({ __tvosGamepadStates: states }, '*'); } catch (e) {}"
            "}"
        "}"
        "function apply(states) {"
            "if (!Array.isArray(states)) { return; }"
            "var seen = {};"
            "for (var i = 0; i < states.length; i++) {"
                "var state = states[i];"
                "if (!state || state.index < 0 || state.index >= MAX) { continue; }"
                "seen[state.index] = true;"
                "var existing = pads[state.index];"
                "if (existing && existing.id !== String(state.id)) {"
                    "existing.connected = false;"
                    "pads[state.index] = null;"
                    "dispatch('gamepaddisconnected', existing);"
                    "existing = null;"
                "}"
                "var signature = JSON.stringify([state.buttons, state.axes]);"
                "if (!existing || signatures[state.index] !== signature) {"
                    "pads[state.index] = makePad(state);"
                    "signatures[state.index] = signature;"
                "}"
                "if (!existing) { dispatch('gamepadconnected', pads[state.index]); }"
            "}"
            "for (var j = 0; j < MAX; j++) {"
                "if (pads[j] && !seen[j]) {"
                    "var gone = pads[j];"
                    "gone.connected = false;"
                    "pads[j] = null;"
                    "signatures[j] = null;"
                    "dispatch('gamepaddisconnected', gone);"
                "}"
            "}"
            "forward(states);"
        "}"
        "function markUsed() {"
            "lastLocalPoll = Date.now();"
            "if (!isTop && lastLocalPoll - lastUsageReport > 500) {"
                "lastUsageReport = lastLocalPoll;"
                "try { window.parent.postMessage({ __tvosGamepadUsed: true }, '*'); } catch (e) {}"
            "}"
        "}"
        "window.addEventListener('message', function(event) {"
            "var data = event.data;"
            "if (!data || typeof data !== 'object') { return; }"
            "if (data.__tvosGamepadStates && !isTop && event.source === window.parent) {"
                "apply(data.__tvosGamepadStates);"
            "} else if (data.__tvosGamepadUsed) {"
                "markUsed();"
            "}"
        "}, false);"
        "function getGamepads() { markUsed(); return pads.slice(0); }"
        "try { Object.defineProperty(Navigator.prototype, 'getGamepads', { value: getGamepads, configurable: true, writable: true }); } catch (e) {}"
        "try { Object.defineProperty(navigator, 'getGamepads', { value: getGamepads, configurable: true, writable: true }); } catch (e) {}"
        "try { navigator.webkitGetGamepads = getGamepads; } catch (e) {}"
        "if (isTop) {"
            "Object.defineProperty(window, '__tvosGamepadUpdate', {"
                "value: function(states) { apply(states); return (Date.now() - lastLocalPoll) < 1500; },"
                "configurable: false, writable: false"
            "});"
        "}"
    "})();";
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _slots = [NSMutableArray arrayWithCapacity:kBrowserGamepadMaxSlots];
        for (NSUInteger index = 0; index < kBrowserGamepadMaxSlots; index++) {
            [_slots addObject:[NSNull null]];
        }
        _suppressedPresses = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_displayLink invalidate];
}

- (void)start {
    if (self.started) {
        return;
    }
    self.started = YES;
    sActiveBridge = self;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleControllerDidConnect:)
                                                 name:GCControllerDidConnectNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleControllerDidDisconnect:)
                                                 name:GCControllerDidDisconnectNotification
                                               object:nil];

    for (GCController *controller in [GCController controllers]) {
        [self assignSlotForController:controller];
    }
    [self updateDisplayLink];
}

- (void)stop {
    if (!self.started) {
        return;
    }
    self.started = NO;
    if (sActiveBridge == self) {
        sActiveBridge = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.displayLink invalidate];
    self.displayLink = nil;
}

- (void)setNeedsStateResend {
    self.lastSentPayload = nil;
}

#pragma mark - Controllers

- (void)handleControllerDidConnect:(NSNotification *)notification {
    [self assignSlotForController:notification.object];
    [self setNeedsStateResend];
    [self updateDisplayLink];
}

- (void)handleControllerDidDisconnect:(NSNotification *)notification {
    NSUInteger index = [self.slots indexOfObject:notification.object];
    if (index != NSNotFound) {
        self.slots[index] = [NSNull null];
    }
    [self setNeedsStateResend];
    // Push the disconnect to the page before the display link possibly stops.
    [self tick];
    [self updateDisplayLink];
}

- (void)assignSlotForController:(GCController *)controller {
    // The Siri Remote only exposes a micro gamepad and keeps driving the browser UI.
    if (controller.extendedGamepad == nil || [self.slots containsObject:controller]) {
        return;
    }
    NSUInteger freeIndex = [self.slots indexOfObject:[NSNull null]];
    if (freeIndex == NSNotFound) {
        return;
    }
    self.slots[freeIndex] = controller;
}

- (BOOL)hasConnectedGamepads {
    for (id slot in self.slots) {
        if (slot != [NSNull null]) {
            return YES;
        }
    }
    return NO;
}

- (void)updateDisplayLink {
    BOOL shouldRun = self.started && [self hasConnectedGamepads];
    if (shouldRun && self.displayLink == nil) {
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleDisplayLink:)];
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    } else if (!shouldRun && self.displayLink != nil) {
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
}

#pragma mark - State

- (NSDictionary *)stateForController:(GCController *)controller index:(NSUInteger)index {
    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    // Order follows the W3C "standard" gamepad mapping.
    NSArray *buttons = @[
        BrowserGamepadButtonEntry(gamepad.buttonA),
        BrowserGamepadButtonEntry(gamepad.buttonB),
        BrowserGamepadButtonEntry(gamepad.buttonX),
        BrowserGamepadButtonEntry(gamepad.buttonY),
        BrowserGamepadButtonEntry(gamepad.leftShoulder),
        BrowserGamepadButtonEntry(gamepad.rightShoulder),
        BrowserGamepadButtonEntry(gamepad.leftTrigger),
        BrowserGamepadButtonEntry(gamepad.rightTrigger),
        BrowserGamepadButtonEntry(gamepad.buttonOptions),
        BrowserGamepadButtonEntry(gamepad.buttonMenu),
        BrowserGamepadButtonEntry(gamepad.leftThumbstickButton),
        BrowserGamepadButtonEntry(gamepad.rightThumbstickButton),
        BrowserGamepadButtonEntry(gamepad.dpad.up),
        BrowserGamepadButtonEntry(gamepad.dpad.down),
        BrowserGamepadButtonEntry(gamepad.dpad.left),
        BrowserGamepadButtonEntry(gamepad.dpad.right),
        BrowserGamepadButtonEntry(gamepad.buttonHome),
    ];
    // Web axes grow downwards, GameController's Y axes grow upwards.
    NSArray *axes = @[
        @(gamepad.leftThumbstick.xAxis.value),
        @(-gamepad.leftThumbstick.yAxis.value),
        @(gamepad.rightThumbstick.xAxis.value),
        @(-gamepad.rightThumbstick.yAxis.value),
    ];
    NSString *name = controller.vendorName.length > 0 ? controller.vendorName : @"Game Controller";
    return @{
        @"index": @(index),
        @"id": [NSString stringWithFormat:@"%@ (STANDARD GAMEPAD)", name],
        @"buttons": buttons,
        @"axes": axes,
    };
}

- (NSArray *)currentStates {
    NSMutableArray *states = [NSMutableArray array];
    [self.slots enumerateObjectsUsingBlock:^(id slot, NSUInteger index, BOOL *stop) {
        (void)stop;
        if (slot != [NSNull null] && ((GCController *)slot).extendedGamepad != nil) {
            [states addObject:[self stateForController:slot index:index]];
        }
    }];
    return states;
}

- (BOOL)statesShowActivity:(NSArray<NSDictionary *> *)states comparedTo:(NSArray<NSDictionary *> *)previousStates {
    for (NSDictionary *state in states) {
        NSDictionary *previous = nil;
        for (NSDictionary *candidate in previousStates) {
            if ([candidate[@"index"] isEqual:state[@"index"]]) {
                previous = candidate;
                break;
            }
        }
        NSArray *buttons = state[@"buttons"];
        NSArray *previousButtons = previous[@"buttons"];
        for (NSUInteger index = 0; index < buttons.count; index++) {
            BOOL pressed = [buttons[index][0] boolValue];
            BOOL wasPressed = index < previousButtons.count ? [previousButtons[index][0] boolValue] : NO;
            if (pressed || pressed != wasPressed) {
                return YES;
            }
        }
        for (NSNumber *axis in state[@"axes"]) {
            if (fabsf(axis.floatValue) > kBrowserGamepadStickActivityThreshold) {
                return YES;
            }
        }
    }
    return NO;
}

- (void)handleDisplayLink:(CADisplayLink *)displayLink {
    (void)displayLink;
    [self tick];
}

- (void)tick {
    CFTimeInterval now = CACurrentMediaTime();
    NSArray *states = [self currentStates];
    if ([self statesShowActivity:states comparedTo:self.lastSnapshot]) {
        self.lastActivityTimestamp = now;
    }
    self.lastSnapshot = states;

    BrowserWebView *webView = self.activeWebViewProvider ? self.activeWebViewProvider() : nil;
    if (webView != self.lastWebView) {
        // Release any held buttons in the tab we are leaving.
        [self.lastWebView evaluateJavaScript:@"window.__tvosGamepadUpdate && window.__tvosGamepadUpdate([])" completionHandler:nil];
        self.lastWebView = webView;
        [self setNeedsStateResend];
    }
    if (webView == nil) {
        return;
    }

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:states options:0 error:nil];
    NSString *payload = jsonData != nil ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : @"[]";
    BOOL changed = ![payload isEqualToString:self.lastSentPayload];
    if (!changed && (now - self.lastSendTimestamp) < kBrowserGamepadHeartbeatInterval) {
        return;
    }
    self.lastSentPayload = payload;
    self.lastSendTimestamp = now;

    NSString *script = [NSString stringWithFormat:@"window.__tvosGamepadUpdate ? window.__tvosGamepadUpdate(%@) : false", payload];
    __weak typeof(self) weakSelf = self;
    [webView evaluateJavaScript:script completionHandler:^(id result) {
        if ([result respondsToSelector:@selector(boolValue)] && [result boolValue]) {
            weakSelf.lastPageUsageTimestamp = CACurrentMediaTime();
        }
    }];
}

#pragma mark - Press suppression

- (BOOL)isPageConsumingGamepad {
    if (![self hasConnectedGamepads]) {
        return NO;
    }
    if ((CACurrentMediaTime() - self.lastPageUsageTimestamp) > kBrowserGamepadPageUsageTimeout) {
        return NO;
    }
    return self.pageInteractiveProvider == nil || self.pageInteractiveProvider();
}

- (BOOL)isPressFromGamepad:(UIPress *)press {
    CFTimeInterval now = CACurrentMediaTime();
    if ((now - self.lastActivityTimestamp) < kBrowserGamepadPressMatchInterval) {
        return YES;
    }
    for (id slot in self.slots) {
        if (slot == [NSNull null]) {
            continue;
        }
        GCExtendedGamepad *gamepad = ((GCController *)slot).extendedGamepad;
        if (fabs(gamepad.lastEventTimestamp - press.timestamp) < kBrowserGamepadPressMatchInterval) {
            return YES;
        }
        for (GCControllerButtonInput *button in gamepad.allButtons) {
            if (button.isPressed) {
                return YES;
            }
        }
    }
    return NO;
}

- (BOOL)shouldSuppressSystemPress:(UIPress *)press {
    if ([self.suppressedPresses containsObject:press]) {
        if (press.phase == UIPressPhaseEnded || press.phase == UIPressPhaseCancelled) {
            [self.suppressedPresses removeObject:press];
        }
        return YES;
    }
    // Decide once per press so UIKit never sees half of a press sequence.
    if (press.phase != UIPressPhaseBegan) {
        return NO;
    }
    if (![self isPageConsumingGamepad] || ![self isPressFromGamepad:press]) {
        return NO;
    }
    [self.suppressedPresses addObject:press];
    return YES;
}

@end
