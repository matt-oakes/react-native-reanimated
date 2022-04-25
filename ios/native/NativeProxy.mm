#import <RNReanimated/LayoutAnimationsProxy.h>
#import <RNReanimated/NativeMethods.h>
#import <RNReanimated/NativeProxy.h>
#import <RNReanimated/REAAnimationsManager.h>
#import <RNReanimated/REAIOSErrorHandler.h>
#import <RNReanimated/REAIOSScheduler.h>
#import <RNReanimated/REAModule.h>
#import <RNReanimated/REANodesManager.h>
#import <RNReanimated/REAUIManager.h>
#import <RNReanimated/RNGestureHandlerStateManager.h>
#import <RNReanimated/ReanimatedSensorContainer.h>
#import <RNReanimated/ReanimatedUIManagerBinding.h>
#import <React-Fabric/react/renderer/core/ShadowNode.h> // ShadowNode::Shared
#import <React-Fabric/react/renderer/uimanager/primitives.h> // shadowNodeFromValue
#import <React/RCTFollyConvert.h>
#import <React/RCTUIManager.h>

#import <React/RCTBridge+Private.h>
#import <React/RCTScheduler.h>
#import <React/RCTSurfacePresenter.h>

#if TARGET_IPHONE_SIMULATOR
#import <dlfcn.h>
#endif

#if __has_include(<reacthermes/HermesExecutorFactory.h>)
#import <reacthermes/HermesExecutorFactory.h>
#elif __has_include(<hermes/hermes.h>)
#import <hermes/hermes.h>
#else
#import <jsi/JSCRuntime.h>
#endif

namespace reanimated {

using namespace facebook;
using namespace react;

static CGFloat SimAnimationDragCoefficient(void)
{
  static float (*UIAnimationDragCoefficient)(void) = NULL;
#if TARGET_IPHONE_SIMULATOR
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    UIAnimationDragCoefficient = (float (*)(void))dlsym(RTLD_DEFAULT, "UIAnimationDragCoefficient");
  });
#endif
  return UIAnimationDragCoefficient ? UIAnimationDragCoefficient() : 1.f;
}

static CFTimeInterval calculateTimestampWithSlowAnimations(CFTimeInterval currentTimestamp)
{
#if TARGET_IPHONE_SIMULATOR
  static CFTimeInterval dragCoefChangedTimestamp = CACurrentMediaTime();
  static CGFloat previousDragCoef = SimAnimationDragCoefficient();

  const CGFloat dragCoef = SimAnimationDragCoefficient();
  if (previousDragCoef != dragCoef) {
    previousDragCoef = dragCoef;
    dragCoefChangedTimestamp = CACurrentMediaTime();
  }

  const bool areSlowAnimationsEnabled = dragCoef != 1.f;
  if (areSlowAnimationsEnabled) {
    return (dragCoefChangedTimestamp + (currentTimestamp - dragCoefChangedTimestamp) / dragCoef);
  } else {
    return currentTimestamp;
  }
#else
  return currentTimestamp;
#endif
}

// COPIED FROM RCTTurboModule.mm
static id convertJSIValueToObjCObject(jsi::Runtime &runtime, const jsi::Value &value);

static NSString *convertJSIStringToNSString(jsi::Runtime &runtime, const jsi::String &value)
{
  return [NSString stringWithUTF8String:value.utf8(runtime).c_str()];
}

static NSDictionary *convertJSIObjectToNSDictionary(jsi::Runtime &runtime, const jsi::Object &value)
{
  jsi::Array propertyNames = value.getPropertyNames(runtime);
  size_t size = propertyNames.size(runtime);
  NSMutableDictionary *result = [NSMutableDictionary new];
  for (size_t i = 0; i < size; i++) {
    jsi::String name = propertyNames.getValueAtIndex(runtime, i).getString(runtime);
    NSString *k = convertJSIStringToNSString(runtime, name);
    id v = convertJSIValueToObjCObject(runtime, value.getProperty(runtime, name));
    if (v) {
      result[k] = v;
    }
  }
  return [result copy];
}

static NSArray *convertJSIArrayToNSArray(jsi::Runtime &runtime, const jsi::Array &value)
{
  size_t size = value.size(runtime);
  NSMutableArray *result = [NSMutableArray new];
  for (size_t i = 0; i < size; i++) {
    // Insert kCFNull when it's `undefined` value to preserve the indices.
    [result addObject:convertJSIValueToObjCObject(runtime, value.getValueAtIndex(runtime, i)) ?: (id)kCFNull];
  }
  return [result copy];
}

static id convertJSIValueToObjCObject(jsi::Runtime &runtime, const jsi::Value &value)
{
  if (value.isUndefined() || value.isNull()) {
    return nil;
  }
  if (value.isBool()) {
    return @(value.getBool());
  }
  if (value.isNumber()) {
    return @(value.getNumber());
  }
  if (value.isString()) {
    return convertJSIStringToNSString(runtime, value.getString(runtime));
  }
  if (value.isObject()) {
    jsi::Object o = value.getObject(runtime);
    if (o.isArray(runtime)) {
      return convertJSIArrayToNSArray(runtime, o.getArray(runtime));
    }
    return convertJSIObjectToNSDictionary(runtime, o);
  }

  throw std::runtime_error("Unsupported jsi::jsi::Value kind");
}

/**
 * All static helper functions are ObjC++ specific.
 */
static jsi::Value convertNSNumberToJSIBoolean(jsi::Runtime &runtime, NSNumber *value)
{
  return jsi::Value((bool)[value boolValue]);
}

static jsi::Value convertNSNumberToJSINumber(jsi::Runtime &runtime, NSNumber *value)
{
  return jsi::Value([value doubleValue]);
}

static jsi::String convertNSStringToJSIString(jsi::Runtime &runtime, NSString *value)
{
  return jsi::String::createFromUtf8(runtime, [value UTF8String] ?: "");
}

static jsi::Value convertObjCObjectToJSIValue(jsi::Runtime &runtime, id value);
static jsi::Object convertNSDictionaryToJSIObject(jsi::Runtime &runtime, NSDictionary *value)
{
  jsi::Object result = jsi::Object(runtime);
  for (NSString *k in value) {
    result.setProperty(runtime, [k UTF8String], convertObjCObjectToJSIValue(runtime, value[k]));
  }
  return result;
}

static jsi::Array convertNSArrayToJSIArray(jsi::Runtime &runtime, NSArray *value)
{
  jsi::Array result = jsi::Array(runtime, value.count);
  for (size_t i = 0; i < value.count; i++) {
    result.setValueAtIndex(runtime, i, convertObjCObjectToJSIValue(runtime, value[i]));
  }
  return result;
}

static std::vector<jsi::Value> convertNSArrayToStdVector(jsi::Runtime &runtime, NSArray *value)
{
  std::vector<jsi::Value> result;
  for (size_t i = 0; i < value.count; i++) {
    result.emplace_back(convertObjCObjectToJSIValue(runtime, value[i]));
  }
  return result;
}

static jsi::Value convertObjCObjectToJSIValue(jsi::Runtime &runtime, id value)
{
  if ([value isKindOfClass:[NSString class]]) {
    return convertNSStringToJSIString(runtime, (NSString *)value);
  } else if ([value isKindOfClass:[NSNumber class]]) {
    if ([value isKindOfClass:[@YES class]]) {
      return convertNSNumberToJSIBoolean(runtime, (NSNumber *)value);
    }
    return convertNSNumberToJSINumber(runtime, (NSNumber *)value);
  } else if ([value isKindOfClass:[NSDictionary class]]) {
    return convertNSDictionaryToJSIObject(runtime, (NSDictionary *)value);
  } else if ([value isKindOfClass:[NSArray class]]) {
    return convertNSArrayToJSIArray(runtime, (NSArray *)value);
  } else if (value == (id)kCFNull) {
    return jsi::Value::null();
  }
  return jsi::Value::undefined();
}
// COPIED FROM RCTTurboModule.mm END

static NSSet *convertProps(jsi::Runtime &rt, const jsi::Value &props)
{
  NSMutableSet *propsSet = [[NSMutableSet alloc] init];
  jsi::Array propsNames = props.asObject(rt).asArray(rt);
  for (int i = 0; i < propsNames.size(rt); i++) {
    NSString *propName = @(propsNames.getValueAtIndex(rt, i).asString(rt).utf8(rt).c_str());
    [propsSet addObject:propName];
  }
  return propsSet;
}

std::shared_ptr<NativeReanimatedModule> createReanimatedModule(
    RCTBridge *bridge,
    std::shared_ptr<CallInvoker> jsInvoker)
{
  REAModule *reanimatedModule = [bridge moduleForClass:[REAModule class]];

  // TODO: create NewestShadowNodesRegistry somewhere else
  auto newestShadowNodesRegistry = getNewestShadowNodesRegistry();

  // RCTUIManager *uiManager = reanimatedModule.nodesManager.uiManager;

  id<RNGestureHandlerStateManager> gestureHandlerStateManager = [bridge moduleForName:@"RNGestureHandlerModule"];
  auto setGestureStateFunction = [gestureHandlerStateManager](int handlerTag, int newState) {
    setGestureState(gestureHandlerStateManager, handlerTag, newState);
  };

  auto propObtainer = [reanimatedModule](
                          jsi::Runtime &rt, const int viewTag, const jsi::String &propName) -> jsi::Value {
    // TODO: support propObtainer on Fabric?
    return jsi::Value::undefined();
  };

#if __has_include(<reacthermes/HermesExecutorFactory.h>)
  std::shared_ptr<jsi::Runtime> animatedRuntime = facebook::hermes::makeHermesRuntime();
#elif __has_include(<hermes/hermes.h>)
  std::shared_ptr<jsi::Runtime> animatedRuntime = facebook::hermes::makeHermesRuntime();
#else
  std::shared_ptr<jsi::Runtime> animatedRuntime = facebook::jsc::makeJSCRuntime();
#endif

  std::shared_ptr<Scheduler> scheduler = std::make_shared<REAIOSScheduler>(jsInvoker);
  std::shared_ptr<ErrorHandler> errorHandler = std::make_shared<REAIOSErrorHandler>(scheduler);
  std::shared_ptr<NativeReanimatedModule> module;

  __block std::weak_ptr<Scheduler> weakScheduler = scheduler;
  // ((REAUIManager *)uiManager).flushUiOperations = ^void() {
  //   std::shared_ptr<Scheduler> scheduler = weakScheduler.lock();
  //   if (scheduler != nullptr) {
  //     scheduler->triggerUI();
  //   }
  // };

  auto requestRender = [reanimatedModule, &module](std::function<void(double)> onRender, jsi::Runtime &rt) {
    [reanimatedModule.nodesManager postOnAnimation:^(CADisplayLink *displayLink) {
      double frameTimestamp = calculateTimestampWithSlowAnimations(displayLink.targetTimestamp) * 1000;
      jsi::Object global = rt.global(); // TODO: fix crash on reload
      jsi::String frameTimestampName = jsi::String::createFromAscii(rt, "_frameTimestamp");
      global.setProperty(rt, frameTimestampName, frameTimestamp);
      onRender(frameTimestamp);
      global.setProperty(rt, frameTimestampName, jsi::Value::undefined());
    }];
  };

  auto synchronouslyUpdateUIPropsFunction = [reanimatedModule](jsi::Runtime &rt, Tag tag, const jsi::Value &props) {
    NSNumber *viewTag = @(tag);
    NSDictionary *uiProps = convertJSIObjectToNSDictionary(rt, props.asObject(rt));
    [reanimatedModule.nodesManager synchronouslyUpdateViewOnUIThread:viewTag props:uiProps];
  };

  auto getCurrentTime = []() { return calculateTimestampWithSlowAnimations(CACurrentMediaTime()) * 1000; };

  // Layout Animations start
  // REAUIManager *reaUiManagerNoCast = [bridge moduleForClass:[REAUIManager class]];
  // RCTUIManager *reaUiManager = reaUiManagerNoCast;
  // REAAnimationsManager *animationsManager = [[REAAnimationsManager alloc] initWithUIManager:reaUiManager];
  // [reaUiManagerNoCast setUp:animationsManager];

  auto notifyAboutProgress = [=](int tag, jsi::Object newStyle) {
    // if (animationsManager) {
    //   NSDictionary *propsDict = convertJSIObjectToNSDictionary(*animatedRuntime, newStyle);
    //   [animationsManager notifyAboutProgress:propsDict tag:[NSNumber numberWithInt:tag]];
    // }
  };

  auto notifyAboutEnd = [=](int tag, bool isCancelled) {
    // if (animationsManager) {
    //   [animationsManager notifyAboutEnd:[NSNumber numberWithInt:tag] cancelled:isCancelled];
    // }
  };

  auto configurePropsFunction = [reanimatedModule](
                                    jsi::Runtime &rt, const jsi::Value &uiProps, const jsi::Value &nativeProps) {
    NSSet *uiPropsSet = convertProps(rt, uiProps);
    NSSet *nativePropsSet = convertProps(rt, nativeProps);
    [reanimatedModule.nodesManager configureUiProps:uiPropsSet andNativeProps:nativePropsSet];
  };

  std::shared_ptr<LayoutAnimationsProxy> layoutAnimationsProxy =
      std::make_shared<LayoutAnimationsProxy>(notifyAboutProgress, notifyAboutEnd);
  std::weak_ptr<jsi::Runtime> wrt = animatedRuntime;
  /*[animationsManager setAnimationStartingBlock:^(
                         NSNumber *_Nonnull tag, NSString *type, NSDictionary *_Nonnull values, NSNumber *depth) {
    std::shared_ptr<jsi::Runtime> rt = wrt.lock();
    if (wrt.expired()) {
      return;
    }
    jsi::Object yogaValues(*rt);
    for (NSString *key in values.allKeys) {
      NSNumber *value = values[key];
      yogaValues.setProperty(*rt, [key UTF8String], [value doubleValue]);
    }

    jsi::Value layoutAnimationRepositoryAsValue =
        rt->global().getPropertyAsObject(*rt, "global").getProperty(*rt, "LayoutAnimationRepository");
    if (!layoutAnimationRepositoryAsValue.isUndefined()) {
      jsi::Function startAnimationForTag =
          layoutAnimationRepositoryAsValue.getObject(*rt).getPropertyAsFunction(*rt, "startAnimationForTag");
      startAnimationForTag.call(
          *rt,
          jsi::Value([tag intValue]),
          jsi::String::createFromAscii(*rt, std::string([type UTF8String])),
          yogaValues,
          jsi::Value([depth intValue]));
    }
  }];

  [animationsManager setRemovingConfigBlock:^(NSNumber *_Nonnull tag) {
    std::shared_ptr<jsi::Runtime> rt = wrt.lock();
    if (wrt.expired()) {
      return;
    }
    jsi::Value layoutAnimationRepositoryAsValue =
        rt->global().getPropertyAsObject(*rt, "global").getProperty(*rt, "LayoutAnimationRepository");
    if (!layoutAnimationRepositoryAsValue.isUndefined()) {
      jsi::Function removeConfig =
          layoutAnimationRepositoryAsValue.getObject(*rt).getPropertyAsFunction(*rt, "removeConfig");
      removeConfig.call(*rt, jsi::Value([tag intValue]));
    }
  }];*/

  // Layout Animations end

  // sensors
  ReanimatedSensorContainer *reanimatedSensorContainer = [[ReanimatedSensorContainer alloc] init];
  auto registerSensorFunction = [=](int sensorType, int interval, std::function<void(double[])> setter) -> int {
    return [reanimatedSensorContainer registerSensor:(ReanimatedSensorType)sensorType
                                            interval:interval
                                              setter:^(double *data) {
                                                setter(data);
                                              }];
  };

  auto unregisterSensorFunction = [=](int sensorId) { [reanimatedSensorContainer unregisterSensor:sensorId]; };
  // end sensors

  PlatformDepMethodsHolder platformDepMethodsHolder = {
      requestRender,
      synchronouslyUpdateUIPropsFunction,
      getCurrentTime,
      registerSensorFunction,
      unregisterSensorFunction,
      setGestureStateFunction,
      configurePropsFunction};

  module = std::make_shared<NativeReanimatedModule>(
      jsInvoker,
      scheduler,
      animatedRuntime,
      errorHandler,
      propObtainer,
      layoutAnimationsProxy,
      newestShadowNodesRegistry,
      platformDepMethodsHolder);

  scheduler->setRuntimeManager(module);

  [reanimatedModule.nodesManager registerEventHandler:^(NSString *eventNameNSString, id<RCTEvent> event) {
    // handles RCTEvents from RNGestureHandler

    auto &rt = *module->runtime;

    std::string eventName = [eventNameNSString UTF8String];
    jsi::Value payload = convertNSDictionaryToJSIObject(rt, [event arguments][2]);
    // TODO: check if NaN and INF values are converted properly

    jsi::Object global = rt.global();
    jsi::String eventTimestampName = jsi::String::createFromAscii(rt, "_eventTimestamp");
    global.setProperty(rt, eventTimestampName, CACurrentMediaTime() * 1000);
    module->onEvent(eventName, std::move(payload));
    global.setProperty(rt, eventTimestampName, jsi::Value::undefined());
  }];

  std::weak_ptr<NativeReanimatedModule> weakModule = module; // to avoid retain cycle
  [reanimatedModule.nodesManager registerPerformOperations:^() {
    weakModule.lock()->performOperations();
  }];

  __weak RCTSurfacePresenter *surfacePresenter = reinterpret_cast<RCTSurfacePresenter *>(bridge.surfacePresenter);
  auto scheduler_ = [surfacePresenter scheduler];
  auto eventListener = std::make_shared<facebook::react::EventListener>(
      [module](const RawEvent &rawEvent) { return module->handleRawEvent(rawEvent, CACurrentMediaTime() * 1000); });
  [scheduler_ addEventListener:eventListener];
  return module;
}

}
