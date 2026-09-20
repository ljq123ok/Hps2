/*
 * Hps2 — 沉浸式全屏控制
 *
 * 解决的问题：游玩时屏幕下方的系统导航条（"小横条"）不隐藏，
 * 既遮挡画面，也可能被误触。
 *
 * 做法：进入游玩页时隐藏系统栏，回到首页时恢复。
 *   setWindowSystemBarEnable([])        —— 传空数组即隐藏全部系统栏
 *   setWindowLayoutFullScreen(true)     —— 让内容延伸到系统栏原本占用的区域
 *
 * 两者必须配套：只隐藏系统栏而不开 layoutFullScreen，原区域会留出空白，
 * 画面仍不占满。
 *
 * 注意：这两个接口返回 Promise，失败不应影响主流程（例如某些设备/模式下
 * 不支持时），因此统一 catch 后只记日志，不抛出。
 */
import window from '@ohos.window';
import hilog from '@ohos.hilog';
import common from '@ohos.app.ability.common';

const DOMAIN = 0x3202;
const TAG = 'HPS2_CORE';

export class Immersive {
  /**
   * 设置游玩时的窗口方向。
   * 游戏固定使用横屏；离开游戏时恢复跟随系统传感器。
   */
  static async setGameOrientation(inGame: boolean, ctx: common.UIAbilityContext): Promise<void> {
    try {
      const win: window.Window = await window.getLastWindow(ctx);
      await win.setPreferredOrientation(
        inGame ? window.Orientation.LANDSCAPE : window.Orientation.AUTO_ROTATION);
      hilog.info(DOMAIN, TAG, 'Immersive.setGameOrientation(%{public}d) applied',
        inGame ? 1 : 0);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'setGameOrientation(%{public}d) failed: %{public}s',
        inGame ? 1 : 0, err.message);
    }
  }

  /**
   * 开关沉浸式全屏。
   *
   * @param enable true=隐藏系统栏并全屏布局；false=恢复系统栏
   * @param ctx 页面上下文（通常传 getContext(this)）
   */
  static async set(enable: boolean, ctx: common.UIAbilityContext): Promise<void> {
    try {
      const win: window.Window = await window.getLastWindow(ctx);

      // 1) 布局是否延伸到系统栏区域
      await win.setWindowLayoutFullScreen(enable);

      // 2) 系统栏显隐。传空数组 = 全部隐藏；传全名 = 全部显示。
      const bars: Array<'status' | 'navigation'> = enable ? [] : ['status', 'navigation'];
      await win.setWindowSystemBarEnable(bars);

      hilog.info(DOMAIN, TAG, 'Immersive.set(%{public}d) applied', enable ? 1 : 0);
    } catch (e) {
      // 不阻断：拿不到窗口或设备不支持时，最多是系统栏没隐藏，
      // 不应因此让游玩流程失败。
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'Immersive.set(%{public}d) failed: %{public}s',
        enable ? 1 : 0, err.message);
    }
  }
}
