import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppContainer } from '../app/AppContainer';
import { Logger } from '../utils/Logger';

const DOMAIN: number = 0x0001;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    AppContainer.get().attach(this.context);
    Logger.install();
    hilog.info(DOMAIN, 'TomatoTV', 'EntryAbility onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'TomatoTV', 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      AppContainer.get().attachWindowStage(windowStage);
    });
  }

  onWindowStageDestroy(): void {
    AppContainer.get().detachWindowStage();
  }

  onForeground(): void {
  }

  onBackground(): void {
  }

  onDestroy(): void {
    Logger.info('EntryAbility', 'onDestroy');
  }
}
