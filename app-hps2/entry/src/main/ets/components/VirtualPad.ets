/*
 * Hps2 — 屏幕虚拟手柄（绝对定位版）
 *
 * 【为什么改用绝对定位】
 *   此前用 Row/Column 的 flex 布局，真机上按键被**两个轴分别压缩**：
 *   横向压到 68%、纵向压到 31%（从截图按 3x 反推）。
 *   根因在 ArkUI 的尺寸约束行为，从外部难以稳定控制。
 *   改用 .position({x, y}) 按实测 surface 尺寸直接算坐标后，
 *   不再依赖任何 flex 计算 —— 从根上消除这一类问题。
 *
 * 【坐标来源】父组件把 XComponent 的实测宽高（vp）传进来，
 *   本组件按比例计算每个控件的位置。不使用固定像素，
 *   因此竖屏/横屏、不同机型都不会溢出。
 *
 * 【配色】刻意不跟随日夜主题，一律半透明白 —— 按键叠在**游戏画面**上，
 *   画面可能雪白也可能漆黑，跟随 UI 主题会导致浅色模式下按键"消失"。
 *
 * 【布局参考 PPSSPP 1.20 的经验】其官方说明：
 *   "以前只是简单把横屏界面压缩进竖屏，视觉与操作体验都差；
 *    现在触控按键布局与画面显示布局在横竖屏下分别独立设置。"
 *   故本组件按方向切换整套坐标，而非缩放同一套布局。
 */
import hps2core from 'libhps2core.so';
import { VpadButton, VpadAxis } from '../common/VpadCodes';

@Component
export struct VirtualPad {
  /** 是否横屏 */
  @Prop landscape: boolean = false;
  /** XComponent 实测宽度（vp） */
  @Prop vpW: number = 440;
  /** XComponent 实测高度（vp） */
  @Prop vpH: number = 674;

  @State lsx: number = 0;
  @State lsy: number = 0;
  @State rsx: number = 0;
  @State rsy: number = 0;

  // ---- 尺寸（vp，按屏幕大小自适应但有上下限，避免极小或极大屏上失调）----
  private get btn(): number {
    const base = this.landscape ? this.vpH * 0.085 : this.vpW * 0.095;
    return Math.max(30, Math.min(52, base));
  }
  private get stickR(): number {
    const base = this.landscape ? this.vpH * 0.15 : this.vpW * 0.19;
    return Math.max(26, Math.min(46, base));
  }
  private get stickBox(): number { return this.stickR * 2.4; }
  private get barW(): number { return this.btn * 1.5; }
  private get barH(): number { return Math.max(24, this.btn * 0.62); }
  private get gap(): number { return Math.max(4, this.btn * 0.12); }

  // ---- 坐标计算 ----
  /** 顶部肩键条的 y */
  private get barY(): number { return this.gap + 6; }
  /** 十字键/四键区的中心 y */
  private get midY(): number {
    return this.landscape ? this.vpH * 0.50 : this.vpH * 0.40;
  }
  /** 摇杆中心 y */
  private get stickY(): number {
    return this.landscape ? this.vpH * 0.80 : this.vpH * 0.82;
  }
  /** 左侧控件中心 x */
  private get leftX(): number { return this.landscape ? this.vpW * 0.15 : this.vpW * 0.22; }
  /** 右侧控件中心 x */
  private get rightX(): number { return this.landscape ? this.vpW * 0.85 : this.vpW * 0.78; }

  /** 把中心点换成左上角坐标 */
  private left(cx: number, w: number): number { return cx - w / 2; }
  private top(cy: number, h: number): number { return cy - h / 2; }

  // ================= 控件 =================

  @Builder
  padButton(label: string, code: number, cx: number, cy: number) {
    Text(label)
      .fontSize(this.btn * 0.42)
      .fontColor('#FFFFFF')
      .textAlign(TextAlign.Center)
      .width(this.btn)
      .height(this.btn)
      .borderRadius(this.btn / 2)
      .backgroundColor('#40FFFFFF')
      .border({ width: 1, color: '#80FFFFFF' })
      .position({ x: this.left(cx, this.btn), y: this.top(cy, this.btn) })
      .onTouch((e: TouchEvent) => {
        if (e.type === TouchType.Down) {
          hps2core.vpadButton(code, true);
        } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
          hps2core.vpadButton(code, false);
        }
      })
  }

  @Builder
  bar(label: string, code: number, isTrigger: boolean, cx: number, cy: number) {
    Text(label)
      .fontSize(this.barH * 0.44)
      .fontColor('#FFFFFF')
      .textAlign(TextAlign.Center)
      .width(this.barW)
      .height(this.barH)
      .borderRadius(6)
      .backgroundColor('#40FFFFFF')
      .border({ width: 1, color: '#80FFFFFF' })
      .position({ x: this.left(cx, this.barW), y: this.top(cy, this.barH) })
      .onTouch((e: TouchEvent) => {
        const down = (e.type === TouchType.Down);
        const up = (e.type === TouchType.Up || e.type === TouchType.Cancel);
        if (isTrigger) {
          // L2/R2 在 PCSX2 里是**轴**：按下给满量程、抬起归零
          if (down) { hps2core.vpadAxis(code, 32767); }
          else if (up) { hps2core.vpadAxis(code, 0); }
        } else {
          if (down) { hps2core.vpadButton(code, true); }
          else if (up) { hps2core.vpadButton(code, false); }
        }
      })
  }

  @Builder
  stick(isLeft: boolean, cx: number, cy: number) {
    Stack() {
      Circle()
        .width(this.stickBox)
        .height(this.stickBox)
        .fill('#18FFFFFF')
        .stroke('#60FFFFFF')
        .strokeWidth(1)
      Circle()
        .width(this.stickR)
        .height(this.stickR)
        .fill('#66FFFFFF')
        .offset({
          x: isLeft ? this.lsx : this.rsx,
          y: isLeft ? this.lsy : this.rsy
        })
    }
    .width(this.stickBox)
    .height(this.stickBox)
    .position({ x: this.left(cx, this.stickBox), y: this.top(cy, this.stickBox) })
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        // 回中：轴值必须归零，否则摇杆卡在最后位置
        if (isLeft) {
          this.lsx = 0; this.lsy = 0;
          hps2core.vpadAxis(VpadAxis.LEFTX, 0);
          hps2core.vpadAxis(VpadAxis.LEFTY, 0);
        } else {
          this.rsx = 0; this.rsy = 0;
          hps2core.vpadAxis(VpadAxis.RIGHTX, 0);
          hps2core.vpadAxis(VpadAxis.RIGHTY, 0);
        }
        return;
      }
      if (e.touches.length === 0) {
        return;
      }
      const t = e.touches[0];
      const c = this.stickBox / 2;
      let dx = t.x - c;
      let dy = t.y - c;

      const dist = Math.sqrt(dx * dx + dy * dy);
      if (dist > this.stickR) {
        dx = dx * this.stickR / dist;
        dy = dy * this.stickR / dist;
      }

      if (isLeft) {
        this.lsx = dx; this.lsy = dy;
      } else {
        this.rsx = dx; this.rsy = dy;
      }

      const ax = Math.round(dx / this.stickR * 32767);
      const ay = Math.round(dy / this.stickR * 32767);
      if (isLeft) {
        hps2core.vpadAxis(VpadAxis.LEFTX, ax);
        hps2core.vpadAxis(VpadAxis.LEFTY, ay);
      } else {
        hps2core.vpadAxis(VpadAxis.RIGHTX, ax);
        hps2core.vpadAxis(VpadAxis.RIGHTY, ay);
      }
    })
  }

  /** 十字键（以 (cx,cy) 为中心） */
  @Builder
  dpad(cx: number, cy: number) {
    this.padButton('▲', VpadButton.DPAD_UP, cx, cy - this.btn - this.gap)
    this.padButton('▼', VpadButton.DPAD_DOWN, cx, cy + this.btn + this.gap)
    this.padButton('◀', VpadButton.DPAD_LEFT, cx - this.btn - this.gap, cy)
    this.padButton('▶', VpadButton.DPAD_RIGHT, cx + this.btn + this.gap, cy)
  }

  /** 四键（△上 ○右 ×下 □左，按 PS2 实际布局） */
  @Builder
  face(cx: number, cy: number) {
    this.padButton('△', VpadButton.NORTH, cx, cy - this.btn - this.gap)
    this.padButton('×', VpadButton.SOUTH, cx, cy + this.btn + this.gap)
    this.padButton('□', VpadButton.WEST, cx - this.btn - this.gap, cy)
    this.padButton('○', VpadButton.EAST, cx + this.btn + this.gap, cy)
  }

  build() {
    Stack() {
      // ---- 肩键与扳机 ----
      // 全部绝对定位，不放进 Row —— 用 Row 会让绝对定位子元素又受 flex
      // 约束，等于把刚消除的问题引回来。
      // 左侧：L1 / L2 并排，整体以 leftX 为中心；右侧同理。
      this.bar('L1', VpadButton.LEFT_SHOULDER, false,
        this.leftX - (this.barW + this.gap) / 2, this.barY)
      this.bar('L2', VpadAxis.LEFT_TRIGGER, true,
        this.leftX + (this.barW + this.gap) / 2, this.barY)
      this.bar('R2', VpadAxis.RIGHT_TRIGGER, true,
        this.rightX - (this.barW + this.gap) / 2, this.barY)
      this.bar('R1', VpadButton.RIGHT_SHOULDER, false,
        this.rightX + (this.barW + this.gap) / 2, this.barY)

      // ---- 十字键 ----
      this.dpad(this.leftX, this.midY)

      // ---- 四键 ----
      this.face(this.rightX, this.midY)

      // ---- 双摇杆 ----
      this.stick(true, this.leftX, this.stickY)
      this.stick(false, this.rightX, this.stickY)
    }
    .width('100%')
    .height('100%')
  }
}
