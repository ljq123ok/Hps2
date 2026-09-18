/*
 * Hps2 — 屏幕虚拟手柄
 *
 * 布局（PS2 手柄）：
 *   顶部：L1 L2 ..................... R2 R1
 *   底部：十字键 · 左摇杆 ... 右摇杆 · △○×□
 *
 * 触控经 hps2core.vpadButton()/vpadAxis() 送入 native，由 SDL 虚拟手柄承载，
 * 最终进入 PCSX2 的 Pad —— 与真实手柄走同一条路径
 * （PCSX2 的 SDL 通用映射表见 SDLInputSource.cpp:510-524）。
 *
 * 关键点：按下与抬起都必须上报，否则按键会卡在按下状态。
 */
import hps2core from 'libhps2core.so';
import { VpadButton, VpadAxis } from '../common/VpadCodes';

@Component
export struct VirtualPad {
  private readonly stickR: number = 44;   // 摇杆可动半径
  private readonly stickBox: number = 132; // 摇杆外框边长
  private readonly btn: number = 38;

  @State lsx: number = 0;
  @State lsy: number = 0;
  @State rsx: number = 0;
  @State rsy: number = 0;

  @Builder
  padButton(label: string, code: number) {
    Text(label)
      .fontSize(14)
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
      .width(50)
      .height(26)
      .borderRadius(6)
      .backgroundColor('#40FFFFFF')
      .border({ width: 1, color: '#80FFFFFF' })
      .onTouch((e: TouchEvent) => {
        const down = (e.type === TouchType.Down);
        const up = (e.type === TouchType.Up || e.type === TouchType.Cancel);
        if (isTrigger) {
          // L2/R2 是轴：按下给满量程，抬起归零
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

  build() {
    Stack() {
      // 顶部肩键与扳机
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
      .padding({ left: 8, right: 8 })
      .align(Alignment.Top)

      // 底部：十字键 / 双摇杆 / 四键
      Row({ space: 10 }) {
        // 注意：@Builder 方法返回 void，不能在调用处链式 .margin()。
        // 间距一律由外层容器负责（Column/Row 的 space 或包裹容器）。
        Column({ space: 4 }) {
          this.padButton('▲', VpadButton.DPAD_UP)
          Row({ space: 4 }) {
            this.padButton('◀', VpadButton.DPAD_LEFT)
            this.padButton('▶', VpadButton.DPAD_RIGHT)
          }
          this.padButton('▼', VpadButton.DPAD_DOWN)
        }

        this.stick(true)

        Blank().layoutWeight(1)

        this.stick(false)

        Column({ space: 4 }) {
          this.padButton('△', VpadButton.NORTH)
          Row({ space: 4 }) {
            this.padButton('□', VpadButton.WEST)
            this.padButton('○', VpadButton.EAST)
          }
          this.padButton('×', VpadButton.SOUTH)
        }
      }
      .width('100%')
      .padding({ left: 8, right: 8 })
      .align(Alignment.Bottom)

    }
    .width('100%')
    .height('100%')
  }
}
