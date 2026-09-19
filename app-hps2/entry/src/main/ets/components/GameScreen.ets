/*
 * Hps2 — 游戏画面区
 *
 * 设计要点（来自设计稿 01）：
 *   PS2 输出为 4:3。横屏时两侧会有黑边 —— **把虚拟按键放在黑边上**，
 *   而不是叠在游戏画面上。这样按键完全不遮挡游戏内容。
 *
 * 本组件只负责：
 *   1. 承载 XComponent（GS 的渲染目标）
 *   2. 把 surface 交给 native
 *   3. 在黑边区域叠加虚拟按键
 *
 * 状态与业务逻辑由父组件（Index）持有，本组件通过回调上报 surface 尺寸。
 */
import hilog from '@ohos.hilog';
import hps2core from 'libhps2core.so';
import { Theme } from '../common/Theme';
import { VirtualPad } from './VirtualPad';

const DOMAIN = 0x3202;
const TAG = 'HPS2_CORE';

@Component
export struct GameScreen {
  /** 是否显示虚拟按键（接入手柄后可由父组件关闭） */
  @Prop showPad: boolean = true;
  /** 由父组件传入是否在游玩中（决定是否叠加按键） */
  @Prop playing: boolean = false;

  /** surface 回调：把尺寸交给父组件，由父组件统一 push 给 native */
  onSurfaceSize?: (w: number, h: number) => void;

  private xcController: XComponentController = new XComponentController();
  /** 上次已知的方向（用于识别旋转）。0=未知 1=竖屏 2=横屏 */
  private lastOrientation: number = 0;

  /**
   * 把 XComponent 的 surfaceId 交给 native，换取 OHNativeWindow。
   *
   * 注意：这一步必须在 XComponent 就绪后做，且要带尺寸 ——
   * native 走的是 surfaceId 路径，拿不到 component 指针，
   * 无法调用 OH_NativeXComponent_GetXComponentSize。
   */
  private pushSurface(w: number, h: number): void {
    try {
      const sid: string = this.xcController.getXComponentSurfaceId();
      if (!sid || sid.length === 0) {
        hilog.error(DOMAIN, TAG, 'getXComponentSurfaceId returned empty');
        return;
      }
      const ok: number = hps2core.setSurface(sid, Math.round(w), Math.round(h));
      hilog.info(DOMAIN, TAG, 'setSurface(%{public}s, %{public}dx%{public}d) -> %{public}d',
        sid, Math.round(w), Math.round(h), ok);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'pushSurface failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 通知 native 新的窗口尺寸。
   *
   * 为什么不能只 pushSurface：
   *   GS 的视口与正交投影是用 WindowInfo.surface_width/height 计算的
   *   （GSDeviceOGL.cpp:3390）。旋转后若只改 surface 尺寸而不让 GS 知道，
   *   画面会错位或只占一角 —— 这正是本项目踩过的坑
   *   （见 docs/stage4-resolution-issue.md）。
   *
   * native 侧会调 MTGS::ResizeDisplayWindow + UpdateDisplayWindow，
   * 并在方向变化时（自动模式下）切换宽高比。
   */
  private notifyResize(w: number, h: number): void {
    const orientation = w > h ? 2 : 1;
    try {
      const ok: number = hps2core.notifyResize(Math.round(w), Math.round(h));
      if (orientation !== this.lastOrientation) {
        hilog.info(DOMAIN, TAG,
          'orientation changed: %{public}s -> notifyResize(%{public}dx%{public}d) = %{public}d',
          this.lastOrientation === 0 ? 'unknown' : (this.lastOrientation === 2 ? 'landscape' : 'portrait'),
          Math.round(w), Math.round(h), ok);
        this.lastOrientation = orientation;
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'notifyResize failed: %{public}s', JSON.stringify(e));
    }
  }

  build() {
    Stack() {
      // 黑底：4:3 画面之外的区域
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.letterbox())

      XComponent({
        id: 'hps2_view',
        type: XComponentType.SURFACE,
        controller: this.xcController
      })
        .width('100%')
        .height('100%')
        .onLoad(() => {
          hilog.info(DOMAIN, TAG, 'XComponent onLoad');
        })
        .onDestroy(() => {
          hilog.info(DOMAIN, TAG, 'XComponent onDestroy');
        })

      // 虚拟按键：仅在游玩中显示。
      // 参考设计稿，按键半透明，尽量不遮挡画面。
      if (this.playing && this.showPad) {
        VirtualPad()
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_, area) => {
      const w = Number(area.width);
      const h = Number(area.height);
      if (w > 0 && h > 0) {
        this.pushSurface(w, h);
        if (this.onSurfaceSize) {
          this.onSurfaceSize(w, h);
        }
        this.notifyResize(w, h);
      }
    })
  }
}
