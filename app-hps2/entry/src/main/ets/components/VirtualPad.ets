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
import {
  PadGroup, PadLayoutVariant, PadOffsetEntry, PadStyle,
  PAD_STYLES, clampStyleIndex, SharedPadLayout, faceColorOf
} from '../common/PadLayout';

/**
 * @Builder 的单一对象参数。
 *
 * ArkUI 的按引用传参要求调用处直接传对象字面量；不要在调用处追加
 * `as XxxSpec`。动态偏移不放进参数，而由私有 Builder 通过 `this`
 * 读取组件自己的 @State，保证拖动后的状态变化能更新节点属性。
 */
interface BtnSpec {
  g: PadGroup;
  label: string;
  code: number;
  cx: number;
  cy: number;
}

interface BarSpec {
  g: PadGroup;
  label: string;
  code: number;
  isTrigger: boolean;
  cx: number;
  cy: number;
}

interface StickSpec {
  g: PadGroup;
  isLeft: boolean;
  cx: number;
  cy: number;
}

interface CenterSpec {
  cx: number;
  cy: number;
}

interface FrameSpec {
  g: PadGroup;
  x: number;
  y: number;
  w: number;
  h: number;
}

@Component
export struct VirtualPad {
  /** 是否横屏 */
  @Prop landscape: boolean = false;
  /** XComponent 实测宽度（vp） */
  @Prop vpW: number = 440;
  /** XComponent 实测高度（vp） */
  @Prop vpH: number = 674;

  /**
   * 编辑布局模式。
   *
   * 编辑态下：控件组显示虚线选框、可整体拖动，且**屏蔽游戏输入** ——
   * 若仍向 native 送按键，用户拖动时会误触游戏（例如拖摇杆时角色乱走）。
   * 因此编辑态只做布局，不发 vpad 事件。
   */
  @Prop editMode: boolean = false;
  /**
   * 外部布局变更信号。拖动中的即时反馈由本地 offsets 驱动；恢复默认、
   * 取消编辑等离散操作通过这个全局版本号重新装载共享布局。
   */
  @StorageLink('hps2_pad_layout_version')
  @Watch('onLayoutVersionChanged') layoutVersion: number = 0;

  /**
   * 本地可观察偏移。拖动只在这里累加一次以驱动画面，同时把同一增量
   * 上报父组件持久化；子组件绝不预写共享 store，避免重复累加。
   */
  @State offsets: Array<PadOffsetEntry> = [];
  /** 配色索引（对应 PAD_STYLES）*/
  @Prop styleIndex: number = 0;
  /**
   * 拖动某组：上报**归一化位移**（已按屏宽/屏高换算），
   * 由父组件累加进它自己持有的布局对象并持久化。
   */
  onGroupDragged?: (group: PadGroup, dxNorm: number, dyNorm: number) => void;
  /** 拖动结束（父组件据此落盘一次）*/
  onGroupDragEnd?: () => void;

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

  // 编辑态拖动状态：只允许同一个手指拖动同一组
  private editingGroup: PadGroup | null = null;
  private editTouchId: number = -1;
  private lastEditX: number = 0;
  private lastEditY: number = 0;

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

  // ================= 用户自定义布局 =================

  /** 当前共享布局；layoutVersion 的读取让透明度等离散变更可刷新。 */
  private currentVariant(): PadLayoutVariant {
    // 读取 @StorageLink 变量以建立依赖（勿删；这不是"空操作"）
    const ver = this.layoutVersion;
    if (ver < 0) {
      // 不可达分支，仅为让编译器保留上面的读取
      console.info('unreachable');
    }
    return SharedPadLayout.variantFor(this.layoutW() > this.layoutH());
  }

  /** 从本地 @State 取某组偏移（本组件自持，渲染直接依赖它）*/
  private localOffset(g: PadGroup): number[] {
    const key = g as string;
    for (let i = 0; i < this.offsets.length; i++) {
      const e = this.offsets[i];
      if (e.group === key) {
        return [e.dx, e.dy];
      }
    }
    return [0, 0];
  }

  /** 首次挂载时从共享单例读入布局到本地 @State*/
  private loadLocalFromStore(): void {
    const v = SharedPadLayout.variantFor(this.layoutW() > this.layoutH());
    const copy: Array<PadOffsetEntry> = [];
    for (let i = 0; i < v.offsets.length; i++) {
      const e = v.offsets[i];
      copy.push({ group: e.group, dx: e.dx, dy: e.dy });
    }
    this.offsets = copy;
    console.info(`HPS2_VPAD_LOAD: groups=${copy.length} ` +
      `landscape=${this.layoutW() > this.layoutH()}`);
  }

  /**
   * 父组件完成离散操作（恢复默认、切换方向）后，同步本地渲染状态。
   * 拖动期间由本组件自己的 @State 负责即时反馈，避免每个 Move 都重复装载。
   */
  private onLayoutVersionChanged(): void {
    if (this.editingGroup === null) {
      this.loadLocalFromStore();
    }
  }

  /** 在本地列表中累加某组偏移（写新数组 → 必然重绘）*/
  private applyLocalDelta(g: PadGroup, dx: number, dy: number): void {
    const key = g as string;
    const next: Array<PadOffsetEntry> = [];
    let found = false;
    for (let i = 0; i < this.offsets.length; i++) {
      const e = this.offsets[i];
      if (e.group === key) {
        found = true;
        // 与 PadLayout.setOffset 相同的钳制（±30%），避免拖出屏幕
        const nx = Math.max(-0.30, Math.min(0.30, e.dx + dx));
        const ny = Math.max(-0.30, Math.min(0.30, e.dy + dy));
        next.push({ group: key, dx: nx, dy: ny });
      } else {
        next.push({ group: e.group, dx: e.dx, dy: e.dy });
      }
    }
    if (!found) {
      next.push({ group: key,
        dx: Math.max(-0.30, Math.min(0.30, dx)),
        dy: Math.max(-0.30, Math.min(0.30, dy)) });
    }
    this.offsets = next;          // ← 组件写自身 @State：必定重绘
  }

  /** 当前配色的基色 */
  private style(): PadStyle {
    return PAD_STYLES[clampStyleIndex(this.styleIndex)];
  }

  // ---- 面键四色（设计稿 v2）----
  // △○×□ 四键在 faceColors 模式下用 PS2 品牌色；其余键走基色。

  /** 该键的面键品牌色；非面键或未开启四色模式时返回 null */
  private faceColor(code: number): string | null {
    if (!this.style().faceColors) {
      return null;
    }
    if (code === VpadButton.NORTH) { return faceColorOf('NORTH'); }
    if (code === VpadButton.EAST) { return faceColorOf('EAST'); }
    if (code === VpadButton.SOUTH) { return faceColorOf('SOUTH'); }
    if (code === VpadButton.WEST) { return faceColorOf('WEST'); }
    return null;
  }

  private faceFg(code: number): string {
    const c = this.faceColor(code);
    return c ? c : this.style().fg;
  }

  private faceBg(code: number): string {
    const c = this.faceColor(code);
    // 面键：深色底 + 品牌色描边，叠在游戏画面上对比度稳定
    return c ? '#8C0A0E17' : this.style().bg;
  }

  private faceBd(code: number): string {
    const c = this.faceColor(code);
    return c ? c : this.style().border;
  }

  private faceBw(code: number): number {
    return this.faceColor(code) ? 1.5 : 1;
  }

  /**
   * 按键不透明度。
   *
   * 配色本身已含 alpha（如 #40FFFFFF），这里再乘一次用户比例 ——
   * 设计稿的 "Button opacity" 是**独立于配色**的总透明度，
   * 故不能只改配色的 alpha（那样换配色会覆盖用户设定）。
   */
  private op(): number {
    const o = this.currentVariant().opacity;
    if (!Number.isFinite(o)) {
      return 0.6;
    }
    return Math.max(0.15, Math.min(1.0, o));
  }

  /** 某组在 x 方向的像素偏移（归一化值 × 屏宽）*/
  private offX(g: PadGroup): number {
    const dx = this.localOffset(g)[0];
    // 【不节流、不去重】渲染坐标日志。
    // 上两轮的诊断（%8 节流 / group:dx 去重）无法证明组件是否重绘，
    // 这一版保留原始输出以便与 SYNC 对照。
    console.info(`HPS2_PAD_RENDER: group=${g} dx=${dx.toFixed(4)} ` +
      `ver=${this.layoutVersion}`);
    return dx * this.layoutW();
  }

  /** 某组在 y 方向的像素偏移（归一化值 × 屏高）*/
  private offY(g: PadGroup): number {
    const o = this.localOffset(g);
    return o[1] * this.layoutH();
  }

  /** 把触摸像素位移换成 vp 归一化位移，更新本地画面并上报持久化。 */
  private dragGroup(g: PadGroup, dxPx: number, dyPx: number): void {
    const w = this.layoutW();
    const h = this.layoutH();
    if (!(w > 0) || !(h > 0)) { return; }
    // 诊断：累计拖动量，每累计约 20vp 打一条日志。
    // 目的：区分"事件没到达"与"到达了但换算错"—— 这是本次
    // 真机问题（用户反馈"拖不动"）唯一能一次判定的手段。
    // -------------------------------------------------------------------
    // 【单位：windowX/windowY 是 vp，不要再除 density】
    //
    // 官方《触摸事件》TouchObject 属性表明确写：
    //   x / y / windowX / windowY / displayX / displayY —— 单位 **vp**
    //
    // 这里曾经把 dxPx 当成 px 又除以 density(2.75)，等于多缩了一次。
    // 真机实测（两次，线性一致）：
    //   手指横移 300px → 虚线框只走 107px（35.7%）
    //   手指横移 400px → 虚线框只走 143px（35.8%）
    //   1/2.75 = 36.4% —— 正是多除的这一刀。
    //
    // 旁证：同文件摇杆路径（onTouch 里 localX = t.windowX - left() - offX()）
    // 一直把 windowX 与 vp 量直接相减、从未除 density，那条是对的。
    //
    // 本函数收到的 dxPx/dyPx 已经是 vp 增量，直接按 vp 归一化即可。
    // （形参名保留 dxPx 以兼容调用点，实际单位为 vp。）
    // -------------------------------------------------------------------
    const dxVp = dxPx;
    const dyVp = dyPx;
    const nx = dxVp / w;
    const ny = dyVp / h;

    this.diagDragAccum += Math.abs(dxVp) + Math.abs(dyVp);
    if (this.diagDragAccum >= 20) {
      this.diagDragAccum = 0;
      console.info(`HPS2_DRAG: group=${g} vp=(${dxVp.toFixed(2)},${dyVp.toFixed(2)}) ` +
        `norm=(${nx.toFixed(4)},${ny.toFixed(4)}) ` +
        `layout=${w.toFixed(1)}x${h.toFixed(1)}`);
    }
    // 1) 先更新本地状态 —— 渲染立即反映，不依赖任何跨组件传播
    this.applyLocalDelta(g, nx, ny);
    // 2) 通知父组件把同一份增量写入共享 store。
    // 不在这里预写 store：父回调会累加一次；若两边都写会把持久化位移翻倍。
    if (this.onGroupDragged) {
      this.onGroupDragged(g, nx, ny);
    }
  }

  private diagDragAccum: number = 0;

  /**
   * 编辑态的虚线选框（对齐设计稿：蓝色虚框 + 淡填充）。
   *
   * 选框是**独立于按键**的触摸层：编辑态下按键自身不再接收触摸，
   * 由选框统一处理拖动 —— 否则拖动会被按键的 onTouch 抢走。
   */
  @Builder
  editFrame(spec: FrameSpec) {
    Column()
      .width(spec.w)
      .height(spec.h)
      .borderRadius(4)
      .border({ width: 1.5, color: '#3A7EFF', style: BorderStyle.Dashed })
      .backgroundColor('#143A7EFF')
      // 偏移在 @Builder 内直接读取组件自身 @State。不能把动态坐标作为
      // 按值参数传进来，否则 Builder 首次构建后会冻结旧坐标。
      .position({ x: spec.x + this.offX(spec.g), y: spec.y + this.offY(spec.g) })
      .onTouch((e: TouchEvent) => {
        const changed = e.changedTouches.length > 0 ? e.changedTouches[0] : e.touches[0];
        if (e.type === TouchType.Down) {
          if (!changed) { return; }
          this.editTouchId = changed.id;
          this.lastEditX = changed.windowX;
          this.lastEditY = changed.windowY;
          this.editingGroup = spec.g;
        } else if (e.type === TouchType.Move) {
          if (this.editingGroup !== spec.g || !changed) { return; }
          // 同一手指才能拖：多点触控时避免跟随错手指
          if (this.editTouchId >= 0 && changed.id !== this.editTouchId) { return; }
          const dx = changed.windowX - this.lastEditX;
          const dy = changed.windowY - this.lastEditY;
          this.lastEditX = changed.windowX;
          this.lastEditY = changed.windowY;
          this.dragGroup(spec.g, dx, dy);
        } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
          if (this.editingGroup === spec.g) {
            this.editingGroup = null;
            this.editTouchId = -1;
            if (this.onGroupDragEnd) { this.onGroupDragEnd(); }
          }
        }
      })
  }

  // ================= 控件 =================

  @Builder
  padButton(spec: BtnSpec) {
    Text(spec.label)
      .fontSize(this.btn() * 0.42)
      .fontColor(this.faceFg(spec.code))
      .textAlign(TextAlign.Center)
      .width(this.btn())
      .height(this.btn())
      .borderRadius(this.btn() / 2)
      .backgroundColor(this.faceBg(spec.code))
      .border({ width: this.faceBw(spec.code), color: this.faceBd(spec.code) })
      .opacity(this.op())
      .position({
        x: this.left(spec.cx, this.btn()) + this.offX(spec.g),
        y: this.top(spec.cy, this.btn()) + this.offY(spec.g)
      })
      // 编辑态不接收触摸：交给上层的虚线选框处理拖动，
      // 否则拖动会被按键抢走，且会向游戏误发按键。
      .hitTestBehavior(this.editMode ? HitTestMode.None : HitTestMode.Default)
      .onTouch((e: TouchEvent) => {
        if (this.editMode) { return; }
        if (e.type === TouchType.Down) {
          hps2core.vpadButton(spec.code, true);
        } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
          hps2core.vpadButton(spec.code, false);
        }
      })
  }

  @Builder
  bar(spec: BarSpec) {
    Text(spec.label)
      .fontSize(this.barH() * 0.44)
      .fontColor(this.style().fg)
      .textAlign(TextAlign.Center)
      .width(this.barW())
      .height(this.barH())
      .borderRadius(6)
      .backgroundColor(this.style().bg)
      .border({ width: 1, color: this.style().border })
      .opacity(this.op())
      .position({
        x: this.left(spec.cx, this.barW()) + this.offX(spec.g),
        y: this.top(spec.cy, this.barH()) + this.offY(spec.g)
      })
      .hitTestBehavior(this.editMode ? HitTestMode.None : HitTestMode.Default)
      .onTouch((e: TouchEvent) => {
        if (this.editMode) { return; }
        const down = (e.type === TouchType.Down);
        const up = (e.type === TouchType.Up || e.type === TouchType.Cancel);
        if (spec.isTrigger) {
          // L2/R2 在 PCSX2 里是**轴**：按下给满量程、抬起回到 SDL 轴底值
          if (down) { hps2core.vpadAxis(spec.code, 32767); }
          else if (up) { hps2core.vpadAxis(spec.code, VpadAxis.TRIGGER_REST); }
        } else {
          if (down) { hps2core.vpadButton(spec.code, true); }
          else if (up) { hps2core.vpadButton(spec.code, false); }
        }
      })
  }

  @Builder
  systemButton(spec: BtnSpec) {
    Text(spec.label)
      .fontSize(this.barH() * 0.38)
      .fontColor(this.style().fg)
      .textAlign(TextAlign.Center)
      .width(this.barW())
      .height(this.barH())
      .borderRadius(6)
      .backgroundColor(this.style().bg)
      .border({ width: 1, color: this.style().border })
      .opacity(this.op())
      .position({
        x: this.left(spec.cx, this.barW()) + this.offX(spec.g),
        y: this.top(spec.cy, this.barH()) + this.offY(spec.g)
      })
      .hitTestBehavior(this.editMode ? HitTestMode.None : HitTestMode.Default)
      .onTouch((e: TouchEvent) => {
        if (this.editMode) { return; }
        if (e.type === TouchType.Down) {
          hps2core.vpadButton(spec.code, true);
        } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
          hps2core.vpadButton(spec.code, false);
        }
      })
  }

  @Builder
  stick(spec: StickSpec) {
    Stack() {
      Circle()
        .width(this.stickBox())
        .height(this.stickBox())
        .fill(this.style().bg)
        .stroke(this.style().border)
        .strokeWidth(1)
      Circle()
        .width(this.stickR())
        .height(this.stickR())
        .fill(this.style().border)
        .offset({
          x: spec.isLeft ? this.lsx : this.rsx,
          y: spec.isLeft ? this.lsy : this.rsy
        })
    }
    .width(this.stickBox())
    .height(this.stickBox())
    .position({
      x: this.left(spec.cx, this.stickBox()) + this.offX(spec.g),
      y: this.top(spec.cy, this.stickBox()) + this.offY(spec.g)
    })
    .opacity(this.op())
    .hitTestBehavior(this.editMode ? HitTestMode.None : HitTestMode.Default)
    .onTouch((e: TouchEvent) => {
      // 编辑态：不摇动、不发轴值 —— 由上层选框处理拖动
      if (this.editMode) { return; }
      e.stopPropagation();
      if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        const activeId = spec.isLeft ? this.leftTouchId : this.rightTouchId;
        const endedId = e.changedTouches.length > 0 ? e.changedTouches[0].id : activeId;
        if (activeId >= 0 && endedId !== activeId) {
          return;
        }
        // 回中：轴值必须归零，否则摇杆卡在最后位置
        if (spec.isLeft) {
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
        if (spec.isLeft) {
          this.leftTouchId = t.id;
        } else {
          this.rightTouchId = t.id;
        }
      } else {
        const activeId = spec.isLeft ? this.leftTouchId : this.rightTouchId;
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
        localX = t.windowX - this.left(spec.cx, box) - this.offX(spec.g);
        localY = t.windowY - this.top(spec.cy, box) - this.offY(spec.g);
      }

      let dx = localX - c;
      let dy = localY - c;

      const dist = Math.sqrt(dx * dx + dy * dy);
      if (dist > this.stickR()) {
        dx = dx * this.stickR() / dist;
        dy = dy * this.stickR() / dist;
      }

      if (spec.isLeft) {
        this.lsx = dx; this.lsy = dy;
      } else {
        this.rsx = dx; this.rsy = dy;
      }

      const ax = Math.round(dx / this.stickR() * 32767);
      const ay = Math.round(dy / this.stickR() * 32767);
      if (spec.isLeft) {
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
  dpad(spec: CenterSpec) {
    this.padButton({ g: PadGroup.DPAD, label: '▲', code: VpadButton.DPAD_UP,
      cx: spec.cx, cy: spec.cy - this.btn() - this.gap() })
    this.padButton({ g: PadGroup.DPAD, label: '▼', code: VpadButton.DPAD_DOWN,
      cx: spec.cx, cy: spec.cy + this.btn() + this.gap() })
    this.padButton({ g: PadGroup.DPAD, label: '◀', code: VpadButton.DPAD_LEFT,
      cx: spec.cx - this.btn() - this.gap(), cy: spec.cy })
    this.padButton({ g: PadGroup.DPAD, label: '▶', code: VpadButton.DPAD_RIGHT,
      cx: spec.cx + this.btn() + this.gap(), cy: spec.cy })
  }

  /** 四键（△上 ○右 ×下 □左，按 PS2 实际布局） */
  @Builder
  face(spec: CenterSpec) {
    this.padButton({ g: PadGroup.FACE, label: '△', code: VpadButton.NORTH,
      cx: spec.cx, cy: spec.cy - this.btn() - this.gap() })
    this.padButton({ g: PadGroup.FACE, label: '×', code: VpadButton.SOUTH,
      cx: spec.cx, cy: spec.cy + this.btn() + this.gap() })
    this.padButton({ g: PadGroup.FACE, label: '□', code: VpadButton.WEST,
      cx: spec.cx - this.btn() - this.gap(), cy: spec.cy })
    this.padButton({ g: PadGroup.FACE, label: '○', code: VpadButton.EAST,
      cx: spec.cx + this.btn() + this.gap(), cy: spec.cy })
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
  aboutToAppear(): void {
    console.info(`HPS2_VC_LIFE: VirtualPad created (editMode=${this.editMode}, ` +
      `ver=${this.layoutVersion})`);
  }

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
      // 用户偏移按组叠加（左右肩键是**两个**独立组，可分别摆放）。
      this.bar({ g: PadGroup.LEFT_SHOULDER, label: 'L1',
        code: VpadButton.LEFT_SHOULDER, isTrigger: false,
        cx: this.controlLeftX() - (this.barW() + this.gap()) / 2,
        cy: this.barY() })
      this.bar({ g: PadGroup.LEFT_SHOULDER, label: 'L2',
        code: VpadAxis.LEFT_TRIGGER, isTrigger: true,
        cx: this.controlLeftX() + (this.barW() + this.gap()) / 2,
        cy: this.barY() })
      this.bar({ g: PadGroup.RIGHT_SHOULDER, label: 'R2',
        code: VpadAxis.RIGHT_TRIGGER, isTrigger: true,
        cx: this.controlRightX() - (this.barW() + this.gap()) / 2,
        cy: this.barY() })
      this.bar({ g: PadGroup.RIGHT_SHOULDER, label: 'R1',
        code: VpadButton.RIGHT_SHOULDER, isTrigger: false,
        cx: this.controlRightX() + (this.barW() + this.gap()) / 2,
        cy: this.barY() })

      // ---- 十字键 ----
      // 动态偏移在 padButton 内部直接读取本组件 @State；
      // 这样不会把拖动坐标作为 @Builder 的按值参数冻结。
      this.padButton({ g: PadGroup.DPAD, label: '▲', code: VpadButton.DPAD_UP,
        cx: this.controlLeftX(), cy: this.midY() - this.btn() - this.gap() })
      this.padButton({ g: PadGroup.DPAD, label: '▼', code: VpadButton.DPAD_DOWN,
        cx: this.controlLeftX(), cy: this.midY() + this.btn() + this.gap() })
      this.padButton({ g: PadGroup.DPAD, label: '◀', code: VpadButton.DPAD_LEFT,
        cx: this.controlLeftX() - this.btn() - this.gap(), cy: this.midY() })
      this.padButton({ g: PadGroup.DPAD, label: '▶', code: VpadButton.DPAD_RIGHT,
        cx: this.controlLeftX() + this.btn() + this.gap(), cy: this.midY() })

      // ---- 四键 ----
      this.face({ cx: this.controlRightX(), cy: this.midY() })

      // ---- Select / Start ----
      // These are separate SDL gamepad buttons (BACK/START), not labels on
      // the status bar.  Keep them in the center gap so they do not steal
      // touch space from the d-pad or face buttons.
      this.systemButton({ g: PadGroup.SYSTEM, label: 'SELECT', code: VpadButton.BACK,
        cx: this.layoutW() / 2 - (this.barW() + this.gap()) / 2,
        cy: this.systemY() })
      this.systemButton({ g: PadGroup.SYSTEM, label: 'START', code: VpadButton.START,
        cx: this.layoutW() / 2 + (this.barW() + this.gap()) / 2,
        cy: this.systemY() })

      // ---- 双摇杆 ----
      this.stick({ g: PadGroup.LEFT_STICK, isLeft: true,
        cx: this.stickLeftX(), cy: this.stickY() })
      this.stick({ g: PadGroup.RIGHT_STICK, isLeft: false,
        cx: this.stickRightX(), cy: this.stickY() })

      // ---- 编辑态：各组的虚线选框（叠在按键之上，负责拖动）----
      //
      // 为什么选框画在**按键之后**：ArkUI 后声明的子节点在上层，
      // 选框需要盖住按键才能接到拖动事件（按键此时已设为
      // HitTestMode.None，不会抢事件）。
      if (this.editMode) {
        this.editFrame({ g: PadGroup.LEFT_SHOULDER,
          x: this.left(this.controlLeftX(), this.barW() * 2 + this.gap()),
          y: this.top(this.barY(), this.barH()),
          w: this.barW() * 2 + this.gap(), h: this.barH() })
        this.editFrame({ g: PadGroup.RIGHT_SHOULDER,
          x: this.left(this.controlRightX(), this.barW() * 2 + this.gap()),
          y: this.top(this.barY(), this.barH()),
          w: this.barW() * 2 + this.gap(), h: this.barH() })
        this.editFrame({ g: PadGroup.DPAD,
          x: this.left(this.controlLeftX(), this.btn() * 3 + this.gap() * 2),
          y: this.top(this.midY(), this.btn() * 3 + this.gap() * 2),
          w: this.btn() * 3 + this.gap() * 2, h: this.btn() * 3 + this.gap() * 2 })
        this.editFrame({ g: PadGroup.FACE,
          x: this.left(this.controlRightX(), this.btn() * 3 + this.gap() * 2),
          y: this.top(this.midY(), this.btn() * 3 + this.gap() * 2),
          w: this.btn() * 3 + this.gap() * 2, h: this.btn() * 3 + this.gap() * 2 })
        this.editFrame({ g: PadGroup.SYSTEM,
          x: this.left(this.layoutW() / 2, this.barW() * 2 + this.gap()),
          y: this.top(this.systemY(), this.barH()),
          w: this.barW() * 2 + this.gap(), h: this.barH() })
        this.editFrame({ g: PadGroup.LEFT_STICK,
          x: this.left(this.stickLeftX(), this.stickBox()),
          y: this.top(this.stickY(), this.stickBox()),
          w: this.stickBox(), h: this.stickBox() })
        this.editFrame({ g: PadGroup.RIGHT_STICK,
          x: this.left(this.stickRightX(), this.stickBox()),
          y: this.top(this.stickY(), this.stickBox()),
          w: this.stickBox(), h: this.stickBox() })
      }

    }
    // Fill the current game surface and measure it locally.  This is
    // deliberate: the parent can rotate/resize after the child is mounted,
    // and the measured size must replace the initial prop snapshot.
    .width('100%')
    .height('100%')
    // 用 onAppear 而非在 build() 内直接调用：
    // onAppear 在组件挂载后触发，此时 @Prop 已由父组件赋值，
    // getter 依赖的数据必然就绪；也不再受 build() 的语句限制。
    .onAppear(() => {
      this.logLayoutOnce();
      // 首次挂载：从共享单例读入初始布局到本地 @State。
      // 之后本地是唯一真值 —— 拖动只写本地，渲染不依赖外部传播。
      this.loadLocalFromStore();
      console.info(`HPS2_VPAD_MOUNT: ver=${this.layoutVersion} ` +
        `landscape=${this.layoutW() > this.layoutH()}`);
    })
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
