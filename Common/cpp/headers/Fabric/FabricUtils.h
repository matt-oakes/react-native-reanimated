#pragma once

#ifdef ANDROID
#include <Binding.h>
#include <fbjni/fbjni.h>
#endif
#include <react/renderer/uimanager/UIManager.h>

#include <memory>
#include <string>

using namespace facebook::react;

namespace reanimated {

struct UIManagerBindingPublic {
  void *vtable;
  std::shared_ptr<UIManager> uiManager_;
};

struct UIManagerPublic {
  void *vtable;
  SharedComponentDescriptorRegistry componentDescriptorRegistry_;
  UIManagerDelegate *delegate_;
  UIManagerAnimationDelegate *animationDelegate_{nullptr};
  RuntimeExecutor const runtimeExecutor_{};
  ShadowTreeRegistry shadowTreeRegistry_{};
  BackgroundExecutor const backgroundExecutor_{};
  ContextContainer::Shared contextContainer_;
};

#ifdef ANDROID
struct BindingPublic : public jni::HybridClass<Binding>,
                       public SchedulerDelegate,
                       public LayoutAnimationStatusDelegate {
  butter::shared_mutex installMutex_;
  std::shared_ptr<FabricMountingManager> mountingManager_;
  std::shared_ptr<Scheduler> scheduler_;
};

struct SchedulerPublic : public UIManagerDelegate {
  SchedulerDelegate *delegate_;
  SharedComponentDescriptorRegistry componentDescriptorRegistry_;
  RuntimeExecutor runtimeExecutor_;
};

RuntimeExecutor getRuntimeExecutorFromBinding(Binding *binding);

std::shared_ptr<UIManager> getUIManagerFromBinding(Binding *binding);

#endif

std::shared_ptr<UIManager> getUIManagerFromBinding(jsi::Runtime &rt);

const ShadowTreeRegistry *getShadowTreeRegistryFromUIManager(
    const std::shared_ptr<UIManager> &uiManager);

std::shared_ptr<const ContextContainer> getContextContainerFromUIManager(
    const UIManager *uiManager);

void UIManager_dispatchCommand(
    const std::shared_ptr<UIManager> &uiManager,
    const ShadowNode::Shared &shadowNode,
    std::string const &commandName,
    folly::dynamic const &args);

LayoutMetrics UIManager_getRelativeLayoutMetrics(
    const std::shared_ptr<UIManager> &uiManager,
    ShadowNode const &shadowNode,
    ShadowNode const *ancestorShadowNode,
    LayoutableShadowNode::LayoutInspectingPolicy policy);

SharedShadowNode UIManager_cloneNode(
    const UIManager *uiManager,
    const ShadowNode::Shared &shadowNode,
    const SharedShadowNodeSharedList &children = nullptr,
    const RawProps *rawProps = nullptr);

void UIManager_appendChild(
    const ShadowNode::Shared &parentShadowNode,
    const ShadowNode::Shared &childShadowNode);

} // namespace reanimated
