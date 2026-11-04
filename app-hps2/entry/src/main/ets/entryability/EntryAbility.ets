import { BusinessError } from '@ohos.base';
import hilog from '@ohos.hilog';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import hps2core from 'libhps2core.so';

const DOMAIN = 0x3202;
const TAG = 'HPS2_CORE';

export default class EntryAbility extends UIAbility {
  private applyRendererDiagnostic(want: Want): void {
    const jitProfile = want.parameters?.['hps2JitProfile'];
    hps2core.setDiagnosticJitProfile(jitProfile === 'on');
    hps2core.setDiagnosticThreadQoS(want.parameters?.['hps2ThreadQoS'] === 'user-initiated');
    const affinityValue = want.parameters?.['hps2Affinity'];
    const affinity: number = affinityValue === 'performance' ? 1 : affinityValue === 'ee-prime' ? 2 :
      affinityValue === 'gs-prime' ? 3 : affinityValue === 'vu-prime' ? 4 : affinityValue === 'middle-only' ? 5 : 0;
    hps2core.setDiagnosticAffinity(affinity);
    const instantValue = want.parameters?.['hps2InstantVU1'];
    const rateValue = want.parameters?.['hps2EECycleRate'];
    const skipValue = want.parameters?.['hps2EECycleSkip'];
    const instant: number = instantValue === 'off' ? 0 : instantValue === 'on' ? 1 : -1;
    const rate: number = typeof rateValue === 'string' ? parseInt(rateValue, 10) : 99;
    const skip: number = typeof skipValue === 'string' ? parseInt(skipValue, 10) : -1;
    hps2core.setDiagnosticTiming(instant, rate, skip);
    const value = want.parameters?.['hps2Renderer'];
    const renderer: string = typeof value === 'string' ? value : 'default';
    const accepted: number = hps2core.setDiagnosticRenderer(renderer);
    hilog.warn(DOMAIN, TAG, 'RENDERER_DIAG: launch=%{public}s accepted=%{public}d',
      renderer, accepted);
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
    this.applyRendererDiagnostic(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.applyRendererDiagnostic(want);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent succeeded');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onBackground');
  }
}
