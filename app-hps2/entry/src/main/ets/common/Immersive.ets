/*
 * Hps2 — 沉浸式全屏控制
 *
 * 解决的问题：
 *   1. 游玩时屏幕下方的系统导航条（"小横条"）不隐藏，既遮挡画面，也可能被误触。
 *   2. 游玩时系统按"用户无操作"计时自动息屏 —— 播片（过场动画）期间
 *      玩家长时间不碰屏幕，系统据此判定空闲而息屏，画面被打断。
 *
 * 做法：进入游玩页时隐藏系统栏并保持屏幕常亮，回到首页时恢复。
 *   setWindowSystemBarEnable([])        —— 传空数组即隐藏全部系统栏
 *   setWindowLayoutFullScreen(true)     —— 让内容延伸到系统栏原本占用的区域
 *   setWindowKeepScreenOn(true)         —— 窗口级"屏幕常亮"标志，由系统内部
 *                                          持锁，息屏计时不再生效
 *
 * 前两者必须配套：只隐藏系统栏而不开 layoutFullScreen，原区域会留出空白，
 * 画面仍不占满。
 *
 * 为什么常亮用窗口接口而不是 runningLock / ohos.power：
 *   setWindowKeepScreenOn 只作用于本窗口且无需申请权限（ohos.permission.RUNNING_LOCK
 *   是 system_grant 的受限权限，普通应用不应为"别息屏"这种诉求去申请）。
 *   窗口标志随窗口生命周期自动收敛，不必自己管锁的释放时机 ——
 *   这正是"息屏计时"要解决的问题：让系统知道**画面仍在更新**。
 *
 * 注意：这些接口返回 Promise，失败不应影响主流程（例如某些设备/模式下
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
    let win: window.Window | null = null;
    try {
      win = await window.getLastWindow(ctx);
    } catch (e) {
      // 拿不到窗口：三项设置都做不了，记录后返回。
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'Immersive.set(%{public}d): getLastWindow failed: %{public}s',
        enable ? 1 : 0, err.message);
      return;
    }

    // 三项设置各自独立 try/catch。
    //
    // 【为什么不能共用一个 try】原实现是两项（布局 + 系统栏）共用一个 try。
    // 现在多加了"屏幕常亮"，若仍共用，任何一项抛错都会跳过其后所有项 ——
    // 结果是"某个观感设置不支持"连累"屏幕常亮"也跟着失效。
    // 而常亮直接决定用户能否连续游玩，不该被系统栏这类纯观感设置连累。
    // 三者互不依赖，各自成对，谁失败都不影响其余。

    // 1) 屏幕常亮。**优先设置**：它直接决定用户能否连续游玩，
    //    优先级高于系统栏与布局这两项纯观感设置。
    try {
      await win.setWindowKeepScreenOn(enable);
      hilog.info(DOMAIN, TAG, 'Immersive.set(%{public}d): keepScreenOn applied', enable ? 1 : 0);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'setWindowKeepScreenOn(%{public}d) failed: %{public}s',
        enable ? 1 : 0, err.message);
    }

    // 2) 布局是否延伸到系统栏区域
    try {
      await win.setWindowLayoutFullScreen(enable);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'setWindowLayoutFullScreen(%{public}d) failed: %{public}s',
        enable ? 1 : 0, err.message);
    }

    // 3) 系统栏显隐。传空数组 = 全部隐藏；传全名 = 全部显示。
    try {
      const bars: Array<'status' | 'navigation'> = enable ? [] : ['status', 'navigation'];
      await win.setWindowSystemBarEnable(bars);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'setWindowSystemBarEnable(%{public}d) failed: %{public}s',
        enable ? 1 : 0, err.message);
    }

    hilog.info(DOMAIN, TAG, 'Immersive.set(%{public}d) done', enable ? 1 : 0);
  }
}
