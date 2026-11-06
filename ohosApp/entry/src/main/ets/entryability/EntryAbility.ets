import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import Napi from 'libkuikly_entry.so';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, 'kuikly', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(0x0000, 'kuikly', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(0x0000, 'kuikly', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, 'kuikly', 'Failed to load content. Cause: %{public}s', JSON.stringify(err) ?? '');
        return;
      }
      hilog.info(0x0000, 'kuikly', 'Succeeded in loading content.');
      Napi.setResourceManager(getContext()?.resourceManager);
    });

    let mainWindow = windowStage.getMainWindowSync();
    // 全屏布局：内容延伸至状态栏区域，由页面按 safeAreaInsets.top 预留状态栏高度
    // （见 LLMChatPage 的状态栏避让）。
    mainWindow.setWindowLayoutFullScreen(true);
    // 状态栏区域与白色顶部导航栏（#FFFFFF）同色，状态栏图标使用深色；
    // 若使用白色图标，在浅色背景上不可见。底部导航区同样采用浅色。
    mainWindow.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      statusBarContentColor: '#000000',
      navigationBarColor: '#00000000',
      navigationBarContentColor: '#000000',
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, 'kuikly', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(0x0000, 'kuikly', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(0x0000, 'kuikly', '%{public}s', 'Ability onBackground');
  }
}
