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
import { GamepadCatcher } from './GamepadCatcher';
import { PadGroup, PadLayoutVariant } from '../common/PadLayout';
import display from '@ohos.display';

const DOMAIN = 0x3202;
const TAG = 'HPS2_CORE';

@Component
export struct GameScreen {
  /** 是否显示虚拟按键（接入手柄后可由父组件关闭） */
  @Prop showPad: boolean = true;
  /** 由父组件传入是否在游玩中（决定是否叠加按键） */
  @Prop @Watch('onPlayingChanged') playing: boolean = false;
  /** 官方 GameControllerKit 已接管实体手柄；此时不能再让 ArkUI 抢焦点。 */
  @Prop nativeGamepad: boolean = false;
  /**
   * 触控布局编辑态。
   *
   * 编辑态下：虚拟按键显示虚线选框可拖动，且不向游戏送输入；
   * 实体手柄接收器也要**停用** —— 否则编辑时按手柄会误触游戏，
   * 也会把按键事件消耗在不可见的交互上。
   */
  @Prop padEditMode: boolean = false;
  /**
   * 配色索引。
   *
   * 注：布局版本号**不再经本组件透传** —— VirtualPad 已改用
   * @StorageLink 直接订阅 AppStorage 的 hps2_pad_layout_version。
   * 逐层 @Prop 在真机上会断链（中间层不重渲染则不向下传播），
   * 详见 VirtualPad 中的说明。
   */
  @Prop padStyleIndex: number = 0;
  /** 拖动某组的归一化位移，上报父组件 */
  onPadGroupDragged?: (group: PadGroup, dxNorm: number, dyNorm: number) => void;
  /** 拖动结束，父组件落盘 */
  onPadDragEnd?: () => void;

  /** surface 回调：把尺寸交给父组件，由父组件统一 push 给 native */
  onSurfaceSize?: (w: number, h: number) => void;
  /** 首次检测到蓝牙手柄时回调（供上层自动隐藏虚拟按键） */
  onGamepadDetected?: () => void;

  private xcController: XComponentController = new XComponentController();
  /** 上次已知的方向（用于识别旋转）。0=未知 1=竖屏 2=横屏 */
  private lastOrientation: number = 0;
  /**
   * 上次已上报给 native 的尺寸（px）。
   *
   * 【为什么必须去重】onAreaChange 会在很多与"画面尺寸变化"无关的时机
   * 触发（进入沉浸式、系统栏显隐、同级组件重排等），而每次都会调到
   * native 的 notifyResize —— 而 native 那条路径会暂停 VM、等待 CPU
   * 线程退出执行循环，再恢复运行（见 napi_init.cpp 的 NapiNotifyResize）。
   * 尺寸没变时的重复调用纯属白付这份代价，还可能打断 FPS 统计与音频。
   *
   * 注意：这里只拦"与上次上报完全相同"的尺寸；尺寸真的变了仍会照常上报。
   */
  private lastNotifiedPxW: number = 0;
  private lastNotifiedPxH: number = 0;
  /**
   * 当前是否横屏。虚拟按键按此切换布局 ——
   * 竖屏与横屏的可视空间差异很大，用同一套布局必然溢出或挤在一起
   * （参考 PPSSPP 1.20：横竖屏的触控布局应各自独立设置）。
   */
  @State landscape: boolean = false;
  /**
   * XComponent 的实测宽高（vp）。
   * 虚拟按键按这两个值计算绝对坐标 —— 必须用**实测值**而非硬编码，
   * 否则不同机型/方向下按键位置会偏。
   */
  @State vpW: number = 440;
  @State vpH: number = 674;

  /**
   * vp → px 换算。
   *
   * 【为什么必须有这一步 —— 真机实测的 bug 根因】
   *   ArkUI 的 onAreaChange 给的是 **vp**（虚拟像素），而 native 侧
   *   拿到的尺寸会直接进 OHNativeWindow 与 GS 视口，二者都按 **px** 解释。
   *
   *   真机证据（Pura X Max 展开大屏）：
   *     ArkTS 传 940x665（vp），设备真实窗口 2584x1828（px），
   *     换算比 2584/940 = 2.749。
   *     native 把 940 当 px 用 → 画面只占窗口 36.4%，
   *     其余留空 → 表现为"画面不在中间、且无法全屏"。
   *
   *   外屏（1264x1848）时密度更低，错配不明显，故该问题只在展开大屏暴露。
   *
   * 取密度失败时回退 1.0 —— 宁可保持旧行为（画面偏小），也不要崩溃；
   * 日志会记录回退，便于定位。
   */
  private density(): number {
    try {
      const d = display.getDefaultDisplaySync();
      const r = d.densityPixels;
      if (Number.isFinite(r) && r > 0) {
        return r;
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getDefaultDisplaySync failed, fallback density=1');
    }
    return 1.0;
  }

  /** vp → px（四舍五入到整数像素）*/
  private vp2px(v: number): number {
    return Math.round(v * this.density());
  }

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
      // 传 px：native 的 OHNativeWindow/GS 视口按 px 解释（见 density 注释）
      const pw = this.vp2px(w);
      const ph = this.vp2px(h);
      const ok: number = hps2core.setSurface(sid, pw, ph);
      hilog.info(DOMAIN, TAG,
        // 注意：float 占位符(%{public}f)在本机 hilog 上会串位，
        // 表现为"success 码位置显示成密度值"。改用字符串传递密度。
        'setSurface(%{public}s, %{public}dx%{public}d px [vp=%{public}dx%{public}d, density=%{public}s]) -> %{public}d',
        sid, pw, ph, Math.round(w), Math.round(h), this.density().toFixed(3), ok);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'pushSurface failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 进入游玩态时清空尺寸去重记录。
   *
   * 【为什么必须清】GameScreen 是**常驻挂载**的（首页只是覆盖层，
   * 见 Index.build 的说明），所以本组件实例会跨越多轮「启动→返回」。
   * 若不清空：上一轮已经在相同窗口尺寸下上报过，新一轮启动后
   * onAreaChange 因尺寸相同而被去重拦掉 —— 新 VM 可能收不到
   * 它需要的尺寸，画面停在旧尺寸（Bug B 的回归形态）。
   *
   * 这里只清标记、不直接补发：此刻的 vpW/vpH 可能是初始默认值
   * （440x674），直接发等于把默认值当成真实尺寸报上去。清空后，
   * 启动流程里必然会到来的一次 onAreaChange（进入沉浸式会改变
   * 布局）就会正常上报真实尺寸。
   */
  private onPlayingChanged(): void {
    if (this.playing) {
      this.lastNotifiedPxW = 0;
      this.lastNotifiedPxH = 0;
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
    this.landscape = (orientation === 2);
    this.vpW = w;
    this.vpH = h;
    try {
      // 同样传 px（native 据此重建 GS 视口与正交投影）
      const pw = this.vp2px(w);
      const ph = this.vp2px(h);
      // 尺寸没变就不打扰 native —— notifyResize 会暂停/恢复 VM，
      // 代价远高于一次比较（见上方 lastNotifiedPxW 的说明）。
      if (pw === this.lastNotifiedPxW && ph === this.lastNotifiedPxH) {
        return;
      }
      this.lastNotifiedPxW = pw;
      this.lastNotifiedPxH = ph;
      const ok: number = hps2core.notifyResize(pw, ph);
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
      // Use separate conditional branches for the two orientations.  The
      // surface can rotate while the same GameScreen remains mounted; using
      // one child instance left its absolute-position builders with the
      // initial portrait geometry on the real device.  Recreating the child
      // at the orientation boundary makes the new vpW/vpH the initial
      // geometry instead of relying on a nested Builder to re-measure it.
      // 编辑态下即使"隐藏按键"也要显示 —— 否则用户进了编辑器却看不到东西，
      // 无从调整。退出编辑后恢复 showPad 的语义。
      if ((this.playing || this.padEditMode) && (this.showPad || this.padEditMode) && !this.landscape) {
        VirtualPad({
          landscape: false, vpW: this.vpW, vpH: this.vpH,
          editMode: this.padEditMode,
          styleIndex: this.padStyleIndex,
          onGroupDragged: (g: PadGroup, dx: number, dy: number) => {
            if (this.onPadGroupDragged) { this.onPadGroupDragged(g, dx, dy); }
          },
          onGroupDragEnd: () => {
            if (this.onPadDragEnd) { this.onPadDragEnd(); }
          }
        })
      }
      if ((this.playing || this.padEditMode) && (this.showPad || this.padEditMode) && this.landscape) {
        VirtualPad({
          landscape: this.landscape, vpW: this.vpW, vpH: this.vpH,
          editMode: this.padEditMode,
          styleIndex: this.padStyleIndex,
          onGroupDragged: (g: PadGroup, dx: number, dy: number) => {
            if (this.onPadGroupDragged) { this.onPadGroupDragged(g, dx, dy); }
          },
          onGroupDragEnd: () => {
            if (this.onPadDragEnd) { this.onPadDragEnd(); }
          }
        })
      }

      // 蓝牙手柄事件接收器（零尺寸，不影响视觉与触摸布局）。
      //
      // 放在 Stack 中以保证已挂载并能获焦；它只监听按键/轴事件，
      // 不拦截触摸，因此不影响虚拟按键。
      // 首次收到手柄事件时回调上层，可用于自动隐藏虚拟按键。
      //
      // 三家手柄（Xbox / PlayStation / Switch）通用：
      // 系统层按键码统一，差异只在物理标注，按位置映射即可。
      // 映射表见 common/GamepadKeyMap.ets。
      if (this.playing && !this.nativeGamepad && !this.padEditMode) {
        GamepadCatcher({
          padEnabled: true,
          onFirstEvent: () => {
            if (this.onGamepadDetected) {
              this.onGamepadDetected();
            }
          }
        })
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
