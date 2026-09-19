/*
 * Hps2 — 屏幕虚拟手柄
 *
 * 【配色】本组件颜色**刻意不跟随日夜主题**，一律用半透明白。
 * 原因：按键叠加在**游戏画面**上，画面内容不可预知（可能雪白也可能漆黑）。
 * 半透明白 + 描边在两种极端下都能看清；若跟随 UI 主题，
 * 浅色模式下会出现"白按键压在亮画面上"而消失。
 *
 * 【布局】按屏幕方向分别布局 —— 这是从 PPSSPP 1.20 学到的经验：
 *   官方说明原文："以前只是简单把横屏界面压缩进竖屏，视觉与操作体验都差；
 *   现在触控按键布局与画面显示布局在横竖屏下分别独立设置。"
 *
 * 实测尺寸依据（本机 Pura X View，surface 440x674 vp）：
 *   竖屏：4:3 画面占高约 49%，上下黑边各约 172vp
 *         → 黑边够高，可把肩键放上黑边、其余按键叠在画面下半部（半透明）
 *   横屏（674x440）：4:3 画面占宽约 87%，左右黑边各约 44vp
 *         → 黑边太窄放不下整套按键，按键叠在画面两侧（半透明）
 *
 * 为什么不用固定像素尺寸：固定尺寸会在窄屏 / 横屏下溢出。
 * 早先的版本用固定 132vp 摇杆 + 38vp 按钮，合计需求 480vp > 可用 440vp，
 * 导致 ArkUI 压缩子元素、全部挤在一起（用户反馈的「挤在一堆」）。
 * 现改用**相对比例**（百分比宽度）保证任何屏幕都不溢出。
 */
import hps2core from 'libhps2core.so';
import { VpadButton, VpadAxis } from '../common/VpadCodes';

@Component
export struct VirtualPad {
  /** 是否横屏（由父组件通过 onAreaChange 传入） */
  @Prop landscape: boolean = false;

  // 摇杆显示状态
  @State lsx: number = 0;
  @State lsy: number = 0;
  @State rsx: number = 0;
  @State rsy: number = 0;

  // 摇杆可动半径与拖拽范围（用比例控制，避免溢出）
  private get stickR(): number { return this.landscape ? 34 : 40; }
  private get stickBox(): number { return this.landscape ? 88 : 104; }

  /** 按键边长 */
  private get btn(): number { return this.landscape ? 34 : 40; }

  @Builder
  padButton(label: string, code: number) {
    Text(label)
      .fontSize(this.landscape ? 13 : 15)
      .fontColor('#FFFFFF')
      .textAlign(TextAlign.Center)
      .width(this.btn)
      .height(this.btn)
      .borderRadius(this.btn / 2)
      .backgroundColor('#40FFFFFF')
      .border({ width: 1, color: '#80FFFFFF' })
      .onTouch((e: TouchEvent) => {
        if (e.type === TouchType.Down) {
          hps2core.vpadButton(code, true);
        } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
          hps2core.vpadButton(code, false);
        }
      })
  }

  @Builder
  bar(label: string, code: number, isTrigger: boolean) {
    Text(label)
      .fontSize(12)
      .fontColor('#FFFFFF')
      .textAlign(TextAlign.Center)
      .width(this.landscape ? 44 : 52)
      .height(26)
      .borderRadius(6)
      .backgroundColor('#40FFFFFF')
      .border({ width: 1, color: '#80FFFFFF' })
      .onTouch((e: TouchEvent) => {
        const down = (e.type === TouchType.Down);
        const up = (e.type === TouchType.Up || e.type === TouchType.Cancel);
        if (isTrigger) {
          // L2/R2 在 PCSX2 里是**轴**，按下给满量程、抬起归零
          if (down) { hps2core.vpadAxis(code, 32767); }
          else if (up) { hps2core.vpadAxis(code, 0); }
        } else {
          if (down) { hps2core.vpadButton(code, true); }
          else if (up) { hps2core.vpadButton(code, false); }
        }
      })
  }

  @Builder
  stick(isLeft: boolean) {
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
      const cx = this.stickBox / 2;
      let dx = t.x - cx;
      let dy = t.y - cx;

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

  /** 十字键（3x3 网格，中间留空） */
  @Builder
  dpad() {
    Column({ space: 2 }) {
      this.padButton('▲', VpadButton.DPAD_UP)
      Row({ space: 2 }) {
        this.padButton('◀', VpadButton.DPAD_LEFT)
        // 用等宽占位保持左右对齐
        Text('').width(this.btn).height(this.btn)
        this.padButton('▶', VpadButton.DPAD_RIGHT)
      }
      this.padButton('▼', VpadButton.DPAD_DOWN)
    }
  }

  /** 四键（△ ○ × □ 按 PS2 实际布局） */
  @Builder
  faceButtons() {
    Column({ space: 2 }) {
      this.padButton('△', VpadButton.NORTH)
      Row({ space: 2 }) {
        this.padButton('□', VpadButton.WEST)
        Text('').width(this.btn).height(this.btn)
        this.padButton('○', VpadButton.EAST)
      }
      this.padButton('×', VpadButton.SOUTH)
    }
  }

  /** 肩键条（L1 L2 ... R2 R1） */
  @Builder
  shoulderRow() {
    Row() {
      this.bar('L1', VpadButton.LEFT_SHOULDER, false)
      Blank().width(6)
      this.bar('L2', VpadAxis.LEFT_TRIGGER, true)

      Blank().layoutWeight(1)

      this.bar('R2', VpadAxis.RIGHT_TRIGGER, true)
      Blank().width(6)
      this.bar('R1', VpadButton.RIGHT_SHOULDER, false)
    }
    .width('100%')
  }

  build() {
    Stack() {
      if (this.landscape) {
        // ============ 横屏布局 ============
        // 左右两侧各占 30% 宽，中间 40% 留空不遮挡画面。
        // 每侧内容 = 肩键 + 十字键/四键 + 摇杆，纵向排列。
        Row() {
          // ---- 左侧 ----
          Column({ space: 6 }) {
            Row({ space: 6 }) {
              this.bar('L1', VpadButton.LEFT_SHOULDER, false)
              this.bar('L2', VpadAxis.LEFT_TRIGGER, true)
            }
            this.dpad()
            this.stick(true)
          }
          .width('30%')
          .alignItems(HorizontalAlign.Center)
          .justifyContent(FlexAlign.Center)

          // 中间留空：不遮挡游戏画面
          Blank().layoutWeight(1)

          // ---- 右侧 ----
          Column({ space: 6 }) {
            Row({ space: 6 }) {
              this.bar('R2', VpadAxis.RIGHT_TRIGGER, true)
              this.bar('R1', VpadButton.RIGHT_SHOULDER, false)
            }
            this.faceButtons()
            this.stick(false)
          }
          .width('30%')
          .alignItems(HorizontalAlign.Center)
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .height('100%')
        .padding({ left: 6, right: 6, top: 6, bottom: 6 })
      } else {
        // ============ 竖屏布局 ============
        // 上方 38% 留给肩键与十字键/四键（多数叠在黑边），
        // 下方 62% 放摇杆（叠在画面上，半透明）。
        Column() {
          // 顶部：肩键
          this.shoulderRow()

          Blank().height(8)

          // 中部：左十字键 / 右四键
          Row() {
            this.dpad()
            Blank().layoutWeight(1)
            this.faceButtons()
          }
          .width('100%')
          .padding({ left: 10, right: 10 })

          Blank().layoutWeight(1)

          // 底部：双摇杆
          Row() {
            this.stick(true)
            Blank().layoutWeight(1)
            this.stick(false)
          }
          .width('100%')
          .padding({ left: 10, right: 10 })
        }
        .width('100%')
        .height('100%')
        .padding({ top: 8, bottom: 12 })
      }
    }
    .width('100%')
    .height('100%')
  }
}
