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

  /**
   * The parent surface can resize after this component is created (entering
   * immersive mode and rotating are both real examples).  ArkUI may keep the
   * initial @Prop snapshot for a custom component, so use the overlay's own
   * measured size as the authoritative value once it is available.
   */
  @State measuredW: number = 0;
  @State measuredH: number = 0;

  private static diagW: number = 0;
  private static diagH: number = 0;
  private static diagLandscape: boolean = false;

  @State lsx: number = 0;
  @State lsy: number = 0;
  @State rsx: number = 0;
  @State rsy: number = 0;

  // Keep each stick attached to the finger that started it.  Using
  // touches[0] loses as soon as another finger is down (for example while
  // holding a face button), and can make the stick appear to point in one
  // constant direction.
  private leftTouchId: number = -1;
  private rightTouchId: number = -1;

  private layoutW(): number {
    return this.measuredW > 0 ? this.measuredW : this.vpW;
  }

  private layoutH(): number {
    return this.measuredH > 0 ? this.measuredH : this.vpH;
  }

  // ---- 尺寸（vp，按屏幕大小自适应但有上下限，避免极小或极大屏上失调）----
  private btn(): number {
    const base = this.isPortraitFit() ? this.layoutW() * 0.095 : this.layoutH() * 0.085;
    return Math.max(30, Math.min(52, base));
  }
  private stickR(): number {
    const base = this.isPortraitFit() ? this.layoutW() * 0.19 : this.layoutH() * 0.15;
    return Math.max(26, Math.min(46, base));
  }
  private stickBox(): number { return this.stickR() * 2.4; }
  private barW(): number { return this.btn() * 1.5; }
  private barH(): number { return Math.max(24, this.btn() * 0.62); }
  private gap(): number { return Math.max(4, this.btn() * 0.12); }

  /**
   * The face/d-pad and shoulder groups need a little more inset than a
   * joystick.  Their outer edges are wider than their center point, so using
   * the joystick center for all three groups clips the outer buttons on a
   * portrait surface (for 440x674 the old L1/R1 edges were -8/448).
   */
  private controlInset(): number {
    const dpadHalf = this.btn() * 1.5 + this.gap();
    const shoulderHalf = this.barW() + this.gap() / 2;
    return Math.max(dpadHalf, shoulderHalf) + this.gap();
  }

  // ---- 画面区域与黑边（关键）----
  //
  // 【为什么要算这个】此前按键中心固定在 屏宽×0.22 / 屏高×0.40 等比例位置上，
  // 真机上表现为"位置不对" —— 实测核算发现：
  //   竖屏 440x674 时 4:3 画面占 y=172~502，而十字键中心在 y=270，
  //   **正压在游戏主体上**，遮挡内容。
  //
  // 正确做法：把按键放进**黑边**（4:3 画面之外的空间）。
  //   竖屏：上黑边 172vp、下黑边 172vp —— 空间充足
  //   横屏：左右黑边各仅 79vp —— 放不下整套按键，只能叠在画面两侧
  // 故两种方向分别处理。

  /** 画面是否按宽度铺满（竖屏）；否则按高度铺满（横屏） */
  private isPortraitFit(): boolean { return this.layoutH() >= this.layoutW(); }

  /** 4:3 画面在本组件内的实际矩形（vp） */
  private contentTop(): number {
    if (this.isPortraitFit()) {
      return (this.layoutH() - this.layoutW() * 0.75) / 2;
    }
    return 0;
  }
  private contentBottom(): number {
    if (this.isPortraitFit()) {
      return this.layoutH() - this.contentTop();
    }
    return this.layoutH();
  }

  // ---- 坐标计算 ----
  /** 顶部肩键条的 y（放在上黑边内，或横屏时贴顶） */
  private barY(): number {
    // 竖屏：上黑边中点；横屏：贴顶（黑边太窄，只能叠在画面上）
    return this.isPortraitFit() ? (this.contentTop() / 2 + 6) : (this.gap() + 8);
  }

  /** 十字键/四键区的中心 y */
  private midY(): number {
    if (this.isPortraitFit()) {
      // 竖屏：放下黑边。
      // 下黑边仅约 172vp，而十字键列高约 125vp、摇杆外框约 110vp ——
      // 两组放不下（实测核算会重叠 37vp）。因此把十字键/四键放黑边，
      // 摇杆另择位置（见 stickY）。
      const bandH = this.layoutH() - this.contentBottom();
      return this.contentBottom() + bandH / 2;
    }
    // 横屏：画面高度中部
    return this.layoutH() * 0.50;
  }

  /** 摇杆中心 y */
  private stickY(): number {
    if (this.isPortraitFit()) {
      // 竖屏：十字键已占用下黑边，摇杆放在**画面下缘内部**（半透明叠加）。
      // 取画面底部往上约一个外框处，尽量少遮挡主体（4:3 游戏的主体多在中部）。
      return this.contentBottom() - this.stickBox() / 2 + 6;
    }
    // 横屏：叠在画面两侧的下方
    return this.layoutH() * 0.80;
  }

  /** Control-group centers; kept separate from the joystick centers. */
  private controlLeftX(): number {
    if (this.isPortraitFit()) {
      return Math.max(this.controlInset(), this.layoutW() * 0.16);
    }
    return Math.max(this.controlInset(), this.layoutW() * 0.11);
  }

  private controlRightX(): number {
    return this.layoutW() - this.controlLeftX();
  }

  /** Joysticks can sit closer to the side edge because they are one object. */
  private stickLeftX(): number {
    return Math.max(this.stickBox() / 2 + this.gap(), this.layoutW() * 0.11);
  }

  private stickRightX(): number {
    return this.layoutW() - this.stickLeftX();
  }

  /** Centered system buttons that were missing from the old virtual pad. */
  private systemY(): number {
    if (this.isPortraitFit()) {
      const bandH = this.layoutH() - this.contentBottom();
      return this.contentBottom() + bandH * 0.82;
    }
    return this.layoutH() - this.barH() / 2 - this.gap() - 6;
  }

  /** 把中心点换成左上角坐标 */
  private left(cx: number, w: number): number { return cx - w / 2; }
  private top(cy: number, h: number): number { return cy - h / 2; }

  // ================= 控件 =================

  @Builder
  padButton(label: string, code: number, cx: number, cy: number) {
    Text(label)
      .fontSize(this.btn() * 0.42)
      .fontColor('#FFFFFF')
      .textAlign(TextAlign.Center)
      .width(this.btn())
      .height(this.btn())
      .borderRadius(this.btn() / 2)
      .backgroundColor('#40FFFFFF')
      .border({ width: 1, color: '#80FFFFFF' })
      .position({ x: this.left(cx, this.btn()), y: this.top(cy, this.btn()) })
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
      .fontSize(this.barH() * 0.44)
      .fontColor('#FFFFFF')
      .textAlign(TextAlign.Center)
      .width(this.barW())
      .height(this.barH())
      .borderRadius(6)
      .backgroundColor('#40FFFFFF')
      .border({ width: 1, color: '#80FFFFFF' })
      .position({ x: this.left(cx, this.barW()), y: this.top(cy, this.barH()) })
      .onTouch((e: TouchEvent) => {
        const down = (e.type === TouchType.Down);
        const up = (e.type === TouchType.Up || e.type === TouchType.Cancel);
        if (isTrigger) {
          // L2/R2 在 PCSX2 里是**轴**：按下给满量程、抬起回到 SDL 轴底值
          if (down) { hps2core.vpadAxis(code, 32767); }
          else if (up) { hps2core.vpadAxis(code, VpadAxis.TRIGGER_REST); }
        } else {
          if (down) { hps2core.vpadButton(code, true); }
          else if (up) { hps2core.vpadButton(code, false); }
        }
      })
  }

  @Builder
  systemButton(label: string, code: number, cx: number, cy: number) {
    Text(label)
      .fontSize(this.barH() * 0.38)
      .fontColor('#FFFFFF')
      .textAlign(TextAlign.Center)
      .width(this.barW())
      .height(this.barH())
      .borderRadius(6)
      .backgroundColor('#40FFFFFF')
      .border({ width: 1, color: '#80FFFFFF' })
      .position({ x: this.left(cx, this.barW()), y: this.top(cy, this.barH()) })
      .onTouch((e: TouchEvent) => {
        if (e.type === TouchType.Down) {
          hps2core.vpadButton(code, true);
        } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
          hps2core.vpadButton(code, false);
        }
      })
  }

  @Builder
  stick(isLeft: boolean, cx: number, cy: number) {
    Stack() {
      Circle()
        .width(this.stickBox())
        .height(this.stickBox())
        .fill('#18FFFFFF')
        .stroke('#60FFFFFF')
        .strokeWidth(1)
      Circle()
        .width(this.stickR())
        .height(this.stickR())
        .fill('#66FFFFFF')
        .offset({
          x: isLeft ? this.lsx : this.rsx,
          y: isLeft ? this.lsy : this.rsy
        })
    }
    .width(this.stickBox())
    .height(this.stickBox())
    .position({ x: this.left(cx, this.stickBox()), y: this.top(cy, this.stickBox()) })
    .onTouch((e: TouchEvent) => {
      e.stopPropagation();
      if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        const activeId = isLeft ? this.leftTouchId : this.rightTouchId;
        const endedId = e.changedTouches.length > 0 ? e.changedTouches[0].id : activeId;
        if (activeId >= 0 && endedId !== activeId) {
          return;
        }
        // 回中：轴值必须归零，否则摇杆卡在最后位置
        if (isLeft) {
          this.lsx = 0; this.lsy = 0;
          this.leftTouchId = -1;
          hps2core.vpadAxis(VpadAxis.LEFTX, 0);
          hps2core.vpadAxis(VpadAxis.LEFTY, 0);
        } else {
          this.rsx = 0; this.rsy = 0;
          this.rightTouchId = -1;
          hps2core.vpadAxis(VpadAxis.RIGHTX, 0);
          hps2core.vpadAxis(VpadAxis.RIGHTY, 0);
        }
        return;
      }

      // Use the finger which changed in this event, then keep following its
      // id on Move.  This avoids reading another finger from touches[0].
      let t = e.changedTouches.length > 0 ? e.changedTouches[0] : e.touches[0];
      if (e.type === TouchType.Down && t) {
        if (isLeft) {
          this.leftTouchId = t.id;
        } else {
          this.rightTouchId = t.id;
        }
      } else {
        const activeId = isLeft ? this.leftTouchId : this.rightTouchId;
        for (let i = 0; i < e.touches.length; i++) {
          if (e.touches[i].id === activeId) {
            t = e.touches[i];
            break;
          }
        }
      }
      if (!t) {
        return;
      }

      const box = this.stickBox();
      const c = box / 2;
      let localX = t.x;
      let localY = t.y;

      // x/y should be local to the event component.  On some absolute
      // positioned ArkUI trees they arrive in window/pixel coordinates
      // instead.  Detect that case and convert from the known stick origin.
      if (localX < -box || localX > box * 2 || localY < -box || localY > box * 2) {
        localX = t.windowX - this.left(cx, box);
        localY = t.windowY - this.top(cy, box);
      }

      let dx = localX - c;
      let dy = localY - c;

      const dist = Math.sqrt(dx * dx + dy * dy);
      if (dist > this.stickR()) {
        dx = dx * this.stickR() / dist;
        dy = dy * this.stickR() / dist;
      }

      if (isLeft) {
        this.lsx = dx; this.lsy = dy;
      } else {
        this.rsx = dx; this.rsy = dy;
      }

      const ax = Math.round(dx / this.stickR() * 32767);
      const ay = Math.round(dy / this.stickR() * 32767);
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
    this.padButton('▲', VpadButton.DPAD_UP, cx, cy - this.btn() - this.gap())
    this.padButton('▼', VpadButton.DPAD_DOWN, cx, cy + this.btn() + this.gap())
    this.padButton('◀', VpadButton.DPAD_LEFT, cx - this.btn() - this.gap(), cy)
    this.padButton('▶', VpadButton.DPAD_RIGHT, cx + this.btn() + this.gap(), cy)
  }

  /** 四键（△上 ○右 ×下 □左，按 PS2 实际布局） */
  @Builder
  face(cx: number, cy: number) {
    this.padButton('△', VpadButton.NORTH, cx, cy - this.btn() - this.gap())
    this.padButton('×', VpadButton.SOUTH, cx, cy + this.btn() + this.gap())
    this.padButton('□', VpadButton.WEST, cx - this.btn() - this.gap(), cy)
    this.padButton('○', VpadButton.EAST, cx + this.btn() + this.gap(), cy)
  }

  /**
   * 尺寸/坐标发生变化时打印一次诊断（便于定位布局问题）。
   *
   * 【教训】此前的写法把诊断放在 aboutToAppear() 里并直接调用
   * this.btn() / this.midY() 等 getter —— 而那时父组件还没把 @Prop
   * vpW/vpH 传进来，getter 基于 undefined 计算，Diagnostic 本身
   * 抛了 TypeError：
   *   TypeError: Cannot read property toFixed of undefined
   * 导致**点击启动游戏即闪退**。
   * 教训：诊断代码必须晚于其依赖的数据就绪，且不得引入新的失败点。
   *
   * 现在改为在实测尺寸有效时才打印，并对每个值做数字兜底。
   */
  private logLayoutOnce(): void {
    const w = this.layoutW();
    const h = this.layoutH();
    const ls = !this.isPortraitFit();
    if (VirtualPad.diagW === w && VirtualPad.diagH === h &&
      VirtualPad.diagLandscape === ls)
      return;
    // 尺寸尚未就绪：静默等待下一次（不要在这里抛错）
    if (!(w > 0) || !(h > 0))
      return;

    VirtualPad.diagW = w;
    VirtualPad.diagH = h;
    VirtualPad.diagLandscape = ls;
    const f = (v: number): string => (Number.isFinite(v) ? v.toFixed(1) : 'n/a');
    console.info(`HPS2_VPAD_LAYOUT: vp=${w}x${h} ` +
      `landscape=${ls} btn=${f(this.btn())} ` +
      `midY=${f(this.midY())} stickY=${f(this.stickY())} ` +
      `controlLeftX=${f(this.controlLeftX())} controlRightX=${f(this.controlRightX())} ` +
      `stickLeftX=${f(this.stickLeftX())} stickRightX=${f(this.stickRightX())} ` +
      `systemY=${f(this.systemY())}`);
  }

  build() {
    Stack() {
      // ---- 肩键与扳机 ----
      // 全部绝对定位，不放进 Row —— 用 Row 会让绝对定位子元素又受 flex
      // 约束，等于把刚消除的问题引回来。
      // 左侧：L1 / L2 并排，整体以 leftX 为中心；右侧同理。
      this.bar('L1', VpadButton.LEFT_SHOULDER, false,
        this.controlLeftX() - (this.barW() + this.gap()) / 2, this.barY())
      this.bar('L2', VpadAxis.LEFT_TRIGGER, true,
        this.controlLeftX() + (this.barW() + this.gap()) / 2, this.barY())
      this.bar('R2', VpadAxis.RIGHT_TRIGGER, true,
        this.controlRightX() - (this.barW() + this.gap()) / 2, this.barY())
      this.bar('R1', VpadButton.RIGHT_SHOULDER, false,
        this.controlRightX() + (this.barW() + this.gap()) / 2, this.barY())

      // ---- 十字键 ----
      this.dpad(this.controlLeftX(), this.midY())

      // ---- 四键 ----
      this.face(this.controlRightX(), this.midY())

      // ---- Select / Start ----
      // These are separate SDL gamepad buttons (BACK/START), not labels on
      // the status bar.  Keep them in the center gap so they do not steal
      // touch space from the d-pad or face buttons.
      this.systemButton('SELECT', VpadButton.BACK,
        this.layoutW() / 2 - (this.barW() + this.gap()) / 2, this.systemY())
      this.systemButton('START', VpadButton.START,
        this.layoutW() / 2 + (this.barW() + this.gap()) / 2, this.systemY())

      // ---- 双摇杆 ----
      this.stick(true, this.stickLeftX(), this.stickY())
      this.stick(false, this.stickRightX(), this.stickY())
    }
    // Fill the current game surface and measure it locally.  This is
    // deliberate: the parent can rotate/resize after the child is mounted,
    // and the measured size must replace the initial prop snapshot.
    .width('100%')
    .height('100%')
    // 用 onAppear 而非在 build() 内直接调用：
    // onAppear 在组件挂载后触发，此时 @Prop 已由父组件赋值，
    // getter 依赖的数据必然就绪；也不再受 build() 的语句限制。
    .onAppear(() => { this.logLayoutOnce(); })
    .onAreaChange((_, area) => {
      const w = Number(area.width);
      const h = Number(area.height);
      if (w > 0 && h > 0 && (w !== this.measuredW || h !== this.measuredH)) {
        this.measuredW = w;
        this.measuredH = h;
        this.logLayoutOnce();
      }
    })
  }
}
