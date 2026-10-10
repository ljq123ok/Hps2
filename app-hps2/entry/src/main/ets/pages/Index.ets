/*
 * Hps2 — 主界面
 *
 * 流程：
 *   1. 用户点「选择 BIOS」→ 系统文件管理器（DocumentViewPicker）
 *   2. 选中的 BIOS 被复制进应用沙箱（核心需要 POSIX 路径）
 *   3. 点「启动」→ 调用 native 的 startBios(dataRoot, biosDir)
 *   4. 轮询 getStatus() 显示各启动阶段；失败时显示具体原因
 *
 * 合法性说明（重要）：
 *   本应用**不内置、不分发 BIOS**。用户需自行准备合法拥有的 PS2 BIOS。
 *   界面中明确提示这一点。
 */
import hilog from '@ohos.hilog';
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import resourceManager from '@ohos.resourceManager';
import buffer from '@ohos.buffer';
import fileshare from '@ohos.fileshare';
import hps2core from 'libhps2core.so';
import { Theme } from '../common/Theme';
import { HomeScreen } from '../components/HomeScreen';
import { GameScreen } from '../components/GameScreen';
import { Immersive } from '../common/Immersive';
import { ErrorHint, FailKind } from '../common/ErrorHint';
import { LogExport } from '../common/LogExport';
import { GameEntry, humanSize as libHumanSize, gameDisplayTitle as libGameTitle, gameDisplaySubtitle as libGameSub } from '../common/GameLibrary';
import { MemoryCardInfo, MemoryCardPanel } from '../components/MemoryCardPanel';
import {
  CoverSource, SharedCoverSources, BUILTIN_COVER_SOURCES, buildCoverUrl, isValidCoverTemplate
} from '../common/CoverSources';
import http from '@ohos.net.http';
import {
  PadGroup, PadOffsetEntry, PadStyle, PadLayoutStore, PadLayoutSnapshot,
  PAD_STYLES, PAD_OPACITY_MIN, PAD_OPACITY_MAX,
  offsetOf, setOffset, defaultVariant, clampOpacity, clampStyleIndex,
  SharedPadLayout
} from '../common/PadLayout';
import common from '@ohos.app.ability.common';

const DOMAIN = 0x3202;
const TAG = 'HPS2_CORE';

// ============================================================================
// 悬浮功能条的固定配色（**刻意不跟随日夜主题**）
//
// 为什么：该功能条叠在**游戏画面**之上，而画面内容不可预知
// （可能雪白也可能漆黑）。若文字颜色跟随 UI 主题，浅色模式下
// textPri 会变成近黑色，压在固定的深色半透明底上就糊成一片 ——
// 这是用户在真机上实测到的问题（"只有按键两个字看得清"，
// 因为那一项恰好用的是亮蓝强调色）。
//
// 因此这里用固定色：深色半透明底 + 浅色文字 + 亮色强调，
// 在任意画面内容上都能看清。与虚拟按键的处理同理。
// ============================================================================
/** 半透明深色底：在亮/暗画面上都提供足够反差 */
const OVERLAY_BG: string = '#B3000000';
/** 主文字：浅色，压在深底上清晰 */
const OVERLAY_FG: string = '#F9FAFB';
/** 次要文字 */
const OVERLAY_FG_DIM: string = '#B8C0CC';
/** 强调色（状态正常、已启用） */
const OVERLAY_OK: string = '#4ADE80';
/** 强调色（操作类，如当前显示中的开关） */
const OVERLAY_ACCENT: string = '#60A5FA';
/** 描边 */
const OVERLAY_BORDER: string = '#59FFFFFF';

interface BootStatus {
  stage: number;
  stageName: string;
  running: boolean;
  paused: boolean;
  error: string;
  fps: number;
  jitAvailable: boolean;
  jitStage: string;
  jitErrno: number;
  jitMessage: string;
  jitAction: string;
  jitDiagnostics: string;
  storeBuild: boolean;
  executionMode: string;
  degraded: boolean;
  downgradeReason: string;
  /** 游戏本体识别：当前光盘序列号（如 SLUS-12345）；未启动时为空串 */
  discSerial: string;
  /** 当前光盘标题；未启动或数据库无记录时为空串 */
  discTitle: string;
  /** 当前 ELF 的 CRC，固定 8 位十六进制（与存档文件名中的值一致） */
  discCRC: string;
}

/** JIT 自检结果（对应 native 的 checkJit()，见 libhps2core/index.d.ts） */
interface JitCheckResult {
  available: boolean;
  stage: number;
  stageName: string;
  errno: number;
  message: string;
  action: string;
  prctlAttempted?: boolean;
  prctlAccepted?: boolean;
  prctlRet?: number;
  prctlErrno?: number;
  pageSize?: number;
  memfdAttempted?: boolean;
  memfdSupported?: boolean;
  memfdInitialExec?: boolean;
  memfdAliasUpdate?: boolean;
  memfdLoop?: boolean;
  memfdConcurrent?: boolean;
  memfdLoopIterations?: number;
  memfdErrno?: number;
  memfdDetail?: string;
  preferredStrategy?: string;
  selinuxContext?: string;
  runtimeValidationAttempted?: boolean;
  runtimeValidationPassed?: boolean;
}

interface JitPrctlExperimentResult {
  attempted: boolean;
  accepted: boolean;
  startupPrctlAlreadyAttempted?: boolean;
  prctlRet: number;
  prctlErrno: number;
  callThreadId: number;
  before?: JitCheckResult;
  after?: JitCheckResult;
  scope: string;
  message?: string;
}

interface BiosSelection {
  fileName: string;
  displayName: string;
}

/**
 * 上次选中的游戏。
 *
 * 与 BIOS 不同，游戏镜像**原地读取**（不复制到沙箱），
 * 因此这里保存的是完整的 URI，而不是沙箱内文件名。
 * URI 的读权限经 fileshare.persistPermission() 持久化，重启后仍可用。
 */
interface GameSelection {
  uri: string;
  name: string;
}


/**
 * 某游戏的独立设置（对应 native readGameSettings()）。
 *
 * `*Set` 字段区分"该游戏显式覆盖了此项"与"未设置、继承全局设置" ——
 * 这是逐游戏设置的关键语义，UI 必须能表达"这一项我不覆盖"。
 */
interface PerGameSettings {
  ok: boolean;
  serial: string;
  crc: number;
  path: string;
  hasFile: boolean;
  aspect: number;
  upscale: number;
  vuThread: boolean;
  aspectSet: boolean;
  upscaleSet: boolean;
  vuThreadSet: boolean;
}

/** 即时存档槽状态（对应 native 的 listSaveSlots()） */
interface SaveSlotInfo {
  slot: number;
  hasSave: boolean;
}

/** 存档操作结果（对应 native 的 saveState()/loadState()） */
interface SaveOpResult {
  ok: boolean;
  message: string;
}

interface MemoryCardOpResult {
  ok: boolean;
  message: string;
}

interface MemoryCardGroupRecord {
  cardName: string;
  groupName: string;
}

/** BIOS 规格检查结果（对应 native 的 checkBios()） */
interface BiosCheckResult {
  sizeOk: boolean;
  signatureOk: boolean;
  size: number;
  sizeText: string;
  message: string;
}

interface VideoSettingsSelection {
  upscaleMultiplier: number;
  /** MTVU（VU1 独立线程）；可选以兼容旧版配置文件 */
  vuThread?: boolean;
}

interface ControllerInfo {
  id: string;
  name: string;
  mapped: boolean;
}

interface ControllerDescriptor {
  id: string;
  name: string;
}

@Entry
@Component
struct Index {
  @State biosPath: string = '';
  @State biosName: string = '';
  @State gamePath: string = '';
  @State gameName: string = '';
  /**
   * 游戏库列表（games/ 目录下的镜像元数据）。
   *
   * 【为什么需要】此前 UI 只能保存**单个**游戏，换一个就得重新选择并
   * 再复制一份。现在把目录里已有的镜像都列出来供点选。
   *
   * 内容由 native listGames() 扫描得出（serial/title/CRC 等），故
   * **只在 VM 未运行时刷新** —— 运行中扫描会破坏 CDVD 状态。
   */
  @State games: Array<GameEntry> = [];
  /** 游戏库是否正在扫描（重 IO，需可见反馈） */
  @State gamesScanning: boolean = false;
  /**
   * 封面：path -> 本地封面文件路径（无封面则不在表里）。
   *
   * 用 Map 而非给 GameEntry 加字段：封面是**异步后到**的（下载/读盘），
   * 而 games 数组由 native 一次性返回。分开存可以让封面到达时只刷新
   * 对应那一行，不重建整个列表。
   */
  @State coverPaths: Map<string, string> = new Map();
  /** 正在下载封面的游戏路径集合（用于显示进度/禁用重复点击） */
  @State coverBusy: Set<string> = new Set();
  /** 封面下载的最近一次结果说明（成功/失败原因，展示给用户） */
  @State coverMessage: string = '';
  /** 封面源面板是否展开 */
  @State showCoverSources: boolean = false;
  /**
   * 封面源列表的版本号。
   *
   * 【为什么需要】源列表存在 SharedCoverSources 单例里，而模块级单例
   * 不是可观察对象 —— 新增/删除/启停源之后界面不会自己重绘。
   * 这与编辑器里"透明度百分比不刷新"是同一类问题，故照同一套做法：
   * 改完自增版本号，让它成为可观察的刷新信号。
   */
  @State coverSourceVersion: number = 0;
  /** 新增自定义源的输入（名称 / URL 模板）*/
  @State newSourceName: string = '';
  @State newSourceUrl: string = '';
  /** 新增失败的原因（成功则清空）*/
  @State newSourceError: string = '';
  /**
   * 逐游戏设置面板：正在为哪个游戏编辑（null = 未打开）。
   * 同时持有读到的当前值，避免面板每次重绘都重扫镜像（扫描是重 IO）。
   */
  @State perGameTarget: GameEntry | null = null;
  @State perGame: PerGameSettings | null = null;
  @State perGameMessage: string = '';
  @State picking: string = '';   // '' | 'bios' | 'game' —— 区分正在选哪个
  @State surfaceReady: boolean = false;
  @State surfaceSize: string = '';

  // XComponent 控制器：其回调给出 surfaceId，我们转交 native 换取 OHNativeWindow
  private xcController: XComponentController = new XComponentController();
  // 用显式的 number 保存尺寸：SizeOptions 的字段是 Length 且可选，
  // 直接读会得到 Length | undefined，无法传给需要 number 的 native 接口。
  @State surfaceW: number = 0;
  @State surfaceH: number = 0;
  @State statusStage: string = 'idle';

  // ---- 长任务的加载提示 ----
  //
  // 为什么单独建状态而不是复用 statusStage：
  // statusStage 是 native 上报的启动阶段（idle/starting-thread/...），
  // 语义是"模拟器核心的状态"；而这里是"应用正在做一件耗时的事"
  // （复制数 GB 的游戏镜像、解析 BIOS）。两者含义不同，
  // 混用会让 UI 判断变得含糊。
  @State loading: boolean = false;
  @State loadingText: string = '';

  // ---- 失败原因分类（改进 1）----
  // 只显示原始错误串，用户无从判断该重启设备还是该换 BIOS。
  @State errorKind: number = 0;          // FailKind
  @State errorAdvice: string = '';

  // ---- BIOS 规格检查结果（改进 2）----
  @State biosCheckMessage: string = '';
  @State biosCheckSuspicious: boolean = false;
  @State biosCheckChecked: boolean = false;

  // ---- 日志导出反馈（改进 3）----
  @State logExportMessage: string = '';

  // ---- 即时存档 ----
  // 与游戏内的记忆卡存档不同：这是整机状态快照，可随时存/读。
  @State saveSlots: Array<SaveSlotInfo> = [];
  @State saveMessage: string = '';
  @State showSavePanel: boolean = false;

  // ---- PS2 记忆卡（跨模拟器可移植文件） ----
  @State memoryCards: Array<MemoryCardInfo> = [];
  @State memoryCardMessage: string = '';
  @State memoryCardsDirectory: string = '';
  @State memoryCardBusy: boolean = false;
  @State memoryCardGroupFilter: string = '全部';
  @State memoryCardGroupRecords: Array<MemoryCardGroupRecord> = [];
  @State showMemoryCardManager: boolean = false;

  /** 悬浮球是否展开为功能列表 */
  @State overlayExpanded: boolean = false;

  // ---- 悬浮球位置（可拖动）----
  //
  // 用绝对坐标而非固定右上角：用户要求"拖动后停留在最终位置"。
  // 初值 -1 表示"尚未拖动过"，此时按右上角默认位置摆放；
  // 一旦拖动即以实际坐标为准。
  @State ballX: number = -1;
  @State ballY: number = -1;
  /** 拖动起点（手势开始时球的位置） */
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  @State statusError: string = '';
  @State statusRunning: boolean = false;
  @State gamePaused: boolean = false;
  @State gameFps: number = 0;
  @State busy: boolean = false;

  // ---- 构建通道与执行模式 ----
  @State storeBuild: boolean = false;
  @State executionMode: string = 'unknown';
  @State degraded: boolean = false;
  @State downgradeReason: string = '';

  // ---- 触控布局编辑 ----
  //
  // 布局由本组件（页面）独占持有：VirtualPad 的 @Prop 是值拷贝，
  // 子组件改了传不回来（会导致"拖动能看见、重启就丢"），
  // 故子组件只上报位移，真值在这里，并由这里落盘。
  @State padEditMode: boolean = false;
  /**
   * 布局版本号 —— 传给 GameScreen/VirtualPad 的唯一刷新信号。
   *
   * 【为什么不再传布局对象】真机实测：对象经两层 @Prop 传递后，
   * 拖动事件与落盘均正常，但 VirtualPad 读到的偏移恒为 0、画面不重绘。
   * 现布局数据放在 SharedPadLayout 单例里（双方直接读），
   * 组件间只传这个 number —— 原始类型跨层传播绝对可靠。
   */
  /**
   * 布局版本号 —— 写入 AppStorage 全局键，由 VirtualPad 用
   * @StorageLink 直接订阅（绕开逐层 @Prop，见 VirtualPad 的说明）。
   */
  @StorageLink('hps2_pad_layout_version') padLayoutVersion: number = 0;
  /** 版本号对应的横屏状态 */
  @State padLayoutLandscape: boolean = false;
  @State padStyleIndex: number = 0;
  /**
   * 当前方向的按键透明度（0.15–1.0）。
   *
   * 【为什么需要一个独立的 @State 镜像】
   *   透明度本体存在 SharedPadLayout 单例里，而模块级单例**不是可观察对象** ——
   *   ArkUI 不会因为它的字段变化而重绘。此前编辑器里的百分比文本直接调
   *   currentPadVariant().opacity，读的是单例，因此数值永不刷新
   *   （滑杆本身能动，是因为 Slider 的 value 由用户手势驱动，与本问题无关）。
   *
   *   同样的问题在配色上早已解决：padStyleIndex 就是单例值的 @State 镜像，
   *   由 syncPadLayoutFromStore() 在每次变更后同步。这里照同一套做。
   */
  @State padOpacity: number = 0.6;
  // 进入编辑前用户的开关状态，退出时恢复
  private padEditRememberShow: boolean = true;
  private padEditRememberOverlay: boolean = false;
  /**
   * 进入编辑器时的布局快照，供「返回」（取消）真正回滚。
   * 编辑期间的拖动/配色等操作会**立即落盘**，所以不能靠"重读磁盘"取消
   * ——磁盘早已被覆盖。见 PadLayoutStore.snapshot() 的说明。
   */
  private padEditSnapshot: PadLayoutSnapshot | null = null;

  // ---- 游戏本体识别（serial / 标题 / CRC）----
  //
  // 为什么需要：记忆卡按**序列号**自动归类，但序列号此前从不显示 ——
  // 用户看到"已匹配当前游戏"却不知道匹配依据，也无法判断某张卡属于哪个游戏。
  // 由 refreshStatus() 每 500ms 从 native 同步（native 侧有 s_info_mutex
  // 保护，可安全轮询；未启动游戏时 native 返回空串）。
  @State discSerial: string = '';
  @State discTitle: string = '';
  @State discCRC: string = '';

  // 开发构建要求 JIT；商店构建按策略固定使用解释器。
  // jitChecked 区分"还没查"与"查了但不可用"：
  // 前者不该显示红色警告，后者必须明确告诉用户不能启动。
  @State jitChecked: boolean = false;
  @State jitAvailable: boolean = false;
  @State jitMessage: string = '';
  @State jitAction: string = '';
  @State jitStage: string = '';
  @State jitErrno: number = 0;
  @State jitDiagnostics: string = '{}';
  @State jitChecking: boolean = false;
  @State jitPrctlExperimentResult: string = '';

  // ---- 新前端的 UI 状态 ----
  /** 页面模式：home=设置/游戏库  game=全屏游玩 */
  @State viewMode: string = 'home';
  /** 是否显示虚拟按键（接入手柄后可关闭） */
  @State showPad: boolean = true;
  /** 官方原生手柄输入已启用；禁用 ArkUI 焦点接收器以免十字键导航 UI。 */
  @State nativeGamepad: boolean = false;
  /** 设置弹层 */
  @State showSettings: boolean = false;
  /** SDL 已识别的真实手柄；蓝牙手柄通过系统 HID 进入这里。 */
  @State controllerDevices: Array<ControllerInfo> = [];
  @State controllerStatus: string = '请先启动游戏，再刷新手柄列表';
  /** 画面比例：0=自动 1=保持4:3 2=铺满 3=宽屏16:9 */
  @State aspectMode: number = 0;
  /**
   * MTVU（VU1 独立线程）。
   * 上游默认为开启；我们早期为"减少线程依赖"显式关闭，
   * 该理由已过时，故开放给用户切换。
   * **下次启动游戏生效** —— 运行期无法可靠切换，UI 已说明。
   */
  @State vuThread: boolean = false;

  /**
   * 正在停止模拟器。用于在停止期间禁用"启动游戏"，
   * 避免"停止中又启动"的竞态（曾导致刚启动的 VM 被立刻停掉）。
   */
  @State stopping: boolean = false;
  /** 内部渲染倍率：1.0 为原生分辨率 */
  @State upscaleMultiplier: number = 1.0;

  private timerId: number = -1;

  // 应用沙箱内的数据目录与 BIOS 目录
  private dataRoot(): string {
    return getContext(this).filesDir;
  }
  private biosDir(): string {
    return this.dataRoot() + '/bios';
  }
  private gameDir(): string {
    return this.dataRoot() + '/games';
  }

  private memoryCardsDir(): string {
    return this.dataRoot() + '/memcards';
  }

  private memoryCardGroupsFile(): string {
    return this.dataRoot() + '/memory-card-groups.json';
  }

  private biosSelectionFile(): string {
    return this.biosDir() + '/selected.json';
  }

  private videoSettingsFile(): string {
    return this.dataRoot() + '/video-settings.json';
  }

  // ===================== 触控布局 =====================

  /**
   * 把 store 中当前方向的布局同步到 @State。
   *
   * 为什么要这一步：store 里同时持有横竖屏两套，而 UI 只显示当前方向那套。
   * 旋转后必须重新取一次，否则横屏会沿用竖屏的偏移
   * （PadLayout.ets 说明了为何两套必须独立）。
   */
  /**
   * 把当前方向的布局同步到共享单例，并**自增版本号**通知 UI 重绘。
   *
   * 【为什么用版本号而不是传布局对象】
   *   真机实测：布局对象经 Index → GameScreen → VirtualPad 两层 @Prop
   *   传递时，拖动事件正常到达、数据也成功落盘（日志有 HPS2_DRAG 与
   *   saved pad layout），但 VirtualPad 读到的偏移恒为 0、画面不重绘
   *   —— 跨层 @Prop 对"对象 + 联合类型"的观察不可靠（Map 亦然）。
   *
   *   现在布局数据放在 SharedPadLayout 单例中，读写双方直接访问；
   *   组件间只传一个 number。原始类型跨层传播绝对可靠：
   *   版本号一变 → 子组件重绘 → 重绘时从单例读最新布局。
   */
  private syncPadLayoutFromStore(): void {
    const landscape = this.surfaceW > this.surfaceH;
    // 只操作单例本身，不再持有独立的 store 字段 ——
    // 避免"页面一份、单例一份"两处数据不同步（这正是难查的坑来源）。
    this.padLayoutLandscape = landscape;
    this.padStyleIndex = SharedPadLayout.store.getStyleIndex();
    // 透明度同样镜像到 @State —— 面板上的百分比文本依赖它才会刷新
    // （单例本身不可观察，见 padOpacity 的说明）。
    this.padOpacity = SharedPadLayout.store.variant(landscape).opacity;
    // 自增版本号：这是唯一的重绘触发器
    this.padLayoutVersion = SharedPadLayout.bump();
    // 链路诊断第 2 环：确认 @State 已写入新版本号
    console.info(`HPS2_CHAIN_2: padLayoutVersion -> ${this.padLayoutVersion} ` +
      `landscape=${landscape}`);
  }

  /** 启动时恢复布局（坏文件回退默认，不阻断游戏）*/
  private restorePadLayout(): void {
    SharedPadLayout.store.load(this.dataRoot());
    this.syncPadLayoutFromStore();
  }

  /**
   * 拖动某组的回调。
   *
   * 接收的是**归一化位移**（VirtualPad 已按 px→vp 换算后归一化），
   * 累加到共享 store 上，再自增版本号触发重绘。
   * 每次只改一个组，故 O(1)。
   */
  private handlePadGroupDragged(group: PadGroup, dxNorm: number, dyNorm: number): void {
    // 链路诊断第 1 环：确认子组件回调是否到达父组件
    console.info(`HPS2_CHAIN_1: parent received drag group=${group} ` +
      `dx=${dxNorm.toFixed(4)} dy=${dyNorm.toFixed(4)}`);
    const landscape = this.surfaceW > this.surfaceH;
    const v = SharedPadLayout.store.variant(landscape);
    const cur = offsetOf(v, group);
    // setOffset 内部做边界钳制（±30%），保证控件主体不会被拖出屏幕
    setOffset(v, group, cur.dx + dxNorm, cur.dy + dyNorm);
    this.syncPadLayoutFromStore();
  }

  /** 拖动结束：落盘一次（避免每帧写盘）*/
  private handlePadDragEnd(): void {
    SharedPadLayout.store.save(this.dataRoot());
  }

  /** 透明度改变 */
  private handlePadOpacityChange(v: number): void {
    const landscape = this.surfaceW > this.surfaceH;
    const layout = SharedPadLayout.store.variant(landscape);
    layout.opacity = clampOpacity(v);
    this.syncPadLayoutFromStore();
  }

  /** 配色改变（立即生效并保存 —— 与拖动不同，这是一次离散操作）*/
  private handlePadStyleChange(index: number): void {
    SharedPadLayout.store.setStyleIndex(clampStyleIndex(index));
    this.syncPadLayoutFromStore();
    SharedPadLayout.store.save(this.dataRoot());
  }

  /** 恢复默认布局 */
  private handlePadReset(): void {
    const landscape = this.surfaceW > this.surfaceH;
    SharedPadLayout.store.resetCurrent(landscape);
    this.syncPadLayoutFromStore();
    SharedPadLayout.store.save(this.dataRoot());
  }

  /** 当前配色 */
  private currentPadStyle(): PadStyle {
    return PAD_STYLES[clampStyleIndex(this.padStyleIndex)];
  }

  /** 当前是否横屏（用于编辑器面板的方向自适应）*/
  private isLandscapeSurface(): boolean {
    return this.surfaceW > this.surfaceH;
  }

  /**
   * 进入/退出布局编辑。
   *
   * 进入时若虚拟按键是关闭状态，会自动打开 —— 否则用户进了编辑器
   * 却看不到任何控件，无从调整（VirtualPad 的显示条件已配合放宽）。
   * 退出时恢复用户原来的开关状态。
   */
  private enterPadEdit(): void {
    this.padEditRememberShow = this.showPad;
    this.showPad = true;
    this.padEditRememberOverlay = this.overlayExpanded;
    this.overlayExpanded = false;   // 悬浮球收起，避免遮挡编辑区
    // 拍快照：编辑期间的操作会立即落盘，取消时靠它回滚
    this.padEditSnapshot = SharedPadLayout.store.snapshot();
    this.padEditMode = true;
  }

  private exitPadEdit(save: boolean): void {
    if (!save) {
      // 取消：用进入时的快照覆盖（编辑期间已落盘的改动一并撤销），
      // 然后回写磁盘 —— 这样"返回"才真的等于放弃本次修改。
      if (this.padEditSnapshot !== null) {
        SharedPadLayout.store.restore(this.padEditSnapshot);
        SharedPadLayout.store.save(this.dataRoot());
      }
      this.syncPadLayoutFromStore();
      this.padEditSnapshot = null;
    } else {
      SharedPadLayout.store.save(this.dataRoot());
      this.padEditSnapshot = null;
    }
    // 恢复悬浮球展开态（进入编辑时强制收起过）
    this.overlayExpanded = this.padEditRememberOverlay;
    this.showPad = this.padEditRememberShow;
    this.padEditMode = false;
  }

  /**
   * 封面源的一行：单选 + 名称 + 备注 +（内置）启停 /（自定义）删除。
   *
   * isBuiltin 决定右侧是开关还是删除按钮 —— 内置源只允许启停
   * （它们是代码里的常量，删掉没有意义，反而会让"没源可用"更难恢复）。
   */
  @Builder
  coverSourceRow(src: CoverSource, isBuiltin: boolean) {
    Row({ space: 10 }) {
      Radio({ value: src.id, group: 'cover-source' })
        .checked(this.currentCoverSourceId() === src.id)
        .onChange((checked: boolean) => {
          if (checked) {
            this.selectCoverSource(src.id);
          }
        })

      Column({ space: 2 }) {
        Text(src.name).fontSize(13).fontColor(Theme.textPri())
          .width('100%').textAlign(TextAlign.Start)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(src.note).fontSize(10).fontColor(Theme.textDim())
          .width('100%').textAlign(TextAlign.Start)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (isBuiltin) {
        Toggle({ type: ToggleType.Switch, isOn: this.isBuiltinCoverEnabled(src.id) })
          .onChange((on: boolean) => { this.toggleBuiltinCoverSource(src.id, on); })
      } else {
        Text('删除')
          .fontSize(11).fontColor(Theme.warn())
          .padding(6)
          .onClick(() => { this.removeCustomCoverSource(src.id); })
      }
    }
    .width('100%')
    .padding(Theme.pad)
    .backgroundColor(Theme.bgCard())
    .borderRadius(Theme.radius)
    .border({ width: 1, color: Theme.border() })
  }

  /**
   * 逐游戏设置里的一项标题行：名称 + 状态说明 +（已覆盖时）"跟随全局"按钮。
   *
   * "跟随全局"是本功能的必要组成：没有它，用户一旦点过某项就再也回不到
   * 继承状态（只能去手改 INI 或删文件）。
   */
  @Builder
  perGameSection(title: string, subtitle: string, overridden: boolean, onClear: () => void) {
    Row() {
      Column({ space: 2 }) {
        Text(title).fontSize(13).fontColor(Theme.textPri())
          .width('100%').textAlign(TextAlign.Start)
        Text(subtitle).fontSize(10)
          .fontColor(overridden ? Theme.ok() : Theme.textDim())
          .width('100%').textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (overridden) {
        Text('跟随全局')
          .fontSize(11).fontColor(Theme.accentHi())
          .padding(4)
          .onClick(() => { onClear(); })
      }
    }
    .width('100%')
  }

  /** 编辑器右侧/底部设置面板 */
  @Builder
  padEditorPanel() {
    Column({ space: 12 }) {
      Text('触控设置')
        .fontSize(15).fontColor(OVERLAY_FG).fontWeight(FontWeight.Medium)
        .width('100%')

      // ---- 按键透明度（设计稿：Button opacity，默认 60%）----
      Column({ space: 4 }) {
        Row() {
          Text('按键透明度').fontSize(12).fontColor(OVERLAY_FG_DIM)
          Blank()
          // 读 @State 镜像而非单例：单例不可观察，百分比不会刷新
          // （见 padOpacity 的说明）。
          Text(Math.round(this.padOpacity * 100).toString() + '%')
            .fontSize(12).fontColor(OVERLAY_FG)
        }
        .width('100%')

        Slider({
          value: Math.round(this.padOpacity * 100),
          min: Math.round(PAD_OPACITY_MIN * 100),
          max: Math.round(PAD_OPACITY_MAX * 100),
          step: 5,
          style: SliderStyle.OutSet
        })
          .width('100%')
          .blockColor(OVERLAY_FG)
          .trackColor(OVERLAY_BORDER)
          .selectedColor(OVERLAY_ACCENT)
          .onChange((value: number) => {
            this.handlePadOpacityChange(value / 100);
          })
      }
      .width('100%')

      // ---- 按键配色（设计稿：Button style 色板）----
      Column({ space: 6 }) {
        Text('按键配色').fontSize(12).fontColor(OVERLAY_FG_DIM).width('100%')
        Row({ space: 8 }) {
          ForEach(PAD_STYLES, (st: PadStyle, idx: number) => {
            Stack() {
              Circle()
                .width(26).height(26)
                // 色板显示用实色（去掉 alpha，否则在黑底上看不出差别）
                .fill(this.styleSwatch(st, idx))
                .stroke(this.padStyleIndex === idx ? OVERLAY_OK : OVERLAY_BORDER)
                .strokeWidth(this.padStyleIndex === idx ? 2 : 1)
            }
            .onClick(() => { this.handlePadStyleChange(idx); })
          }, (st: PadStyle) => st.name)
        }
        .width('100%')
      }
      .width('100%')

      // ---- 操作 ----
      Row({ space: 8 }) {
        Button('恢复默认')
          .layoutWeight(1).height(36).fontSize(13)
          .backgroundColor(OVERLAY_BG).fontColor(OVERLAY_FG)
          .borderRadius(18)
          .onClick(() => { this.handlePadReset(); })
        Button('保存')
          .layoutWeight(1).height(36).fontSize(13)
          .backgroundColor(OVERLAY_ACCENT).fontColor('#FFFFFF')
          .borderRadius(18)
          .onClick(() => { this.exitPadEdit(true); })
      }
      .width('100%')

      Text(this.isLandscapeSurface()
        ? '每套方向各存一份布局；保存后立即生效。'
        : '竖屏与横屏的布局分别保存。')
        .fontSize(10).fontColor(OVERLAY_FG_DIM).width('100%')
    }
    .width(this.isLandscapeSurface() ? 220 : '100%')
    .padding(12)
    .margin({ right: this.isLandscapeSurface() ? 12 : 0, bottom: this.isLandscapeSurface() ? 0 : 8 })
    .backgroundColor(OVERLAY_BG)
    .borderRadius(Theme.radius)
    .border({ width: 1, color: OVERLAY_BORDER })
  }

  /**
   * 色板显示色。
   *
   * 配色本身含 alpha（#40FFFFFF 等），直接画在黑底面板上几乎看不见，
   * 故显示时统一去掉 alpha 通道 —— 用户选的是"颜色"，不是"透明度"
   * （透明度由上面的滑杆单独控制）。
   */
  private styleSwatch(st: PadStyle, idx: number): string {
    const hex = st.border;
    if (hex.length === 9) {
      return '#' + hex.substring(3);
    }
    return hex;
  }

  aboutToAppear(): void {
    // ---------------------------------------------------------------------
    // 初始化 AppStorage 的布局版本键。
    //
    // 必须先于任何组件挂载执行：@StorageLink 在组件创建时会读取该键，
    // 若键不存在则取默认值 0；先建立键可保证后续自增被正确观察。
    // ---------------------------------------------------------------------
    if (AppStorage.get<number>('hps2_pad_layout_version') === undefined) {
      AppStorage.setOrCreate<number>('hps2_pad_layout_version', 0);
    }
    // Native 状态只在当前进程内有效；先恢复持久化设置，再读取 UI 初始值。
    this.restoreVideoSettings();
    // 触控布局同样要恢复；坏文件回退默认，不阻断启动。
    this.restorePadLayout();
    // 让 native 侧与 UI 的初始比例一致（默认「自动」）。
    try {
      this.aspectMode = hps2core.getAspectMode();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getAspectMode failed');
    }
    try {
      this.upscaleMultiplier = hps2core.getUpscaleMultiplier();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getUpscaleMultiplier failed');
    }
    try {
      const dir = this.biosDir();
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
      hilog.info(DOMAIN, TAG, 'BIOS storage directory prepared');
      this.restoreBiosSelection();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'mkdir BIOS directory failed');
    }
    try {
      const gdir = this.gameDir();
      if (!fs.accessSync(gdir)) {
        fs.mkdirSync(gdir);
      }
      hilog.info(DOMAIN, TAG, 'game storage directory prepared');
      // 目录就绪后恢复上次选中的游戏（此前只写不读）
      this.restoreGameSelection();
      // 【必须在读写逐游戏设置/封面之前】native 侧的 GameSettings/Covers
      // 原本只在"启动游戏"时才赋值，未启动游戏时为空字符串，会让路径
      // 退化成从根目录拼（实测写成 /SCPS-15062_1C4E2A9F.ini → errno 13）。
      hps2core.initGameFolders(this.dataRoot());
      // 封面源配置（决定后续下载走哪个库）
      SharedCoverSources.store.load(this.dataRoot());
      // 再扫描整个 games/ 目录填充游戏库列表。
      // 放在 restore 之后：即使列表为空，上次选中的游戏也已恢复。
      this.refreshGames();
      // 扫描完列表后解析本地已有封面（纯查文件，无网络）
      this.refreshLocalCovers();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'mkdir games directory failed');
    }
    try {
      this.memoryCardsDirectory = hps2core.memoryCardsDirectory(this.dataRoot());
      this.loadMemoryCardGroups();
      this.refreshMemoryCards();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'memory card directory setup failed');
    }
    // 核心要求 <AppRoot>/resources 存在（SetResourcesDirectory 会校验），
    // 首次启动时从 HAP 的 rawfile 解压出来。
    this.ensureResources();
    this.refreshStatus();

    // 启动前先查 JIT 能力：让用户在选 BIOS 之前就知道能不能跑，
    // 而不是点了启动才发现失败。
    this.checkJit();

  }

  /**
   * 页面销毁：释放本页面持有的定时器。
   *
   * 【为什么必须有】此前只有 startPolling 而没有对应的清理，
   * 页面销毁后 setInterval 仍会触发 —— 回调持有 this，
   * 既阻止回收，又在页面已不可见时继续调 native 并写状态。
   */
  aboutToDisappear(): void {
    this.stopPolling();
  }

  /*
   * JIT 能力自检。
   *
   * 为什么放在 UI 层做一次：native 侧在 startBios() 里也有硬门禁（权威判据），
   * 但那次失败对用户来说太晚 —— 用户已经选好 BIOS、点过启动。
   * 这里提前查一次，把结论和建议直接摆在界面上。
   *
   * 注意：这是**一次真实的**自检（会申请页并执行代码），不是缓存查询，
   * 因此不放在高频刷新的轮询里。
   */
  private checkJit(): void {
    this.jitChecking = true;
    let raw: string = '';
    try {
      raw = hps2core.checkJit();
      const r = JSON.parse(raw) as JitCheckResult;
      this.jitAvailable = r.available;
      this.jitMessage = r.message;
      this.jitAction = r.action;
      this.jitStage = r.stageName;
      this.jitErrno = r.errno;
      this.jitDiagnostics = this.formatJitDiagnostics(r);
      this.jitChecked = true;
      hilog.info(DOMAIN, TAG, 'checkJit available=%{public}d stage=%{public}s errno=%{public}d',
        r.available ? 1 : 0, r.stageName, r.errno);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'checkJit failed: %{public}s rawLength=%{public}d tail=%{public}s',
        err.message, raw.length, raw.slice(Math.max(0, raw.length - 120)));
      // 自检本身抛异常 => 视为不可用（不静默放过）
      this.jitAvailable = false;
      this.jitChecked = true;
      this.jitMessage = 'JIT 自检调用失败：' + err.message;
      this.jitAction = '请重启应用后重试；若仍失败，请反馈此结果。';
      this.jitStage = 'call-failed';
    } finally {
      this.jitChecking = false;
    }
  }

  private runJitPrctlExperiment(): void {
    try {
      const raw: string = hps2core.runJitPrctlExperiment();
      const r = JSON.parse(raw) as JitPrctlExperimentResult;
      const before = r.before;
      const after = r.after;
      this.jitPrctlExperimentResult = before !== undefined && after !== undefined
        ? `thread=${r.callThreadId} A=${before.available ? 'PASS' : 'FAIL'}(${before.stageName}/${before.errno}) ` +
          `prctl=${r.prctlRet}/${r.prctlErrno} ` +
          `B=${after.available ? 'PASS' : 'FAIL'}(${after.stageName}/${after.errno})` +
          (r.startupPrctlAlreadyAttempted ? ' (启动时已调用 prctl；A 不是无 prctl 基线)' : '')
        : (r.message !== undefined ? r.message : r.scope);
      hilog.warn(DOMAIN, TAG, 'JIT_PRCTL_AB %{public}s', this.jitPrctlExperimentResult);
      if (after !== undefined) {
        this.jitAvailable = after.available;
        this.jitMessage = after.message;
        this.jitAction = after.action;
        this.jitStage = after.stageName;
        this.jitErrno = after.errno;
        this.jitDiagnostics = this.formatJitDiagnostics(after);
        this.jitChecked = true;
      }
    } catch (e) {
      const err = e as BusinessError;
      this.jitPrctlExperimentResult = '实验调用失败：' + err.message;
      hilog.error(DOMAIN, TAG, 'JIT_PRCTL_AB failed: %{public}s', err.message);
    }
  }

  private formatJitDiagnostics(r: JitCheckResult): string {
    const attempted = r.prctlAttempted === true;
    const memfd = r.memfdAttempted === true
      ? (r.memfdSupported === true ? 'PASS' : `FAIL errno=${r.memfdErrno || 0}`)
      : '未运行';
    const runtime = r.runtimeValidationAttempted === true
      ? (r.runtimeValidationPassed === true ? 'PASS' : 'FAIL')
      : '尚无运行期复检';
    const lines = [
      `prctl: ${attempted ? (r.prctlAccepted ? 'accepted' : 'rejected') : 'not attempted'} ret=${r.prctlRet || 0} errno=${r.prctlErrno || 0}`,
      `匿名 RW→RX: ${r.available ? 'PASS' : 'FAIL'} (${r.stageName}, errno=${r.errno})`,
      `memfd RW/RX: ${memfd}; loops=${r.memfdLoopIterations || 0}`,
      `运行期复检: ${runtime}`,
      `preferred=${r.preferredStrategy || 'None'}; page=${r.pageSize || 0}; build=${this.storeBuild ? 'release/store-policy' : 'debug'}`,
      `SELinux: ${r.selinuxContext || '不可读取'}`
    ];
    if (r.memfdDetail) lines.push(r.memfdDetail);
    return lines.join('\n');
  }

  /*
   * 把 HAP rawfile 中的 resources/ 解压到应用数据目录。
   *
   * 为什么需要：核心的 EmuFolders::SetResourcesDirectory()（见
   * pcsx2/Pcsx2Config.cpp）在非 Apple 平台会去找 <AppRoot>/resources，
   * 目录不存在就直接返回 false。HAP 内的 rawfile 不是普通文件路径，
   * 核心读不到，必须先解压到真实文件系统。
   *
   * 实现方式：使用**构建期生成的清单**（rawfile_manifest.json）逐条解压，
   * 而不是运行时递归遍历。原因：getRawFileList 是否返回子目录、
   * 是否递归在文档中未明确，依赖它容易出错；清单是确定的。
   *
   * 幂等：以字体文件为标记，已解压则跳过。
   */
  private ensureResources(): void {
    const resDir = this.dataRoot() + '/resources';
    const marker = resDir + '/fonts/Roboto-Regular.ttf';
    try {
      if (fs.accessSync(marker)) {
        hilog.info(DOMAIN, TAG, 'resources already extracted');
        return;
      }

      hilog.info(DOMAIN, TAG, 'extracting resources');
      const mgr = getContext(this).resourceManager;

      const raw: Uint8Array = mgr.getRawFileContentSync('rawfile_manifest.json');
      const text = buffer.from(raw.buffer).toString('utf-8');
      const list: Array<string> = JSON.parse(text) as Array<string>;
      hilog.info(DOMAIN, TAG, 'manifest entries=%{public}d', list.length);

      let ok = 0;
      for (const rel of list) {
        // rel 形如 "resources/fonts/Roboto-Regular.ttf"
        const dest = this.dataRoot() + '/' + rel;
        this.mkdirsFor(dest);

        const data: Uint8Array = mgr.getRawFileContentSync(rel);
        const file = fs.openSync(dest,
          fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, data.buffer);
        fs.closeSync(file);
        ok++;
      }
      hilog.info(DOMAIN, TAG, 'extracted %{public}d/%{public}d files', ok, list.length);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'extract resources failed');
      this.statusError = '解压资源失败：' + (err.message ? err.message : JSON.stringify(err));
    }
  }

  // 为目标文件路径逐级创建父目录
  private mkdirsFor(filePath: string): void {
    const idx = filePath.lastIndexOf('/');
    if (idx <= 0) {
      return;
    }
    const dir = filePath.substring(0, idx);
    if (fs.accessSync(dir)) {
      return;
    }
    // 递归确保父目录存在
    this.mkdirsFor(dir);
    fs.mkdirSync(dir);
  }

  /*
   * 把 ArkUI XComponent 的 surface 交给 native 层。
   *
   * 为什么需要这一步：PCSX2/ARMSX2 的 GS 需要一个真实的渲染窗口才能
   * 真正绘制（而不是把画面丢弃）。OHOS 上这个窗口是 OHNativeWindow，
   * 只能由 ArkUI 提供 —— 拿到的途径是 XComponent 的 surfaceId。
   *
   * 数据流：
   *   XComponent.surfaceId (string)
   *     → hps2core.setSurface()           [native]
   *     → OH_NativeWindow_CreateNativeWindowFromSurfaceId()
   *     → OHNativeWindow*
   *     → Host::AcquireRenderWindow() 返回 WindowInfo{type=OHOS}
   *     → GLContextEGLOHOS 交给 EGL
   *
   * 尺寸必须在这里一起传：native 走的是 surfaceId 路径，
   * 拿不到 XComponent 的 component 指针，无法调用
   * OH_NativeXComponent_GetXComponentSize。
   */
  private pushSurface(w: number, h: number): void {
    try {
      const sid: string = this.xcController.getXComponentSurfaceId();
      if (!sid || sid.length === 0) {
        hilog.error(DOMAIN, TAG, 'getXComponentSurfaceId returned empty');
        return;
      }
      const ok: number = hps2core.setSurface(sid, Math.round(w), Math.round(h));
      hilog.info(DOMAIN, TAG,
        'setSurface(sid=%{public}s, %{public}dx%{public}d) -> %{public}d', sid, w, h, ok);
      if (ok === 1) {
        this.surfaceReady = true;
        this.surfaceSize = Math.round(w) + '×' + Math.round(h);
      } else {
        this.surfaceReady = false;
        this.statusError = '渲染表面创建失败（见日志 HPS2_CORE）';
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'pushSurface failed: %{public}s', JSON.stringify(err));
      this.surfaceReady = false;
    }
  }

  // 通过系统文件管理器选择文件，并复制进应用沙箱。
  //
  // 为什么必须复制而不是直接把 URI 交给核心：
  //   核心（PCSX2）通过 POSIX 接口打开文件，需要真实文件系统路径；
  //   而 picker 返回的 URI 授权是**临时**的，App 重启后失效，
  //   模拟器却需要长期稳定访问。复制进沙箱后路径稳定且完全受控。
  //
  // 复制用 fd 方式：直接 copyFileSync(uri, path) 会报 ENOENT，
  // 因为 URI 需先经文件系统解析成文件描述符。
  private async pickAndCopy(kind: string, suffixes: Array<string>,
                            destDir: string): Promise<string> {
    this.picking = kind;
    this.statusError = '';
    try {
      const ctx = getContext(this);
      const options = new picker.DocumentSelectOptions();
      options.fileSuffixFilters = suffixes;

      const docPicker = new picker.DocumentViewPicker(ctx);
      const uris: Array<string> = await docPicker.select(options);
      if (!uris || uris.length === 0) {
        hilog.info(DOMAIN, TAG, 'user cancelled %{public}s selection', kind);
        this.picking = '';
        return '';
      }

      const srcUri = uris[0];
      hilog.info(DOMAIN, TAG, 'selected %{public}s document (URI redacted)', kind);

      const clean = srcUri.split('?')[0];
      const segs = clean.split('/');
      const fileName = decodeURIComponent(segs[segs.length - 1]) || (kind + '.bin');
      const destPath = destDir + '/' + fileName;
      hilog.info(DOMAIN, TAG, '%{public}s copied into sandbox', kind);

      let srcFile: fs.File | null = null;
      let dstFile: fs.File | null = null;
      try {
        srcFile = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
        if (fs.accessSync(destPath)) {
          fs.unlinkSync(destPath);   // 避免复制到自己
        }
        dstFile = fs.openSync(destPath,
          fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.copyFileSync(srcFile.fd, dstFile.fd);
      } finally {
        if (srcFile !== null) {
          fs.closeSync(srcFile);
        }
        if (dstFile !== null) {
          fs.closeSync(dstFile);
        }
      }

      const stat = fs.statSync(destPath);
      hilog.info(DOMAIN, TAG, '%{public}s copied, size=%{public}d', kind, stat.size);
      this.picking = '';
      return destPath + '|' + fileName + '|' + libHumanSize(stat.size);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'pick %{public}s failed', kind);
      this.statusError = '选择文件失败：' + (err.message ? err.message : JSON.stringify(err));
      this.picking = '';
      return '';
    }
  }

  private async chooseBios(): Promise<void> {
    // BIOS 仅 4MB，复制很快，但用户选择后到显示结果之间仍有间隔，
    // 给一个轻量提示避免"点了没反应"的观感。
    this.beginLoading('正在载入 BIOS…');
    try {
      await this.doChooseBios();
    } finally {
      this.endLoading();
    }
  }

  private async doChooseBios(): Promise<void> {
    // PS2 BIOS 常见后缀：.bin / .rom，也有无后缀的
    const r = await this.pickAndCopy('bios',
      ['.bin', '.BIN', '.rom', '.ROM', '.p2b'], this.biosDir());
    if (r.length > 0) {
      const parts = r.split('|');
      this.biosPath = parts[0];
      this.biosName = parts[1] + ' (' + parts[2] + ')';
      this.saveBiosSelection(parts[1], this.biosName);
      // 改进 2：立即做基本规格检查，尽早提示"可能不是有效的 PS2 BIOS"。
      // 不阻止启动 —— 检查可能误判，用户应有最终决定权。
      await this.checkBiosSpec(this.biosPath);
    }
  }

  /** 保存最后一次选择的 BIOS，只记录沙箱内文件名，不保存临时 picker URI。 */
  private saveBiosSelection(fileName: string, displayName: string): void {
    try {
      const file = fs.openSync(this.biosSelectionFile(),
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        const selection: BiosSelection = { fileName: fileName, displayName: displayName };
        fs.writeSync(file.fd, JSON.stringify(selection));
      } finally {
        fs.closeSync(file);
      }
      hilog.info(DOMAIN, TAG, 'saved BIOS selection');
    } catch (e) {
      // BIOS 已复制成功；记录失败不阻止本次启动，但保留诊断日志。
      hilog.error(DOMAIN, TAG, 'save BIOS selection failed');
    }
  }

  /**
   * 应用启动时恢复 BIOS。
   * 兼容早期版本：没有选择记录但沙箱中只有一个 BIOS 文件时自动接管。
   */
  private restoreBiosSelection(): void {
    try {
      let fileName: string = '';
      let displayName: string = '';
      const marker = this.biosSelectionFile();

      if (fs.accessSync(marker)) {
        const raw = fs.readTextSync(marker);
        const selection = JSON.parse(raw) as BiosSelection;
        fileName = selection.fileName;
        displayName = selection.displayName;
      } else {
        const files = fs.listFileSync(this.biosDir());
        let candidateCount = 0;
        for (const name of files) {
          const lower = name.toLowerCase();
          if (lower.endsWith('.bin') || lower.endsWith('.rom') || lower.endsWith('.p2b')) {
            fileName = name;
            candidateCount++;
          }
        }
        if (candidateCount !== 1) {
          fileName = '';
        }
      }

      if (fileName.length === 0) {
        return;
      }

      const restoredPath = this.biosDir() + '/' + fileName;
      if (!fs.accessSync(restoredPath)) {
        this.statusError = '已保存的 BIOS 文件不存在，请到设置中重新选择';
        hilog.error(DOMAIN, TAG, 'saved BIOS file is missing');
        return;
      }

      if (displayName.length === 0) {
        const stat = fs.statSync(restoredPath);
        displayName = fileName + ' (' + libHumanSize(stat.size) + ')';
      }
      this.biosPath = restoredPath;
      this.biosName = displayName;
      if (!fs.accessSync(marker)) {
        this.saveBiosSelection(fileName, displayName);
      }
      hilog.info(DOMAIN, TAG, 'restored BIOS selection');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'restore BIOS selection failed');
    }
  }

  /**
   * 让用户选一个大文件并**原地使用**（不复制）。
   *
   * 【为什么不再复制】外部测试者反馈：选 ISO 后 GUI 卡约 8 秒随后闪退，
   * 而 .bin 正常。成因是 pickAndCopy() 用 fs.copyFileSync **同步复制**
   * 且跑在 UI 线程 —— ISO 动辄 2-4GB，期间界面完全冻结。
   * （自测 2.24GB 约 2.4 秒；用户文件更大或存储更慢时 8 秒合理。）
   *
   * 改为原地读取还有两个额外好处：
   *   1. 省下 2-4GB 沙箱空间（用户此前要等两份拷贝）
   *   2. 游戏放在用户自己的目录里，升级/重装应用不会丢
   *
   * 【权限】长期持有 URI 读权限需要 fileshare.persistPermission()，
   * 其要求的 ohos.permission.FILE_ACCESS_PERSIST 经查 SDK 的
   * PermissionDefinitions.json 为 grantMode=system_grant、
   * availableLevel=normal —— 系统自动授予，非受限、无需 ACL、无需弹窗。
   *
   * 返回 '路径|显示名|大小'，失败返回 ''。
   */
  private async pickInPlace(kind: string, suffixes: Array<string>): Promise<string> {
    this.picking = kind;
    this.statusError = '';
    try {
      const ctx = getContext(this);
      const options = new picker.DocumentSelectOptions();
      options.fileSuffixFilters = suffixes;

      const docPicker = new picker.DocumentViewPicker(ctx);
      const uris: Array<string> = await docPicker.select(options);
      if (!uris || uris.length === 0) {
        hilog.info(DOMAIN, TAG, 'user cancelled %{public}s selection', kind);
        this.picking = '';
        return '';
      }

      const srcUri = uris[0];
      hilog.info(DOMAIN, TAG, 'selected %{public}s document (URI redacted)', kind);

      // 持久化读权限：否则应用重启后该 URI 失效。
      // 失败不致命 —— 本次会话内仍可用，只是下次启动要重选。
      try {
        const policy: fileshare.PolicyInfo = {
          uri: srcUri,
          operationMode: fileshare.OperationMode.READ_MODE
        };
        await fileshare.persistPermission([policy]);
        hilog.info(DOMAIN, TAG, 'persistPermission ok for %{public}s', kind);
      } catch (_e) {
        hilog.error(DOMAIN, TAG, 'persistPermission failed for %{public}s', kind);
      }

      const clean = srcUri.split('?')[0];
      const segs = clean.split('/');
      const fileName = decodeURIComponent(segs[segs.length - 1]) || (kind + '.bin');

      // 只取大小用于显示，不读取内容
      let size = 0;
      try {
        const stat = fs.statSync(srcUri);
        size = stat.size;
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'stat %{public}s failed (size unknown)', kind);
      }

      this.picking = '';
      const sizeText = size > 0 ? libHumanSize(size) : '未知大小';
      // 【注意】返回的是 **URI**，不是转换后的文件系统路径。
      //
      // 我一度把 URI 转成 `/storage/...` 再复制，结果报 13900002
      // (No such file or directory) —— 因为 ArkTS 的 fs 需要的是
      // picker **已授权的那个 URI**；裸路径没有对应授权，反而打不开。
      // 旧实现 fs.openSync(srcUri) 传 URI 是对的，不应改动这一点。
      //
      // 因此：ArkTS 侧一律用 URI 做 IO；native 侧才需要真实路径，
      // 由 copyToSandboxAsync 复制到沙箱后统一用沙箱路径。
      return srcUri + '|' + fileName + '|' + sizeText;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'pick %{public}s failed', kind);
      this.statusError = '选择文件失败：' + (err.message ? err.message : JSON.stringify(err));
      this.picking = '';
      return '';
    }
  }

  /**
   * 异步复制到沙箱。
   *
   * 【为什么用 fd 方式而不是 fs.copyFile(uri, path)】
   * 1) ArkTS 的 fs 需要 picker **已授权的 URI**；把 URI 转成裸路径
   *    （/storage/...）会报 13900002 No such file or directory
   *    —— 这是我上一版改错的地方（本次真机实测踩到）。
   * 2) 直接 copyFileSync(uri, path) 在本平台会报 ENOENT，
   *    故沿用旧实现验证过的做法：先 openSync 成 fd，再按 fd 复制。
   *
   * 【与旧实现的唯一区别】用 **Promise 版** copyFile 而非 copyFileSync：
   * 复制 2-4GB 的 ISO 时不再阻塞 UI 线程（外部反馈的"卡 8 秒"）。
   *
   * 【为什么仍需复制】native 的 CDVD 只接受 POSIX 路径，不能收授权 URI。
   * 若将来 native 支持接收 fd 或 URI 映射，即可省掉这一步
   * （那也是"数据目录外置"的最终形态）。
   */
  private async copyToSandboxAsync(srcUri: string, destDir: string,
                                   fileName: string): Promise<string> {
    const destPath = destDir + '/' + fileName;
    // 用户可见的加载提示。
    // 复制 2-4GB 的 ISO 需要数十秒，期间必须让用户知道应用在工作
    // （此前只在按钮上写"处理中…"，且 picking 在复制开始前就被清掉，
    //   按钮已还原成"选择游戏镜像" —— 用户看不到任何提示）。
    this.beginLoading('正在载入游戏镜像…\n' + fileName);

    try {
      if (fs.accessSync(destPath)) {
        fs.unlinkSync(destPath);   // 覆盖旧文件，避免复制到自己
      }
    } catch (e) {
      // accessSync 失败即不存在，无需处理
    }

    let srcFile: fs.File | null = null;
    let dstFile: fs.File | null = null;
    try {
      srcFile = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
      dstFile = fs.openSync(destPath,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      await fs.copyFile(srcFile.fd, dstFile.fd);
    } finally {
      if (srcFile !== null) {
        fs.closeSync(srcFile);
      }
      if (dstFile !== null) {
        fs.closeSync(dstFile);
      }
    }
    return destPath;
  }

  /**
   * 设置错误并按类别给出处置建议（改进 1）。
   *
   * 用户反馈"我的 BIOS 都能启动，别人不行" —— 根因之一是失败原因
   * 无法区分（JIT 失效要重启、BIOS 无效要换文件，处置完全不同）。
   */
  private setError(raw: string): void {
    this.statusError = raw;
    const kind = ErrorHint.classify(raw);
    this.errorKind = kind;
    this.errorAdvice = kind === FailKind.None ? '' : ErrorHint.advice(kind);
  }

  /** 清除错误及其分类。 */
  private clearError(): void {
    this.statusError = '';
    this.errorKind = FailKind.None;
    this.errorAdvice = '';
  }

  /**
   * 对选中的 BIOS 做基本规格检查（改进 2）。
   *
   * 目的：用户能选中的 .bin 未必是 PS2 BIOS（其它机种也叫 .bin）。
   * 尽早提示，胜过等到启动失败才困惑。
   *
   * 措辞刻意保守 —— 本检查只能排除明显无效的文件，
   * 不能证明文件合法或完整。
   */
  private async checkBiosSpec(path: string): Promise<void> {
    try {
      const raw: string = hps2core.checkBios(path);
      const r = JSON.parse(raw) as BiosCheckResult;
      this.biosCheckChecked = true;
      this.biosCheckMessage = r.message;
      // 两项都通过才认为"看起来正常"；否则标记为可疑（但仍允许启动）
      this.biosCheckSuspicious = !(r.sizeOk && r.signatureOk);
      hilog.info(DOMAIN, TAG, 'checkBios sizeOk=%{public}d sigOk=%{public}d size=%{public}s',
        r.sizeOk ? 1 : 0, r.signatureOk ? 1 : 0, r.sizeText);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'checkBios failed');
    }
  }

  /**
   * 导出诊断日志到 Download（改进 3）。
   *
   * 项目一直缺少反馈通道：用户只能描述现象，而日志里有明确原因。
   */
  private exportLog(): void {
    try {
      const extra: Array<string> = [
		'构建通道: ' + (this.storeBuild ? 'store' : 'development'),
		'执行模式: ' + this.executionMode,
		'性能降级: ' + (this.degraded ? '是' : '否'),
		'降级原因: ' + (this.downgradeReason.length > 0 ? this.downgradeReason : '(无)'),
        '启动阶段: ' + this.statusStage,
        '运行中: ' + (this.statusRunning ? '是' : '否'),
        'JIT 可用: ' + (this.jitAvailable ? '是' : '否'),
        'JIT 阶段: ' + this.jitStage,
        'JIT errno: ' + this.jitErrno.toString(),
        '当前错误: ' + (this.statusError.length > 0 ? this.statusError : '(无)'),
        '错误类别: ' + ErrorHint.kindLabel(this.errorKind as FailKind),
        'BIOS 检查: ' + (this.biosCheckChecked ? this.biosCheckMessage : '(未检查)'),
        // 游戏本体识别：出问题时能直接对照"哪个游戏、哪个 CRC"，
        // 而不用让用户描述（此前排查只能靠用户口述游戏名）。
        '游戏序列号: ' + (this.discSerial.length > 0 ? this.discSerial : '(未启动或无盘)'),
        '游戏标题: ' + (this.discTitle.length > 0 ? this.discTitle : '(无)'),
        '游戏 CRC: ' + (this.discCRC.length > 0 ? this.discCRC : '(无)'),
      ];
      const content = LogExport.build(this.dataRoot(), extra);
      const ctx = getContext(this) as common.UIAbilityContext;
      const saved = LogExport.saveToDownload(ctx, content);
      if (saved.length > 0) {
        this.logExportMessage = '日志已保存到 Download：' + saved.split('/').pop();
      } else {
        this.logExportMessage = '日志保存失败（见 hilog 的 HPS2_CORE）';
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'exportLog failed');
      this.logExportMessage = '日志导出失败：' + err.message;
    }
  }

  /**
   * 检测到蓝牙手柄时的处理。
   *
   * 自动隐藏虚拟按键 —— 接上手柄后屏幕按键只会遮挡画面。
   * 只在首次触发时动作，避免玩家每次按键都改写状态。
   */
  private gamepadSeen: boolean = false;

  private onGamepadConnected(): void {
    if (this.gamepadSeen) {
      return;
    }
    this.gamepadSeen = true;
    if (this.showPad) {
      this.showPad = false;
      hilog.info(DOMAIN, TAG, 'bluetooth gamepad detected -> hid on-screen pad');
    } else {
      hilog.info(DOMAIN, TAG, 'bluetooth gamepad detected');
    }
  }

  /**
   * GameControllerKit receives controller input independently of ArkUI.
   * Consume the matching ArkUI key event at the root before focus traversal,
   * otherwise D-pad/A can also select or activate the FPS floating overlay.
   */
  private consumeNativeGamepadUiKey(event: KeyEvent): boolean {
    if (!this.nativeGamepad || this.viewMode !== 'game') {
      return false;
    }
    const code = event.keyCode;
    const isDpad = code >= 2012 && code <= 2015;
    const isGamepadButton = code >= 2301 && code <= 2315;
    return isDpad || isGamepadButton;
  }

  /** 屏幕可用宽高（surface 未就绪时给安全默认值） */
  private screenW(): number { return this.surfaceW > 0 ? this.surfaceW : 440; }
  private screenH(): number { return this.surfaceH > 0 ? this.surfaceH : 744; }

  /** 悬浮球尺寸 */
  private ballSize(): number { return 56; }

  /**
   * 悬浮球左上角的默认 x（屏幕右侧，留 12 边距）。
   * 尚未拖动过（ballX < 0）时用默认位置。
   */
  private ballLeft(): number {
    if (this.ballX >= 0) {
      return this.ballX;
    }
    return this.screenW() - this.ballSize() - 12;
  }

  /** 悬浮球左上角的默认 y（顶部，避开系统状态栏区域） */
  private ballTop(): number {
    if (this.ballY >= 0) {
      return this.ballY;
    }
    return this.overlayTop();
  }

  /** 更新球位置（拖动中调用，边界钳制后写入） */
  private updateBallPos(x: number, y: number): void {
    this.ballX = x;
    this.ballY = y;
    this.clampBall();
  }

  /**
   * 展开态面板的左上角 x。
   *
   * 【为什么不能直接用球的位置】真机反馈："悬浮球在屏幕边缘时，
   * 点开后无法正常显示"。
   *
   * 根因：clampBall() 只按**球**（56vp）钳制位置，而展开后的面板
   * 宽约 136vp（ballBtnW 最大 120 + 左右 padding 各 8）。
   * 球贴右边缘时 x 可达 616（=672-56），面板右边缘 616+136=752，
   * 超出屏宽 672 达 80vp → 面板被裁掉，按钮点不到。
   *
   * 修法：展开态改为按**面板宽度**重新钳制：
   *   - 默认（球在左侧）：从球的左边缘向右展开；
   *   - 球在右半边：面板向左展开（右边缘对齐球右边缘），
   *     避免溢出屏幕。
   */
  private panelLeft(): number {
    const ballX = this.ballX >= 0 ? this.ballX : this.ballLeft();
    const panelW = this.panelWidth();
    const w = this.screenW();
    const maxLeft = Math.max(0, w - panelW);
    // 球在右半边时向左展开
    const preferLeftEdge = ballX > (w - this.ballSize()) / 2;
    if (preferLeftEdge) {
      const rightAligned = ballX + this.ballSize() - panelW;
      return Math.max(0, Math.min(maxLeft, rightAligned));
    }
    return Math.max(0, Math.min(maxLeft, ballX));
  }

  /** 展开态面板的左上角 y（同样避免超出屏幕下边缘）*/
  private panelTop(): number {
    const ballTop = this.ballY >= 0 ? this.ballY : this.ballTop();
    const h = this.screenH();
    // 面板高度按内容估：状态行 + 6 个按钮 + padding，约 280vp。
    // 这里保守取实际渲染后的钳制：先按可用高度预留，避免底部按钮被裁。
    const panelH = this.panelEstimatedHeight();
    const maxTop = Math.max(0, h - panelH);
    return Math.max(0, Math.min(maxTop, ballTop));
  }

  /** 展开面板的宽度（与 padEditorPanel / 按钮宽度保持一致）*/
  private panelWidth(): number {
    return this.ballBtnW() + 16;   // 左右 padding 各 8
  }

  /** 展开面板的估算高度（用于垂直钳制）*/
  private panelEstimatedHeight(): number {
    // 状态行(约 26) + 6 个按钮(32/28 + space 8) + 上下 padding(16)
    return 26 + 5 * 40 + 36 + 16;
  }

  /**
   * 把球钳制在屏幕内。
   *
   * 为什么要钳：拖动可能越界，导致球部分或完全移出屏幕，
   * 用户再也点不到（也就无法展开功能或退出）。
   * 因此保留至少球体完整可见 —— 这是可用性底线，不是美化。
   */
  private clampBall(): void {
    const size = this.ballSize();
    const w = this.screenW();
    const h = this.screenH();
    const minX = 0;
    const maxX = Math.max(0, w - size);
    const minY = 0;
    const maxY = Math.max(0, h - size);

    let x = this.ballX >= 0 ? this.ballX : this.ballLeft();
    let y = this.ballY >= 0 ? this.ballY : this.ballTop();

    if (x < minX) x = minX;
    if (x > maxX) x = maxX;
    if (y < minY) y = minY;
    if (y > maxY) y = maxY;

    this.ballX = x;
    this.ballY = y;
  }

  /**
   * 切换 MTVU（VU1 独立线程）并持久化。
   *
   * 说明：该设置**下次启动游戏生效**。vu1Thread 在 VU1 重编译器初始化时
   * 创建一次，运行期改这个标志会让已编译的 VU1 代码与新取值不一致，
   * 故不做"立即生效"的承诺。
   */
  private setVuThread(enabled: boolean): void {
    if (this.storeBuild) {
      this.vuThread = false;
      return;
    }
    this.vuThread = enabled;
    try {
      const ok: number = hps2core.setVuThread(enabled);
      hilog.info(DOMAIN, TAG, 'setVuThread(%{public}d) -> %{public}d',
        enabled ? 1 : 0, ok);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'setVuThread failed: %{public}s', err.message);
    }
    // 与上采样共用同一份配置文件
    this.saveVideoSettings(this.upscaleMultiplier);
  }

  /** 悬浮球展开后各按钮的宽度（按屏幕宽度自适应） */
  private ballBtnW(): number {
    // 竖屏窄、横屏宽；给一个合理范围，避免过宽或过窄
    const w = this.surfaceW > 0 ? this.surfaceW : 440;
    return Math.max(88, Math.min(120, w * 0.24));
  }

  /**
   * 退出游戏，回到首页。
   *
   * 【为什么单独抽出来】此前「返回」按钮点击无效 —— 根因在 native：
   * hps2core.stop() 只设了 g_vm_running=false 就 join()，而 VM 线程
   * 正阻塞在 VMManager::Execute() 内（长跑、只在状态变化时返回），
   * 标志设了也无人理会 => join 等不到退出 => UI 线程被阻塞，
   * 点击表现为"没反应"。
   * native 侧已修正（先把 VM 状态置为 Paused 以打断 Execute，
   * 再 join）。此处保持调用顺序清晰，并给出可视化反馈。
   */
  /**
   * 退出游戏，回到首页。
   *
   * 【此前有一个竞态，已修】原实现用 setTimeout(..., 50) 延迟停止，
   * 目的是让"正在停止"提示先绘制出来。但那 50ms 窗口内界面已回到首页、
   * "启动游戏"按钮可点 —— 若用户快速点击启动：
   *     startBios() 时 VM 仍在运行 -> native 直接返回"已在运行"
   *     随后 50ms 到期 -> stopBoot() 把**刚启动的** VM 停掉
   *     => 界面切到游玩页但 VM 已停 => 黑屏/异常
   *
   * 现在改为**先停止、再切页**，并在停止期间用 stopping 标志禁用启动，
   * 从根上消除该窗口。加载提示仍会显示（停止本身很快）。
   */
  private exitGame(): void {
    this.overlayExpanded = false;
    // 停止期间禁止再次启动（配合 UI 上的按钮禁用）
    this.stopping = true;
    this.beginLoading('正在停止模拟器…');
    try {
      this.stopBoot();
    } finally {
      this.endLoading();
      this.stopping = false;
      this.gamePaused = false;
      this.viewMode = 'home';
      // 回首页必须恢复系统栏，否则用户看不到导航条、难以切换应用
      this.setImmersive(false);
      this.setGameOrientation(false);
      // 停止状态轮询：轮询是"游玩时"才需要的能力（FPS/阶段/暂停态），
      // 回首页后 VM 已停止，再每 500ms 调 getStatus 既无意义，
      // 又会持续覆写首页状态（例如把 discTitle 反复刷成空串）。
      this.stopPolling();
    }
  }

  /**
   * 刷新各存档槽状态。
   *
   * 为什么每次打开面板都刷新：存档是后台线程写入的（zip_on_thread），
   * 刚存完可能还没落盘；重新查一次能反映真实情况。
   */
  private refreshSaveSlots(): void {
    try {
      const raw: string = hps2core.listSaveSlots();
      this.saveSlots = JSON.parse(raw) as Array<SaveSlotInfo>;
    } catch (_e) {
      hilog.error(DOMAIN, TAG, 'listSaveSlots failed');
      this.saveSlots = [];
    }
  }

  /** 即时存档到指定槽。 */
  private doSaveState(slot: number): void {
    try {
      const raw: string = hps2core.saveState(slot);
      const r = JSON.parse(raw) as SaveOpResult;
      this.saveMessage = r.message;
      hilog.info(DOMAIN, TAG, 'saveState(%{public}d) ok=%{public}d', slot, r.ok ? 1 : 0);
      // 存档在后台压缩写入，稍后再刷新状态更准确
      setTimeout(() => { this.refreshSaveSlots(); }, 800);
    } catch (e) {
      const err = e as BusinessError;
      this.saveMessage = '存档失败：' + err.message;
      hilog.error(DOMAIN, TAG, 'saveState failed');
    }
  }

  /** 从指定槽读档。 */
  private doLoadState(slot: number): void {
    try {
      const raw: string = hps2core.loadState(slot);
      const r = JSON.parse(raw) as SaveOpResult;
      this.saveMessage = r.message;
      hilog.info(DOMAIN, TAG, 'loadState(%{public}d) ok=%{public}d', slot, r.ok ? 1 : 0);
      this.refreshSaveSlots();
    } catch (e) {
      const err = e as BusinessError;
      this.saveMessage = '读档失败：' + err.message;
      hilog.error(DOMAIN, TAG, 'loadState failed');
    }
  }

  /** 删除指定槽的即时存档（包括上游自动保留的 .backup 文件）。 */
  private doDeleteState(slot: number): void {
    try {
      const raw: string = hps2core.deleteSaveState(slot);
      const r = JSON.parse(raw) as SaveOpResult;
      this.saveMessage = r.message;
      hilog.info(DOMAIN, TAG, 'deleteSaveState(%{public}d) ok=%{public}d', slot, r.ok ? 1 : 0);
      this.refreshSaveSlots();
    } catch (e) {
      const err = e as BusinessError;
      this.saveMessage = '删除存档失败：' + err.message;
      hilog.error(DOMAIN, TAG, 'deleteSaveState failed');
    }
  }

  /** 删除不可恢复，先让用户明确确认槽位，避免误触。 */
  private confirmDeleteState(slot: number): void {
    AlertDialog.show({
      title: '删除即时存档',
      message: `确定删除槽 ${slot} 的存档吗？删除后无法恢复。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: Theme.err(),
        action: () => { this.doDeleteState(slot); }
      }
    });
  }

  private currentMemoryCardGroup(): string {
    if (this.gameName.length === 0) {
      return '未分类';
    }
    return this.gameName.replace(/\s+\([^)]*\)$/, '');
  }

  private loadMemoryCardGroups(): void {
    try {
      const filePath = this.memoryCardGroupsFile();
      if (!fs.accessSync(filePath)) {
        this.memoryCardGroupRecords = [];
        return;
      }
      const raw = fs.readTextSync(filePath);
      this.memoryCardGroupRecords = JSON.parse(raw) as Array<MemoryCardGroupRecord>;
    } catch (e) {
      this.memoryCardGroupRecords = [];
      hilog.error(DOMAIN, TAG, 'load memory card groups failed');
    }
  }

  private saveMemoryCardGroups(): void {
    try {
      const file = fs.openSync(this.memoryCardGroupsFile(),
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(this.memoryCardGroupRecords));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save memory card groups failed');
    }
  }

  private groupNameForCard(cardName: string): string {
    for (const record of this.memoryCardGroupRecords) {
      if (record.cardName === cardName && record.groupName.length > 0) {
        return record.groupName;
      }
    }
    return '未分类';
  }

  private rememberMemoryCardGroup(cardName: string, groupName: string): void {
    const records: Array<MemoryCardGroupRecord> = this.memoryCardGroupRecords.slice();
    let found = false;
    for (const record of records) {
      if (record.cardName === cardName) {
        record.groupName = groupName;
        found = true;
        break;
      }
    }
    if (!found) {
      records.push({ cardName: cardName, groupName: groupName });
    }
    this.memoryCardGroupRecords = records;
    this.saveMemoryCardGroups();
  }

  private removeMemoryCardGroup(cardName: string): void {
    const kept: Array<MemoryCardGroupRecord> = [];
    for (const record of this.memoryCardGroupRecords) {
      if (record.cardName !== cardName) {
        kept.push(record);
      }
    }
    this.memoryCardGroupRecords = kept;
    this.saveMemoryCardGroups();
  }

  private memoryCardGroupOptions(): Array<string> {
    const options: Array<string> = ['全部', '未分类'];
    if (this.gameName.length > 0) {
      const current = this.currentMemoryCardGroup();
      if (!options.includes(current)) options.push(current);
    }
    for (const record of this.memoryCardGroupRecords) {
      if (record.groupName.length > 0 && !options.includes(record.groupName)) {
        options.push(record.groupName);
      }
    }
    return options;
  }

  private visibleMemoryCards(): Array<MemoryCardInfo> {
    if (this.memoryCardGroupFilter === '全部') {
      return this.memoryCards;
    }
    return this.memoryCards.filter((card: MemoryCardInfo) =>
      card.groupName === this.memoryCardGroupFilter);
  }

  private memoryCardDisplayName(name: string): string {
    const lower = name.toLowerCase();
    const suffixes = ['.ps2', '.mcr', '.mcd', '.bin', '.mc2'];
    for (const suffix of suffixes) {
      if (lower.endsWith(suffix)) {
        return name.substring(0, name.length - suffix.length) + '.ps2';
      }
    }
    return name + '.ps2';
  }

  private uniqueMemoryCardPath(fileName: string): string {
    const dir = this.memoryCardsDir();
    let candidate = dir + '/' + fileName;
    if (!fs.accessSync(candidate)) {
      return candidate;
    }
    const dot = fileName.lastIndexOf('.');
    const stem = dot > 0 ? fileName.substring(0, dot) : fileName;
    const suffix = dot > 0 ? fileName.substring(dot) : '.ps2';
    let index = 2;
    while (fs.accessSync(candidate)) {
      candidate = dir + '/' + stem + '-' + index.toString() + suffix;
      index++;
    }
    return candidate;
  }

  private async importMemoryCard(): Promise<void> {
    if (this.memoryCardBusy || this.statusRunning) {
      this.memoryCardMessage = '请先停止模拟器，再导入记忆卡';
      return;
    }
    this.memoryCardBusy = true;
    this.picking = 'memory-card';
    this.memoryCardMessage = '';
    try {
      const ctx = getContext();
      const options = new picker.DocumentSelectOptions();
      options.fileSuffixFilters = ['.ps2', '.PS2', '.mcr', '.MCR', '.mcd', '.MCD',
        '.bin', '.BIN', '.mc2', '.MC2'];
      const docPicker = new picker.DocumentViewPicker(ctx);
      const uris: Array<string> = await docPicker.select(options);
      if (!uris || uris.length === 0) {
        return;
      }

      const srcUri = uris[0];
      const clean = srcUri.split('?')[0];
      const segs = clean.split('/');
      const sourceName = decodeURIComponent(segs[segs.length - 1]) || 'memory-card.ps2';
      const fileName = this.memoryCardDisplayName(sourceName);
      const destPath = this.uniqueMemoryCardPath(fileName);
      let srcFile: fs.File | null = null;
      let dstFile: fs.File | null = null;
      try {
        srcFile = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
        dstFile = fs.openSync(destPath,
          fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.copyFileSync(srcFile.fd, dstFile.fd);
      } finally {
        if (srcFile !== null) fs.closeSync(srcFile);
        if (dstFile !== null) fs.closeSync(dstFile);
      }

      this.refreshMemoryCards();
      const imported = this.memoryCards.some((card: MemoryCardInfo) => card.name === fileName);
      if (!imported) {
        if (fs.accessSync(destPath)) fs.unlinkSync(destPath);
        this.memoryCardMessage = '文件不是可识别的 PS2 记忆卡，已撤销导入';
        return;
      }
      this.rememberMemoryCardGroup(fileName, this.currentMemoryCardGroup());
      this.refreshMemoryCards();
      this.memoryCardMessage = '已导入 ' + fileName + '；文件管理器可继续复制或移动它';
    } catch (e) {
      const err = e as BusinessError;
      this.memoryCardMessage = '导入记忆卡失败：' + (err.message ? err.message : JSON.stringify(e));
      hilog.error(DOMAIN, TAG, 'import memory card failed');
    } finally {
      this.picking = '';
      this.memoryCardBusy = false;
    }
  }

  private async exportMemoryCard(name: string): Promise<void> {
    if (this.memoryCardBusy || this.statusRunning) {
      this.memoryCardMessage = '请先停止模拟器，再导出记忆卡';
      return;
    }
    const sourcePath = this.memoryCardsDir() + '/' + name;
    if (!fs.accessSync(sourcePath)) {
      this.memoryCardMessage = '记忆卡文件已被文件管理器移动或删除，请刷新列表';
      this.refreshMemoryCards();
      return;
    }
    this.memoryCardBusy = true;
    try {
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [name];
      options.fileSuffixChoices = ['PS2 记忆卡|.ps2'];
      const docPicker = new picker.DocumentViewPicker(getContext());
      const uris: Array<string> = await docPicker.save(options);
      if (!uris || uris.length === 0) return;
      const destUri = uris[0];

      let srcFile: fs.File | null = null;
      let dstFile: fs.File | null = null;
      try {
        srcFile = fs.openSync(sourcePath, fs.OpenMode.READ_ONLY);
        dstFile = fs.openSync(destUri,
          fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.copyFileSync(srcFile.fd, dstFile.fd);
      } finally {
        if (srcFile !== null) fs.closeSync(srcFile);
        if (dstFile !== null) fs.closeSync(dstFile);
      }
      this.memoryCardMessage = '已导出 ' + name + '；这是可供其他模拟器读取的原始记忆卡文件';
    } catch (e) {
      const err = e as BusinessError;
      this.memoryCardMessage = '导出记忆卡失败：' + (err.message ? err.message : JSON.stringify(e));
      hilog.error(DOMAIN, TAG, 'export memory card failed');
    } finally {
      this.memoryCardBusy = false;
    }
  }

  private createMemoryCard(sizeMb: number): void {
    if (this.memoryCardBusy || this.statusRunning) {
      this.memoryCardMessage = '请先停止模拟器，再新建记忆卡';
      return;
    }
    const base = 'Mcd001';
    let name = base + '.ps2';
    let index = 2;
    while (this.memoryCards.some((card: MemoryCardInfo) => card.name === name)) {
      name = base + '-' + index.toString() + '.ps2';
      index++;
    }
    try {
      const raw: string = hps2core.createMemoryCard(this.dataRoot(), name, sizeMb);
      const result = JSON.parse(raw) as MemoryCardOpResult;
      this.memoryCardMessage = result.message;
      if (result.ok) {
        this.rememberMemoryCardGroup(name, this.currentMemoryCardGroup());
      }
      this.refreshMemoryCards();
    } catch (e) {
      const err = e as BusinessError;
      this.memoryCardMessage = '新建记忆卡失败：' + (err.message ? err.message : JSON.stringify(e));
      hilog.error(DOMAIN, TAG, 'create memory card failed');
    }
  }

  private confirmDeleteMemoryCard(name: string): void {
    AlertDialog.show({
      title: '删除 PS2 记忆卡',
      message: `确定删除 ${name} 吗？文件管理器中的同一文件也会消失。`,
      autoCancel: true,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '删除',
        fontColor: Theme.err(),
        action: () => {
          try {
            const raw: string = hps2core.deleteMemoryCard(this.dataRoot(), name);
            const result = JSON.parse(raw) as MemoryCardOpResult;
            this.memoryCardMessage = result.message;
            if (result.ok) {
              this.removeMemoryCardGroup(name);
            }
            this.refreshMemoryCards();
          } catch (e) {
            const err = e as BusinessError;
            this.memoryCardMessage = '删除记忆卡失败：' + (err.message ? err.message : JSON.stringify(e));
          }
        }
      }
    });
  }

  private assignMemoryCardToCurrentGame(name: string): void {
    if (this.gameName.length === 0) {
      this.memoryCardMessage = '请先在首页选择游戏，再进行分组';
      return;
    }
    this.rememberMemoryCardGroup(name, this.currentMemoryCardGroup());
    this.refreshMemoryCards();
    this.memoryCardMessage = '已归类到“' + this.currentMemoryCardGroup() + '”';
  }

  private refreshMemoryCards(): void {
    try {
      const dir: string = hps2core.memoryCardsDirectory(this.dataRoot());
      this.memoryCardsDirectory = dir;
      const raw: string = hps2core.listMemoryCards(this.dataRoot(), this.gamePath);
      const listed = JSON.parse(raw) as Array<MemoryCardInfo>;
      this.memoryCards = listed.map((card: MemoryCardInfo) => {
        const storedGroup = this.groupNameForCard(card.name);
        // 只有记忆卡目录中确实存在当前 ISO 的序列号时才自动归类；
        // 空卡、未格式化卡或无法识别序列号的卡继续保持人工管理。
        if (storedGroup === '未分类' && card.matchedGameSerial.length > 0 &&
            this.gameName.length > 0) {
          this.rememberMemoryCardGroup(card.name, this.currentMemoryCardGroup());
          card.groupName = this.currentMemoryCardGroup();
        } else {
          card.groupName = storedGroup;
        }
        return card;
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'list memory cards failed');
      this.memoryCards = [];
    }
  }

  /** 开始一个长任务：显示加载提示。 */
  private beginLoading(text: string): void {
    this.loadingText = text;
    this.loading = true;
  }

  /** 结束长任务：隐藏加载提示。 */
  private endLoading(): void {
    this.loading = false;
    this.loadingText = '';
  }

  private async chooseGame(): Promise<void> {
    // PS2 游戏镜像常见格式。
    // 【改为原地读取，不再复制】见 pickInPlace 的说明 —— 复制 2-4GB 的 ISO
    // 会同步阻塞 UI 线程（外部反馈：卡 8 秒后闪退）。
    const r = await this.pickInPlace('game',
      ['.iso', '.ISO', '.chd', '.CHD', '.bin', '.BIN', '.img', '.IMG', '.gz']);
    if (r.length === 0) {
      this.statusStage = '';
      return;
    }

    const parts = r.split('|');
    const srcPath = parts[0];
    const fileName = parts[1];
    const sizeText = parts[2];

    try {
      // 异步复制到沙箱（native 需要 POSIX 路径）。
      // 关键改进：不再用同步复制，UI 在复制期间保持响应。
      const destPath = await this.copyToSandboxAsync(srcPath, this.gameDir(), fileName);
      this.gamePath = destPath;
      this.gameName = fileName + ' (' + sizeText + ')';
      this.saveGameSelection(destPath, fileName);
      // 新导入的镜像要立刻出现在游戏库里（否则列表要等下次启动才更新）
      this.refreshGames();
      // 选择 ISO 后立即用其真实序列号重扫记忆卡，命中的存档会自动归类。
      this.refreshMemoryCards();
      hilog.info(DOMAIN, TAG, 'game ready in sandbox');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'copy game failed code=%{public}d', err.code);
      this.statusError = '复制游戏文件失败：' + (err.message ? err.message : JSON.stringify(err));
      this.gamePath = '';
      this.gameName = '';
    } finally {
      // 无论成功失败都要收起加载提示，否则界面会一直卡在"载入中"
      this.endLoading();
      this.statusStage = '';
      this.picking = '';
    }
  }

  /** 记住上次选中的游戏（含 URI，便于重启后直接恢复）。 */
  private saveGameSelection(uri: string, displayName: string): void {
    try {
      const file = fs.openSync(this.gameSelectionFile(),
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify({ uri: uri, name: displayName } as GameSelection));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'saveGameSelection failed');
    }
  }

  private gameSelectionFile(): string {
    return this.dataRoot() + '/game_selection.json';
  }

  /**
   * 启动时恢复上次选中的游戏镜像。
   *
   * 【为什么必须有】saveGameSelection() 一直在写这个文件，但**从没有人读** ——
   * "记住上次游戏"是空头承诺：文件在磁盘上，重启后什么都不恢复。
   * 这里补上读取侧，与 restoreBiosSelection() 同一套路数。
   *
   * 容错原则（与 BIOS 恢复一致）：文件缺失 / 损坏 / 镜像已被删，
   * 都只当作"没有上次选择"处理，不阻断启动。
   */
  private restoreGameSelection(): void {
    try {
      const marker = this.gameSelectionFile();
      if (!fs.accessSync(marker)) {
        return;
      }
      const raw = fs.readTextSync(marker);
      if (!raw || raw.length === 0) {
        return;
      }
      const selection = JSON.parse(raw) as GameSelection;
      const path = selection.uri;
      if (!path || path.length === 0) {
        return;
      }
      // 镜像可能已被删除或移走 —— 静默忽略，不打断启动。
      if (!fs.accessSync(path)) {
        hilog.info(DOMAIN, TAG, 'saved game image is gone, ignoring selection');
        return;
      }
      let displayName = selection.name || '';
      if (displayName.length === 0) {
        // 旧文件可能只存了路径，用文件名兜底
        const slash = path.lastIndexOf('/');
        displayName = slash >= 0 ? path.substring(slash + 1) : path;
      }
      this.gamePath = path;
      this.gameName = displayName;
      hilog.info(DOMAIN, TAG, 'restored game selection');
    } catch (e) {
      // 坏文件：当作没有上次选择，不影响启动
      hilog.error(DOMAIN, TAG, 'restore game selection failed');
    }
  }

  private clearGame(): void {
    this.gamePath = '';
    this.gameName = '';
    // 【必须同时删掉持久化记录】否则下次启动 restoreGameSelection()
    // 会把用户刚清掉的游戏又恢复回来。
    try {
      const marker = this.gameSelectionFile();
      if (fs.accessSync(marker)) {
        fs.unlinkSync(marker);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'clearGame: remove selection failed');
    }
  }

  /**
   * 刷新游戏库列表。
   *
   * 【为什么必须判 VM 状态】native 侧扫描走 CDVD 打开镜像读取 ELF 头，
   * 上游在 GameList.h:116 明确警告"运行中调用会破坏 CDVD 状态"。
   * 故运行中直接跳过（列表保持上次内容），而不是硬扫。
   */
  private refreshGames(): void {
    if (this.statusRunning) {
      hilog.info(DOMAIN, TAG, 'refreshGames skipped: VM is running');
      return;
    }
    this.gamesScanning = true;
    try {
      const raw: string = hps2core.listGames(this.gameDir());
      const list = JSON.parse(raw) as Array<GameEntry>;
      // 按标题（无标题则文件名）排序，让列表稳定可预期
      list.sort((a: GameEntry, b: GameEntry) => {
        const ka = (a.title && a.title.length > 0 ? a.title : a.name).toLowerCase();
        const kb = (b.title && b.title.length > 0 ? b.title : b.name).toLowerCase();
        return ka < kb ? -1 : (ka > kb ? 1 : 0);
      });
      this.games = list;
      hilog.info(DOMAIN, TAG, 'listGames -> %{public}d item(s)', list.length);
      // 列表变了，本地封面表也要重算（否则新导入的游戏没有封面）
      this.refreshLocalCovers();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'listGames failed');
      this.games = [];
    } finally {
      this.gamesScanning = false;
    }
  }

  // ===================== 逐游戏设置 =====================

  /**
   * 打开某游戏的独立设置面板。
   *
   * 【为什么需要单独读一次】值来自该游戏的 INI 文件，与全局设置是两套。
   * native 侧读取时要扫描镜像取 serial/CRC（重 IO），故只在打开时读一次，
   * 结果存在 @State 里，面板重绘不重复扫描。
   */
  private openPerGameSettings(g: GameEntry): void {
    if (this.statusRunning) {
      this.statusError = '游戏运行中无法修改设置，请先返回。';
      return;
    }
    if (g.invalid || !g.serial || g.serial.length === 0) {
      this.statusError = '该镜像未被识别，无法使用逐游戏设置。';
      return;
    }
    this.perGameTarget = g;
    this.perGameMessage = '';
    this.perGame = null;
    try {
      const raw: string = hps2core.readGameSettings(g.path);
      const st = JSON.parse(raw) as PerGameSettings;
      if (!st.ok) {
        this.perGameMessage = '读取该游戏的设置失败（见日志）。';
        return;
      }
      this.perGame = st;
      hilog.info(DOMAIN, TAG, 'readGameSettings ok hasFile=%{public}d', st.hasFile ? 1 : 0);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'readGameSettings failed');
      this.perGameMessage = '读取设置失败。';
    }
  }

  private closePerGameSettings(): void {
    this.perGameTarget = null;
    this.perGame = null;
    this.perGameMessage = '';
  }

  /**
   * 写入一项逐游戏设置。
   *
   * value 传 null 表示"删除该覆盖、回退全局" —— 这是本功能的核心语义：
   * 用户应当能明确表达"这一项我不管，用全局的"。
   */
  private writePerGameSetting(key: string, value: number | boolean | null): void {
    const target = this.perGameTarget;
    if (target === null) {
      return;
    }
    let payload = '{';
    if (value === null) {
      payload += '"' + key + '":null';
    } else if (typeof value === 'boolean') {
      payload += '"' + key + '":' + (value ? 'true' : 'false');
    } else {
      payload += '"' + key + '":' + value.toString();
    }
    payload += '}';

    try {
      const raw: string = hps2core.writeGameSettings(target.path, payload);
      const r = JSON.parse(raw) as SaveOpResult;
      this.perGameMessage = r.message;
      // 把失败原因也打进日志 —— 只在 UI 上显示的话，排查时拿不到
      hilog.info(DOMAIN, TAG, 'writeGameSettings ok=%{public}d msg=%{public}s',
        r.ok ? 1 : 0, r.message ? r.message : '');
      if (r.ok) {
        // 重新读回，让面板显示真实落盘结果（而不是我们以为写进去的值）
        this.openPerGameSettings(target);
        this.perGameMessage = r.message;
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'writeGameSettings failed');
      this.perGameMessage = '保存失败。';
    }
  }

  /** 面板显示用的"当前有效值"：有覆盖用覆盖值，否则回退全局设置 */
  private effectiveAspect(): number {
    const pg = this.perGame;
    if (pg !== null && pg.aspectSet) {
      return pg.aspect;
    }
    return this.aspectMode;
  }

  private effectiveUpscale(): number {
    const pg = this.perGame;
    if (pg !== null && pg.upscaleSet && pg.upscale > 0) {
      return Math.round(pg.upscale);
    }
    return this.upscaleMultiplier;
  }

  private effectiveVuThread(): boolean {
    const pg = this.perGame;
    if (pg !== null && pg.vuThreadSet) {
      return pg.vuThread;
    }
    return this.vuThread;
  }

  // ===================== 封面 =====================

  /** 封面目录（与 native 的 EmuFolders::Covers 一致：<dataRoot>/covers）*/
  private coversDir(): string {
    return this.dataRoot() + '/covers';
  }

  /**
   * 上游按 "serial → 文件标题 → 标题" 的顺序在 covers/ 里找图
   * （GameList::GetCoverImagePathForEntry）。本地查找要照同一套，
   * 否则会出现"下载成功了但界面不显示"。
   */
  private findLocalCover(g: GameEntry): string {
    const exts: Array<string> = ['.jpg', '.jpeg', '.png', '.webp'];
    const dir = this.coversDir();
    const fileTitle = g.name.replace(/\.[^.]+$/, '');
    // 候选名按上游优先级排列；去重避免同一名字查两遍
    const cands: Array<string> = [];
    if (fileTitle.length > 0 && fileTitle !== g.title) {
      cands.push(fileTitle);
    }
    if (g.serial && g.serial.length > 0) {
      cands.push(g.serial);
    }
    if (g.title && g.title.length > 0) {
      cands.push(g.title);
    }
    if (g.titleEn && g.titleEn.length > 0) {
      cands.push(g.titleEn);
    }
    for (const ext of exts) {
      for (const c of cands) {
        const sanitized = c.replace(/[\\/:*?"<>|]/g, '_');
        const p = dir + '/' + sanitized + ext;
        try {
          if (fs.accessSync(p)) {
            return p;
          }
        } catch (e) {
          // 不存在即继续
        }
      }
    }
    return '';
  }

  /** 为游戏库里每个条目解析本地封面（同步、只是查文件是否存在）*/
  private refreshLocalCovers(): void {
    const next: Map<string, string> = new Map();
    for (const g of this.games) {
      const p = this.findLocalCover(g);
      if (p.length > 0) {
        next.set(g.path, p);
      }
    }
    this.coverPaths = next;
  }

  /**
   * 用当前选中的封面源为一款游戏下载封面。
   *
   * 【设计取舍】
   *   - 串行逐个下载：并发会打满小水管，且失败时难以归因
   *   - 失败不阻断：无网/源不可用时只记录说明，不影响游戏运行
   *   - 只按 serial 命名保存（上游最通用的查找方式）
   *   - 下载完立刻刷新本地封面表，界面即时可见
   */
  private async downloadCoverFor(g: GameEntry): Promise<boolean> {
    const src: CoverSource | null = SharedCoverSources.store.current();
    if (src === null) {
      this.coverMessage = '没有可用的封面源，请在「封面源」里启用或添加一个。';
      return false;
    }
    if (!g.serial || g.serial.length === 0) {
      this.coverMessage = '这款游戏未能识别序列号，无法按 serial 查找封面。';
      return false;
    }

    const url = buildCoverUrl(src.urlTemplate, g.serial, g.title, g.name.replace(/\.[^.]+$/, ''));
    hilog.info(DOMAIN, TAG, 'cover download start via %{public}s', src.id);

    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 10000,
        readTimeout: 20000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
      });
      if (resp.responseCode !== 200) {
        this.coverMessage = `下载失败：HTTP ${resp.responseCode}（源：${src.name}）`;
        hilog.warn(DOMAIN, TAG, 'cover HTTP %{public}d', resp.responseCode);
        return false;
      }
      const buf = resp.result as ArrayBuffer;
      if (!buf || buf.byteLength === 0) {
        this.coverMessage = `下载失败：内容为空（源：${src.name}）`;
        return false;
      }

      // 目录可能还不存在（首次运行）
      try {
        if (!fs.accessSync(this.coversDir())) {
          fs.mkdirSync(this.coversDir());
        }
      } catch (e) {
        // 已存在
      }

      // 统一存成 .jpg：上游按扩展名探测，且封面库给的就是 jpg
      const dest = this.coversDir() + '/' + g.serial + '.jpg';
      const file = fs.openSync(dest,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, buf);
      } finally {
        fs.closeSync(file);
      }
      hilog.info(DOMAIN, TAG, 'cover saved for %{public}s', g.serial);
      this.coverMessage = `已下载封面：${libGameTitle(g)}`;
      return true;
    } catch (e) {
      const err = e as BusinessError;
      // 网络类失败最常见（无网 / 源被墙 / 超时），如实说明而不是笼统"失败"
      this.coverMessage = `下载失败：${err.message ? err.message : JSON.stringify(e)}（源：${src.name}）`;
      hilog.error(DOMAIN, TAG, 'cover download failed');
      return false;
    } finally {
      req.destroy();
    }
  }

  /** 标记封面源配置已变更，触发界面重绘 */
  private bumpCoverSources(): void {
    this.coverSourceVersion++;
  }

  /** 当前选中的源 id（供单选按钮判断勾选态；复用 current() 的回退逻辑）*/
  private currentCoverSourceId(): string {
    const src = SharedCoverSources.store.current();
    return src === null ? '' : src.id;
  }

  /** 全部可用源（供面板渲染；读一次 coverSourceVersion 建立依赖）*/
  private coverSourceList(): Array<CoverSource> {
    const v = this.coverSourceVersion;
    if (v < 0) {
      // 不可达分支，仅为让编译器保留上面的读取
      console.info('unreachable');
    }
    return SharedCoverSources.store.all();
  }

  /** 内置源列表（面板里单独一组，支持启停）*/
  private builtinCoverSources(): Array<CoverSource> {
    return BUILTIN_COVER_SOURCES;
  }

  private selectCoverSource(id: string): void {
    SharedCoverSources.store.select(id);
    SharedCoverSources.store.save(this.dataRoot());
    this.bumpCoverSources();
  }

  private toggleBuiltinCoverSource(id: string, enabled: boolean): void {
    SharedCoverSources.store.setBuiltinEnabled(id, enabled);
    SharedCoverSources.store.save(this.dataRoot());
    this.bumpCoverSources();
  }

  private isBuiltinCoverEnabled(id: string): boolean {
    return SharedCoverSources.store.isBuiltinEnabled(id);
  }

  private addCustomCoverSource(): void {
    const err = SharedCoverSources.store.addCustom(this.newSourceName, this.newSourceUrl);
    if (err.length > 0) {
      this.newSourceError = err;
      return;
    }
    SharedCoverSources.store.save(this.dataRoot());
    this.newSourceName = '';
    this.newSourceUrl = '';
    this.newSourceError = '';
    this.bumpCoverSources();
  }

  private removeCustomCoverSource(id: string): void {
    if (SharedCoverSources.store.removeCustom(id)) {
      SharedCoverSources.store.save(this.dataRoot());
      this.bumpCoverSources();
    }
  }

  /** 当前封面源的显示名（未配置时返回空串）*/
  private currentCoverSourceName(): string {
    const src = SharedCoverSources.store.current();
    return src === null ? '' : src.name;
  }

  /** 为单个游戏下载封面（列表行内按钮）*/
  private async downloadOneCover(g: GameEntry): Promise<void> {
    const busy = new Set(this.coverBusy);
    busy.add(g.path);
    this.coverBusy = busy;
    await this.downloadCoverFor(g);
    const after = new Set(this.coverBusy);
    after.delete(g.path);
    this.coverBusy = after;
    this.refreshLocalCovers();
  }

  /** 为列表里**所有缺封面**的游戏逐个下载 */
  private async downloadMissingCovers(): Promise<void> {
    const todo: Array<GameEntry> = [];
    for (const g of this.games) {
      if (g.invalid || !g.serial || g.serial.length === 0) {
        continue;
      }
      if (this.findLocalCover(g).length > 0) {
        continue;
      }
      todo.push(g);
    }
    if (todo.length === 0) {
      this.coverMessage = '所有已识别的游戏都已有封面。';
      return;
    }

    let ok = 0;
    let fail = 0;
    for (const g of todo) {
      // 每项标记 busy，让界面能看出进度
      const busy = new Set(this.coverBusy);
      busy.add(g.path);
      this.coverBusy = busy;

      const done = await this.downloadCoverFor(g);
      if (done) {
        ok++;
      } else {
        fail++;
      }

      const after = new Set(this.coverBusy);
      after.delete(g.path);
      this.coverBusy = after;
    }

    this.refreshLocalCovers();
    this.coverMessage = `封面下载完成：成功 ${ok}，失败 ${fail}。`;
  }

  /** 从游戏库选中一项作为当前游戏（不复制 —— 它已经在沙箱里了）。*/
  private selectGameFromLibrary(g: GameEntry): void {
    if (this.statusRunning) {
      this.statusError = '游戏运行中无法更换，请先返回。';
      return;
    }
    this.gamePath = g.path;
    // 显示名与"从选择器导入"保持同一形态：文件名 (大小)
    this.gameName = g.name + ' (' + libHumanSize(g.size) + ')';
    this.saveGameSelection(g.path, this.gameName);
    this.clearError();
    // 换了镜像，记忆卡的"匹配当前游戏"要重算
    this.refreshMemoryCards();
    hilog.info(DOMAIN, TAG, 'game selected from library');
  }





  private async startBoot(): Promise<void> {
    // 停止过程中不允许启动 —— 否则会出现"刚启动就被停掉"的竞态
    if (this.stopping) {
      this.statusError = '正在停止上一次运行，请稍候再启动。';
      return;
    }
    // ---------------------------------------------------------------------
    // 启动进行中不允许重入。
    //
    // 【为什么必须有】startBoot 是 async，中间有 await setGameOrientation()。
    // 在那之前/之后的空隙里，第二次点击也能走到 hps2core.startBios()。
    // 而 native 侧那次调用会写 s_data_root/s_game_path 等**非原子全局
    // string**，同时上一轮的 VM 线程可能正在读它们 → use-after-free。
    //
    // 按钮上本来有 `.enabled(... && !this.busy)`，但 busy 从未被置位，
    // 守卫是空的。这里真正把它用起来（并在 finally 里复位）。
    // ---------------------------------------------------------------------
    if (this.busy) {
      hilog.info(DOMAIN, TAG, 'startBoot ignored: already starting');
      return;
    }
    if (!this.biosPath) {
      this.statusError = '请先选择 BIOS 文件';
      return;
    }

    // 只有开发构建把 JIT 自检作为启动门禁。商店构建的
    // policy-disabled 是预期状态，应继续进入解释器兼容模式。
    if (!this.storeBuild && this.jitChecked && !this.jitAvailable) {
      this.setError(`JIT 不可用，已拒绝启动。${this.jitMessage}`);
      return;
    }

    this.clearError();
    this.busy = true;
    try {
      // 先锁定窗口方向，再启动 GS，避免 VM 已开始渲染后才发生旋转。
      await this.setGameOrientation(true);
      const ok: number = hps2core.startBios(this.dataRoot(), this.biosDir(), this.gamePath);
      hilog.info(DOMAIN, TAG, 'startBios returned %{public}d', ok);
      if (ok !== 1) {
        this.setError('核心启动被拒绝，详见日志（tag=HPS2_CORE）');
      }
      // 启动成功后只**挂载**虚拟手柄，不做按键映射。
      //
      // 映射必须等 VM 初始化完成（输入源懒创建）——
      // 那段逻辑已移到 native 的 VM 线程里（napi_init.cpp 的 VMThreadMain，
      // 在 VMManager::Initialize() 之后），因为在那之前调用会让
      // InputManager::GetGenericBindingMapping() 解引用空指针而闪退。
      this.setupVirtualPad();

      // 启动被拒绝：留在首页显示错误，不切页面。
      if (ok !== 1) {
        this.syncJitFromStatus();
        return;
      }

      // 启动成功 —— 切到全屏游玩页。
      //
      // 【此前遗漏】viewMode 从未被设为 'game'，所以点了启动后 VM 起来了、
      // 虚拟手柄也挂上了，但界面仍停在首页 —— 用户看到的是"点了没反应"。
      // 现在按 startBios 的返回值决定是否切页。
      this.viewMode = 'game';
      // 进入游玩页：隐藏系统导航条等系统栏，让画面占满全屏。
      // （用户反馈：全屏时下方的小横条不隐藏，既遮挡画面也易误触。）
      this.setImmersive(true);

      // 启动后刷新一次 JIT 状态：native 的硬门禁可能刚判过一次。
      this.syncJitFromStatus();
      this.startPolling();
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'startBios exception');
      this.statusError = '调用核心失败：' + err.message;
    } finally {
      // 无论成功、被拒绝还是抛异常，都要解锁重入守卫，
      // 否则一次失败会让"启动"按钮永久失效。
      this.busy = false;
    }
  }

  private async setGameOrientation(inGame: boolean): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      await Immersive.setGameOrientation(inGame, ctx);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'setGameOrientation(%{public}d) failed: %{public}s',
        inGame ? 1 : 0, err.message);
    }
  }

  /**
   * 从 getStatus() 同步 JIT 状态。
   *
   * 为什么需要：运行期看门狗发现 JIT 失效时会停机并写入 jitMessage，
   * UI 必须把它显示出来（否则用户只看到"未运行"，不知道原因）。
   */
  private syncJitFromStatus(): void {
    try {
      const raw: string = hps2core.getStatus();
      const st = JSON.parse(raw) as BootStatus;
	  this.storeBuild = st.storeBuild === true;
	  this.executionMode = st.executionMode || 'unknown';
	  this.degraded = st.degraded === true;
	  this.downgradeReason = st.downgradeReason || '';
      if (st.jitStage) {
        this.jitChecked = true;
        this.jitAvailable = st.jitAvailable;
        this.jitMessage = st.jitMessage;
        this.jitAction = st.jitAction;
        this.jitStage = st.jitStage;
        this.jitErrno = st.jitErrno;
        try {
          const diag = JSON.parse(st.jitDiagnostics) as JitCheckResult;
          this.jitDiagnostics = this.formatJitDiagnostics(diag);
        } catch (e) {
          this.jitDiagnostics = st.jitDiagnostics || '{}';
        }
      }
    } catch (e) {
      // 状态解析失败不刷屏
    }
  }

  /*
   * 准备虚拟手柄：挂载 SDL 虚拟手柄 + 为手柄端口 0 做自动映射。
   *
   * 为什么需要自动映射：PCSX2 的 Pad 没有内置按键绑定表
   * （Pad::SetDefaultControllerConfig 只设置手柄类型，不生成按键绑定），
   * 绑定必须由前端提供。上游的现成做法是用通用映射自动绑定：
   *   Pad::MapController(si, port, InputManager::GetGenericBindingMapping(device));
   * 见 FullscreenUI_Settings.cpp:1581。
   *
   * native 侧已封装为 initVirtualPad() / mapVirtualPad(port)。
   */
  private setupVirtualPad(): void {
    try {
      const init: number = hps2core.initVirtualPad();
      hilog.info(DOMAIN, TAG, 'initVirtualPad -> %{public}d', init);
      if (init !== 1) {
        this.statusError = '虚拟手柄初始化失败（见 HPS2_VPAD 日志）';
        return;
      }
      this.nativeGamepad = hps2core.hasOfficialGamepad() === 1;
      hilog.info(DOMAIN, TAG, 'native GameControllerKit input=%{public}d', this.nativeGamepad ? 1 : 0);
      // 按键映射不在这里做 —— 见上方注释。native 会在 VM 初始化完成后
      // 自行映射到端口 0（1P）。
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'setupVirtualPad failed: %{public}s', JSON.stringify(err));
      this.statusError = '虚拟手柄准备失败：' + err.message;
    }
  }

  private startPolling(): void {
    this.stopPolling();
    this.timerId = setInterval(() => this.refreshStatus(), 500);
  }

  /**
   * 停止状态轮询。
   *
   * 必须在"离开游玩态"与"页面销毁"时调用 —— 否则定时器会一直
   * 持有 this 并每 500ms 调一次 native：页面已不可见却仍在写状态，
   * 也会让首页的 discTitle/statusStage 之类的值被反复覆写。
   */
  private stopPolling(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private refreshStatus(): void {
    try {
      const raw: string = hps2core.getStatus();
      const st = JSON.parse(raw) as BootStatus;
	  this.storeBuild = st.storeBuild === true;
	  this.executionMode = st.executionMode || 'unknown';
	  this.degraded = st.degraded === true;
	  this.downgradeReason = st.downgradeReason || '';
      this.statusStage = st.stageName;
      this.statusRunning = st.running;
      this.gamePaused = st.paused === true;
      this.gameFps = st.fps > 0 ? st.fps : 0;
      // 游戏本体识别：native 未启动时给空串，这里原样同步即可
      // （不清空为 undefined，避免 ArkTS 把 undefined 当字符串用）。
      this.discSerial = st.discSerial || '';
      this.discTitle = st.discTitle || '';
      this.discCRC = st.discCRC || '';
      // native 上报的错误也走分类，保证建议一致
      if (st.error && st.error.length > 0) {
        this.setError(st.error);
      }
    } catch (e) {
      // 轮询失败不刷屏
    }
  }

  /** 画面比例选项的显示名 */
  private aspectLabel(m: number): string {
    if (m === 0) return '自动（横屏铺满 / 竖屏 4:3）';
    if (m === 1) return '保持 4:3（不变形）';
    if (m === 2) return '铺满屏幕（可能变形）';
    return '宽屏 16:9';
  }

  private upscaleLabel(m: number): string {
    if (m === 1) return '原生分辨率（1x）';
    return m + 'x 内部渲染';
  }

  private runningLabel(): string {
    if (this.gamePaused) return '已暂停';
    if (this.gameFps <= 0) return '运行中';
    return '运行中  ' + (Math.round(this.gameFps * 10) / 10) + ' FPS';
  }

  /** 切换游戏暂停状态；VM 保持在内存中，恢复后从当前帧继续。 */
  private toggleGamePause(): void {
    if (!this.statusRunning || this.stopping) {
      return;
    }
    const target = !this.gamePaused;
    try {
      const ok: number = hps2core.setPaused(target);
      if (ok !== 1) {
        this.statusError = target ? '暂停失败：当前没有可用的游戏核心。' :
          '继续失败：当前没有可用的游戏核心。';
        return;
      }
      this.gamePaused = target;
      hilog.info(DOMAIN, TAG, 'setPaused(%{public}d) accepted', target ? 1 : 0);
    } catch (e) {
      const err = e as BusinessError;
      this.statusError = (target ? '暂停失败：' : '继续失败：') + err.message;
      hilog.error(DOMAIN, TAG, 'setPaused failed: %{public}s', err.message);
    }
  }

  /**
   * 设置画面比例，下一次启动游戏时生效。
   *
   * native 侧会把值写入启动配置；不在 ArkUI 线程直接调用 MTGS，避免
   * 运行中的渲染器重配置造成闪退。
   */
  private setAspect(m: number): void {
    this.aspectMode = m;
    try {
      const ok: number = hps2core.setAspectMode(m);
      hilog.info(DOMAIN, TAG, 'setAspectMode(%{public}d) -> %{public}d', m, ok);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'setAspectMode failed: %{public}s', err.message);
    }
  }

  private setUpscale(m: number): void {
    try {
      const ok: number = hps2core.setUpscaleMultiplier(m);
      if (ok === 1) {
        this.upscaleMultiplier = m;
        this.saveVideoSettings(m);
      }
      hilog.info(DOMAIN, TAG, 'setUpscaleMultiplier(%{public}f) -> %{public}d', m, ok);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'setUpscaleMultiplier failed: %{public}s', err.message);
    }
  }

  /** 保存视频设置；倍率在应用重启后仍应保持。 */
  private saveVideoSettings(multiplier: number): void {
    try {
      const file = fs.openSync(this.videoSettingsFile(),
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        const settings: VideoSettingsSelection = {
          upscaleMultiplier: multiplier,
          vuThread: this.vuThread
        };
        fs.writeSync(file.fd, JSON.stringify(settings));
      } finally {
        fs.closeSync(file);
      }
      hilog.info(DOMAIN, TAG, 'saved video settings upscale=%{public}f', multiplier);
    } catch (e) {
      // 本次运行已经应用成功；持久化失败只记录，不阻止游戏启动。
      hilog.error(DOMAIN, TAG, 'save video settings failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 应用启动时恢复视频设置，并同步到 native 的启动配置。 */
  private restoreVideoSettings(): void {
    try {
      const marker = this.videoSettingsFile();
      if (!fs.accessSync(marker)) {
        return;
      }

      const raw = fs.readTextSync(marker);
      const settings = JSON.parse(raw) as VideoSettingsSelection;
      const multiplier = settings.upscaleMultiplier;
      // 当前 UI 提供 1x/2x/3x；拒绝损坏文件或未来写入的越界值。
      if (multiplier !== 1 && multiplier !== 2 && multiplier !== 3) {
        hilog.error(DOMAIN, TAG, 'ignored invalid saved upscale=%{public}f', multiplier);
        return;
      }

      // 恢复 MTVU（旧配置文件可能没有该字段 -> 保持默认 false）
      if (settings.vuThread === true) {
        const vuOk: number = hps2core.setVuThread(true);
        if (vuOk === 1) {
          this.vuThread = true;
          hilog.info(DOMAIN, TAG, 'restored MTVU=enabled');
        }
      }

      const ok: number = hps2core.setUpscaleMultiplier(multiplier);
      if (ok === 1) {
        this.upscaleMultiplier = multiplier;
        hilog.info(DOMAIN, TAG, 'restored video settings upscale=%{public}f', multiplier);
      } else {
        hilog.error(DOMAIN, TAG, 'restore video settings rejected upscale=%{public}f', multiplier);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'restore video settings failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 枚举 SDL 能识别的**真实手柄**（备用路径）。
   *
   * 【主备关系（用户已确认以 ArkUI 事件方案为准）】
   *   主方案：components/GamepadCatcher 监听系统 KeyEvent/FocusAxisEvent
   *           —— 不依赖 SDL 能否发现设备
   *   备用  ：本函数（SDL 枚举）
   *
   * 为何保留备用：SDL 在本项目的自编译配置中**没有 evdev 后端**
   * （SDL_JOYSTICK_LINUX 未定义），只启用 HIDAPI，而后端依赖
   * /dev/hidraw*（真机实测不存在）与 udev（OHOS 无）。
   * 因此本路径**很可能枚举不到任何设备** —— 但它成本为零，
   * 且若某个手柄恰好被 SDL 识别，多一条可用路径没有坏处。
   * UI 上只作为进阶选项展示，主流程指引用户直接用（主方案自动生效）。
   */
  private refreshControllers(): void {
    try {
      const raw: string = hps2core.enumerateControllers();
      const parsed = JSON.parse(raw) as Array<ControllerDescriptor>;
      const devices: Array<ControllerInfo> = [];
      for (const item of parsed) {
        devices.push({ id: item.id, name: item.name, mapped: false });
      }
      this.controllerDevices = devices;
      this.controllerStatus = devices.length > 0 ?
        '已发现 ' + devices.length + ' 个手柄' :
        (this.statusRunning ? '未发现已被模拟器识别的手柄' : '请先启动游戏，再刷新手柄列表');
      hilog.info(DOMAIN, TAG, 'enumerate controllers count=%{public}d', devices.length);
    } catch (e) {
      const err = e as BusinessError;
      this.controllerDevices = [];
      this.controllerStatus = '手柄列表读取失败：' + err.message;
      hilog.error(DOMAIN, TAG, 'enumerate controllers failed: %{public}s', JSON.stringify(e));
    }
  }

  private mapController(device: ControllerInfo): void {
    try {
      const ok: number = hps2core.mapController(device.id, 0);
      if (ok === 1) {
        const updated: Array<ControllerInfo> = [];
        for (const item of this.controllerDevices) {
          updated.push({ id: item.id, name: item.name, mapped: item.id === device.id });
        }
        this.controllerDevices = updated;
        this.controllerStatus = device.name + ' 已映射到 1P（本次运行有效）';
      } else {
        this.controllerStatus = '映射失败，请确认手柄已连接并重新刷新';
      }
    } catch (e) {
      const err = e as BusinessError;
      this.controllerStatus = '映射失败：' + err.message;
      hilog.error(DOMAIN, TAG, 'map controller failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 开关沉浸式全屏（隐藏/恢复系统栏）。
   *
   * 用户反馈「全屏时下方的小横条不会隐藏」—— 那是系统导航条。
   * 实现见 common/Immersive.ets；此处只负责在模式切换时调用。
   */
  private setImmersive(enable: boolean): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      Immersive.set(enable, ctx);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'setImmersive(%{public}d) failed: %{public}s',
        enable ? 1 : 0, err.message);
    }
  }

  /**
   * 顶部运行提示栏的安全起始位置。
   *
   * VirtualPad 的 L1/L2/R1/R2 使用顶部区域：横屏贴近顶部，竖屏位于
   * 4:3 画面上方黑边的中部。提示栏不能继续固定在右上角，否则会覆盖
   * R1/R2 的触控区域。这里把提示栏放到肩键行的下方，同时保留 Row
   * 自身的 10vp 内边距。
   */
  private overlayTop(): number {
    if (this.surfaceW <= 0 || this.surfaceH <= 0) {
      // surface 尺寸尚未回调时，先避开横屏肩键的顶部区域。
      return 38;
    }

    if (this.surfaceH > this.surfaceW) {
      // 竖屏 4:3 内容上边界；提示栏放在肩键行下方，尽量仍留在黑边。
      const contentTop: number = (this.surfaceH - this.surfaceW * 0.75) / 2;
      return Math.max(0, contentTop - 54);
    }

    // 横屏黑边不足，肩键贴顶，提示栏放在其下方。
    return 38;
  }

  private stopBoot(): void {
    try {
      hps2core.stop();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'stop failed: %{public}s', JSON.stringify(e));
    }
    this.refreshStatus();
  }

  /*
   * JIT 能力状态面板。
   *
   * 为什么必须在界面上显著展示：本产品**不做降级** —— JIT 不可用时
   * 应用无法运行（PS2 模拟在解释器下没有意义）。因此用户必须在启动前
   * 就知道当前能不能跑、不能跑该怎么办，而不是点了启动收到一个失败。
   */

  build() {
    Stack() {
      // =====================================================================
      // 【关键】GameScreen（含 XComponent）**始终挂载**，不随页面模式切换。
      //
      // 为什么必须这样 —— 这是一个真实的竞态，我最初的两态设计引入了它：
      //   GS 初始化时会经 GSDevice::AcquireWindow()（GSDevice.cpp:472）
      //   调 Host::AcquireRenderWindow() 拿渲染窗口。若那一刻 XComponent
      //   尚未挂载，窗口拿不到，GS 只能以 Surfaceless 打开，无法出画面。
      //   而 startBios() 会立刻触发 VM 线程去初始化 GS —— 若此时才切页
      //   让 XComponent 挂载，两者就是竞态。
      //
      // 让 XComponent 常驻则从根本上消除该依赖：surface 自应用启动就存在，
      // GS 任何时刻来拿都有。旧前端也是这个形态（XComponent 一直在树上），
      // 所以它没暴露过这个问题。
      //
      // 首页只作为**叠加层**盖在画面之上，见下方。
      // =====================================================================
      GameScreen({
        playing: this.viewMode === 'game',
        showPad: this.showPad,
        nativeGamepad: this.nativeGamepad,
        padEditMode: this.padEditMode,
        padStyleIndex: this.padStyleIndex,
        onPadGroupDragged: (g: PadGroup, dx: number, dy: number) => {
          this.handlePadGroupDragged(g, dx, dy);
        },
        onPadDragEnd: () => { this.handlePadDragEnd(); },
        onSurfaceSize: (w: number, h: number) => {
          // -----------------------------------------------------------------
          // 【为什么必须在尺寸变化时重新同步布局】
          //
          // padStore 里横竖屏各存一套偏移。方向一变（尤其内屏⇄外屏
          // 这种同时改变尺寸与方向的情况），必须重新取对应变体，
          // 否则会**继续沿用旧方向的偏移** —— 真机现象就是
          // "展开切到折叠后虚拟按键完全错位"。
          //
          // 此前只在拖动与启动时同步，遗漏了这里。
          // -----------------------------------------------------------------
          const wasLandscape = this.surfaceW > this.surfaceH;
          this.surfaceW = w;
          this.surfaceH = h;
          const nowLandscape = w > h;
          if (wasLandscape !== nowLandscape) {
            hilog.info(DOMAIN, TAG,
              'surface orientation changed: %{public}s -> %{public}s, re-sync pad layout',
              wasLandscape ? 'landscape' : 'portrait',
              nowLandscape ? 'landscape' : 'portrait');
            this.syncPadLayoutFromStore();
          }
        },
        // 首次检测到蓝牙手柄 → 自动隐藏虚拟按键。
        // 理由：玩家接上手柄就不需要屏幕按键了，留着反而遮挡画面。
        // 用户仍可在设置里手动打开（showPad 开关保留）。
        onGamepadDetected: () => { this.onGamepadConnected(); }
      })

      // ---- 首页叠加层 ----
      if (this.viewMode === 'home') {
        Column() {
          HomeScreen({
            biosName: this.biosName,
            gameName: this.gameName,
            picking: this.picking,
            statusStage: this.statusStage,
            statusError: this.statusError,
            errorKindLabel: ErrorHint.kindLabel(this.errorKind as FailKind),
            errorAdvice: this.errorAdvice,
            biosCheckChecked: this.biosCheckChecked,
            biosCheckMessage: this.biosCheckMessage,
            biosCheckSuspicious: this.biosCheckSuspicious,
            logExportMessage: this.logExportMessage,
            busy: this.busy,
            jitChecked: this.jitChecked,
            jitAvailable: this.jitAvailable,
            jitMessage: this.jitMessage,
            jitAction: this.jitAction,
            jitStage: this.jitStage,
            jitErrno: this.jitErrno,
            jitDiagnostics: this.jitDiagnostics,
			storeBuild: this.storeBuild,
			executionMode: this.executionMode,
			degraded: this.degraded,
			discSerial: this.discSerial,
			discTitle: this.discTitle,
			discCRC: this.discCRC,
            games: this.games,
            gamesScanning: this.gamesScanning,
            currentGamePath: this.gamePath,
            onPickBios: () => { this.chooseBios(); },
            onPickGame: () => { this.chooseGame(); },
            onClearGame: () => { this.clearGame(); },
            onSelectGame: (g: GameEntry) => { this.selectGameFromLibrary(g); },
            onRefreshGames: () => { this.refreshGames(); },
            coverPaths: this.coverPaths,
            coverBusy: this.coverBusy,
            coverMessage: this.coverMessage,
            coverSourceName: this.currentCoverSourceName(),
            onDownloadCovers: () => { this.downloadMissingCovers(); },
            onDownloadCoverFor: (g: GameEntry) => { this.downloadOneCover(g); },
            onOpenCoverSources: () => { this.showCoverSources = true; },
            onOpenPerGameSettings: (g: GameEntry) => { this.openPerGameSettings(g); },
            onStart: () => { this.startBoot(); },
            onCheckJit: () => { this.checkJit(); },
            onJitPrctlExperiment: () => { this.runJitPrctlExperiment(); },
            jitPrctlExperimentResult: this.jitPrctlExperimentResult,
            onExportLog: () => { this.exportLog(); },
            onOpenSettings: () => {
              this.showSettings = true;
              this.refreshControllers();
            },
            // Dock「记忆卡」入口：直接打开记忆卡管理弹层
            onOpenMemoryCard: () => {
              this.memoryCardGroupFilter = '全部';
              this.showMemoryCardManager = true;
              this.refreshMemoryCards();
            }
          })
        }
        .width('100%')
        .height('100%')
        // 首页需要完全不透明地盖住下面的画面区，避免视觉串扰
        .backgroundColor(Theme.bgBase())
      }

      // ---- 游玩页悬浮球（可拖动）----
      //
      // 【为什么用绝对定位 + PanGesture】
      // 用户要求：悬浮球可随意拖动，并停留在最终拖动位置。
      // 因此不能用"全屏 Column 钉在右上角"的做法（那样无法自由移动），
      // 改为 position({x,y}) 绝对定位 + PanGesture 更新坐标。
      //
      // 坐标含义：球**左上角**在容器内的位置。
      // 拖动时把手势偏移量累加到起点坐标上，实现跟手。
      if (this.viewMode === 'game') {
        Stack() {
          if (this.overlayExpanded) {
            // ---- 展开态：功能列表 ----
            Column({ space: 8 }) {
              Text(this.gamePaused ? '已暂停' : (this.statusRunning ? `${this.gameFps.toFixed(0)} FPS` : this.statusStage))
                .fontSize(11)
                .fontColor(this.gamePaused ? OVERLAY_ACCENT : (this.statusRunning ? OVERLAY_OK : OVERLAY_FG_DIM))
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor(OVERLAY_BG)
                .borderRadius(12)

              Button('存档')
                .width(this.ballBtnW()).height(32).fontSize(12)
                .focusable(false)
                .backgroundColor(OVERLAY_BG)
                .fontColor(OVERLAY_FG)
                .borderRadius(16)
                .onClick(() => {
                  this.refreshSaveSlots();
                  this.saveMessage = '';
                  this.showSavePanel = true;
                  this.overlayExpanded = false;
                })

              Button(this.gamePaused ? '继续' : '暂停')
                .width(this.ballBtnW()).height(32).fontSize(12)
                .focusable(false)
                .backgroundColor(OVERLAY_BG)
                .fontColor(this.gamePaused ? OVERLAY_OK : OVERLAY_ACCENT)
                .borderRadius(16)
                .onClick(() => {
                  this.toggleGamePause();
                  this.overlayExpanded = false;
                })

              Button(this.showPad ? '隐藏按键' : '显示按键')
                .width(this.ballBtnW()).height(32).fontSize(12)
                .focusable(false)
                .backgroundColor(OVERLAY_BG)
                .fontColor(this.showPad ? OVERLAY_ACCENT : OVERLAY_FG)
                .borderRadius(16)
                .onClick(() => {
                  this.showPad = !this.showPad;
                  this.overlayExpanded = false;
                })

              Button('设置')
                .width(this.ballBtnW()).height(32).fontSize(12)
                .focusable(false)
                .backgroundColor(OVERLAY_BG)
                .fontColor(OVERLAY_FG)
                .borderRadius(16)
                .onClick(() => {
                  this.showSettings = true;
                  this.overlayExpanded = false;
                })

              Button('返回')
                .width(this.ballBtnW()).height(32).fontSize(12)
                .focusable(false)
                .backgroundColor(OVERLAY_BG)
                .fontColor(OVERLAY_FG)
                .borderRadius(16)
                .onClick(() => { this.exitGame(); })

              Button('收起')
                .width(this.ballBtnW()).height(28).fontSize(11)
                .focusable(false)
                .backgroundColor(OVERLAY_BG)
                .fontColor(OVERLAY_FG_DIM)
                .borderRadius(14)
                .onClick(() => { this.overlayExpanded = false; })
            }
            .focusable(false)
            .padding(8)
            .backgroundColor(OVERLAY_BG)
            .borderRadius(Theme.radius)
            // 展开态：按**面板尺寸**钳制，避免贴边时被裁切（见 panelLeft）
            .position({ x: this.panelLeft(), y: this.panelTop() })
          } else {
            // ---- 收起态：FPS 悬浮球（可拖动）----
            Column({ space: 1 }) {
              Text(this.gamePaused ? '暂停' : (this.statusRunning ? this.gameFps.toFixed(0) : '--'))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.gamePaused ? OVERLAY_ACCENT : (this.statusRunning ? OVERLAY_OK : OVERLAY_FG_DIM))
              Text('FPS')
                .fontSize(8)
                .fontColor(OVERLAY_FG_DIM)
            }
            .focusable(false)
            .width(56)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(OVERLAY_BG)
            .borderRadius(28)
            .border({ width: 1, color: OVERLAY_BORDER })
            .position({ x: this.ballLeft(), y: this.ballTop() })
            // 用 PanGesture 而非 onClick 拖动：
            // 点击与拖动在触屏上是同一种手势的不同幅度，用 gesture 统一处理
            // 可避免"轻微移动就被判为拖动、导致点击失效"。
            .gesture(
              PanGesture({ fingers: 1, distance: 5 })
                .onActionStart(() => {
                  // 记录拖动起点：若尚未拖过，用当前默认位置
                  this.dragStartX = this.ballLeft();
                  this.dragStartY = this.ballTop();
                })
                .onActionUpdate((event: GestureEvent) => {
                  this.updateBallPos(
                    this.dragStartX + event.offsetX,
                    this.dragStartY + event.offsetY);
                })
                .onActionEnd(() => {
                  // 停留在最终位置：坐标已在 update 中写入 @State，
                  // 此处只需保证坐标合法（贴边不越界）。
                  this.clampBall();
                })
            )
            .onClick(() => { this.overlayExpanded = true; })
          }
        }
        .focusable(false)
        .width('100%')
        .height('100%')
        // 容器不拦截触摸：只有球/列表可点，其余区域透传给下层
        // （虚拟按键与画面）。拖动时由球的 PanGesture 消费事件。
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // ---- 即时存档面板 ----
      //
      // 与游戏内记忆卡存档的区别应在界面上说清，否则用户会混淆：
      // 这是整机状态快照，可随时存读，与记忆卡互不影响。
      if (this.showSavePanel) {
        Column() {
          Column({ space: Theme.gap }) {
            Row() {
              Text('即时存档').fontSize(17).fontColor(Theme.textPri())
                .fontWeight(FontWeight.Medium)
              Blank()
              Button('关闭')
                .height(30).fontSize(13)
                .backgroundColor(Theme.bgCardHi())
                .fontColor(Theme.textPri())
                .borderRadius(15)
                .onClick(() => { this.showSavePanel = false; })
            }
            .width('100%')

            Text('整机状态快照，可随时存读；与游戏内的记忆卡存档互不影响。')
              .fontSize(11).fontColor(Theme.textDim()).width('100%')

            // 存档归属提示：即时存档的文件名含序列号与 CRC（上游格式
            // "<serial> (<CRC8>).NN.p2s"），即**按游戏分开存放**。
            // 用户在多游戏间切换时，若不知道当前槽属于哪个游戏，
            // 容易误以为"存档丢了"。这里显式标出归属。
            if (this.discSerial.length > 0) {
              Row({ space: 6 }) {
                Text('当前游戏')
                  .fontSize(10).fontColor(Theme.textDim())
                Text(this.discTitle.length > 0 ? this.discTitle : this.discSerial)
                  .fontSize(11).fontColor(Theme.accentHi())
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(this.discSerial)
                  .fontSize(10).fontColor(Theme.textDim())
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 5, bottom: 5 })
              .backgroundColor(Theme.bgCardHi())
              .borderRadius(Theme.radiusSm)
            } else {
              Text('尚未启动游戏 —— 存档槽按游戏分开存放，请先启动后再存读。')
                .fontSize(10).fontColor(Theme.warn()).width('100%')
            }

            if (this.saveMessage.length > 0) {
              Text(this.saveMessage)
                .fontSize(12).fontColor(Theme.accentHi()).width('100%')
            }

            // 槽位列表（可滚动，避免槽多时溢出）
            Scroll() {
              Column({ space: 8 }) {
                ForEach(this.saveSlots, (item: SaveSlotInfo) => {
                  Row({ space: 10 }) {
                    Text('槽 ' + item.slot.toString())
                      .fontSize(13).fontColor(Theme.textPri()).width(52)

                    Text(item.hasSave ? '有存档' : '空')
                      .fontSize(11)
                      .fontColor(item.hasSave ? Theme.ok() : Theme.textDim())
                      .layoutWeight(1)

                    Button('存')
                      .height(32).fontSize(12)
                      .backgroundColor(Theme.accent())
                      .fontColor('#FFFFFF')
                      .borderRadius(Theme.radiusSm)
                      .onClick(() => { this.doSaveState(item.slot); })

                    Button('读')
                      .height(32).fontSize(12)
                      .backgroundColor(item.hasSave ? Theme.bgCardHi() : Theme.bgDeep())
                      .fontColor(item.hasSave ? Theme.textPri() : Theme.textDim())
                      .borderRadius(Theme.radiusSm)
                      .enabled(item.hasSave)
                      .onClick(() => { this.doLoadState(item.slot); })

                    Button('删')
                      .height(32).fontSize(12)
                      .backgroundColor(item.hasSave ? Theme.panelErrBg() : Theme.bgDeep())
                      .fontColor(item.hasSave ? Theme.err() : Theme.textDim())
                      .borderRadius(Theme.radiusSm)
                      .enabled(item.hasSave)
                      .onClick(() => { this.confirmDeleteState(item.slot); })
                  }
                  .width('100%')
                  .padding({ top: 6, bottom: 6 })
                }, (item: SaveSlotInfo) => item.slot.toString())
              }
              .width('100%')
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)

            if (this.saveSlots.length === 0) {
              Text('存档槽状态不可用 —— 可能尚未启动游戏。')
                .fontSize(11).fontColor(Theme.warn()).width('100%')
            }
          }
          .width('88%')
          .height('72%')
          .padding(Theme.pad)
          .backgroundColor(Theme.bgBase())
          .borderRadius(Theme.radius)
          .border({ width: 1, color: Theme.borderHi() })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.overlayScrim())
        .onClick(() => { this.showSavePanel = false; })
      }

      // ---- 触控布局编辑器 ----
      //
      // 对齐设计稿 03-edit-layout.jpg：顶栏（返回/标题/完成）+ 右侧设置面板。
      //
      // 【为什么面板位置随方向变】设计稿是横屏（画面宽、右侧有空间）。
      // 竖屏时右侧面板会盖掉大半个屏幕，用户看不到自己正在摆的按键 ——
      // 故竖屏改为底部面板，两者共用同一套 builder。
      if (this.padEditMode) {
        Column() {
          // ---- 顶栏 ----
          Row() {
            Button('‹ 返回')
              .height(34).fontSize(13)
              .backgroundColor(OVERLAY_BG).fontColor(OVERLAY_FG)
              .borderRadius(17)
              .onClick(() => { this.exitPadEdit(false); })

            Text('编辑布局')
              .fontSize(16).fontColor(OVERLAY_FG).fontWeight(FontWeight.Medium)
              .layoutWeight(1).textAlign(TextAlign.Center)

            Button('✓ 完成')
              .height(34).fontSize(13)
              .backgroundColor(OVERLAY_BG).fontColor(OVERLAY_OK)
              .borderRadius(17)
              .onClick(() => { this.exitPadEdit(true); })
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })

          // ---- 主体：画布提示 + 设置面板 ----
          if (this.isLandscapeSurface()) {
            Row() {
              // 左侧留白即画布区（虚拟按键在 GameScreen 层，此处不遮挡）
              Text('拖动虚线框调整按键位置')
                .fontSize(12).fontColor(OVERLAY_FG_DIM)
                .layoutWeight(1).textAlign(TextAlign.Center)
              this.padEditorPanel()
            }
            .width('100%').layoutWeight(1).alignItems(VerticalAlign.Top)
          } else {
            Column() {
              Text('拖动虚线框调整按键位置')
                .fontSize(12).fontColor(OVERLAY_FG_DIM)
                .width('100%').textAlign(TextAlign.Center)
                .padding({ top: 8, bottom: 8 })
                .layoutWeight(1)
              this.padEditorPanel()
            }
            .width('100%').layoutWeight(1)
          }
        }
        .width('100%')
        .height('100%')
        // 编辑器自身不拦截触摸（否则游戏画面/按键都点不到），
        // 只有顶栏与面板是可交互的 —— 中间的画布区透传给下层 VirtualPad。
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // ---- 加载覆盖层 ----
      //
      // 用户要求：选择游戏后给出加载中提示，加载完自动消失。
      // 覆盖全屏且**拦截触摸** —— 复制数 GB 期间不应允许再次点选，
      // 否则会并发复制、互相覆盖目标文件。
      if (this.loading) {
        Column({ space: 20 }) {
          LoadingProgress()
            .width(56)
            .height(56)
            .color(Theme.accentHi())

          Text('载入中')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPri())

          Text(this.loadingText)
            .fontSize(13)
            .fontColor(Theme.textSec())
            .textAlign(TextAlign.Center)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 24, right: 24 })

          Text('大文件需要数十秒，请勿退出应用')
            .fontSize(11)
            .fontColor(Theme.textDim())
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.overlayScrim())
        // 拦截所有触摸：加载期间不允许再触发选择/启动
        .onClick(() => { /* 有意吞掉点击，避免穿透到底层控件 */ })
      }

      // ---- 设置弹层 ----
      // 画面比例等设置放在这里，游玩时也能调（改完立即生效，无需重启 VM）。
      if (this.showSettings) {
        Column() {
          Column({ space: Theme.gap }) {
            Row() {
              Text('设置').fontSize(17).fontColor(Theme.textPri()).fontWeight(FontWeight.Medium)
              Blank()
              Button('关闭')
                .height(30).fontSize(13)
                .backgroundColor(Theme.bgCardHi())
                .fontColor(Theme.textPri())
                .borderRadius(15)
                .onClick(() => { this.showSettings = false; this.showMemoryCardManager = false; })
            }
            .width('100%')

          Scroll() {
            Column({ space: Theme.gap }) {
              // ---- 存档管理入口 ----
              Column({ space: 8 }) {
                Row() {
                  Column({ space: 2 }) {
                    Text('存档管理').fontSize(14).fontColor(Theme.textPri())
                    Text('PS2 记忆卡按游戏分类；即时存档仍在游戏内管理')
                      .fontSize(11).fontColor(Theme.textDim())
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Button('打开')
                    .height(34).fontSize(12)
                    .backgroundColor(Theme.accent())
                    .fontColor('#FFFFFF')
                    .borderRadius(Theme.radiusSm)
                    .onClick(() => {
                      this.memoryCardGroupFilter = '全部';
                      this.showMemoryCardManager = true;
                      this.refreshMemoryCards();
                    })
                }
                .width('100%')
              }
              .width('100%')
              .padding(Theme.pad)
              .backgroundColor(Theme.bgCard())
              .borderRadius(Theme.radius)
              .border({ width: 1, color: Theme.border() })

              // ---- BIOS ----
              Column({ space: 10 }) {
                Text('BIOS').fontSize(14).fontColor(Theme.textPri()).width('100%')
                Text(this.biosName.length > 0 ? '当前：' + this.biosName :
                  '尚未选择 BIOS；首次选择后会自动记住。')
                  .fontSize(11)
                  .fontColor(this.biosName.length > 0 ? Theme.ok() : Theme.textDim())
                  .width('100%')
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Button(this.picking === 'bios' ? '处理中…' : '更换 BIOS')
                  .width('100%')
                  .height(38)
                  .fontSize(13)
                  .backgroundColor(Theme.bgCardHi())
                  .fontColor(Theme.textPri())
                  .borderRadius(Theme.radiusSm)
                  .enabled(this.picking !== 'bios')
                  .onClick(() => { this.chooseBios(); })
              }
              .width('100%')
              .padding(Theme.pad)
              .backgroundColor(Theme.bgCard())
              .borderRadius(Theme.radius)
              .border({ width: 1, color: Theme.border() })

              // ---- 蓝牙 / 外接手柄 ----
              Column({ space: 10 }) {
                Text('蓝牙手柄映射').fontSize(14).fontColor(Theme.textPri()).width('100%')
                Text(this.controllerStatus)
                  .fontSize(11).fontColor(Theme.textDim()).width('100%')
                Text('蓝牙手柄需要先在系统中完成配对；模拟器启动后点击刷新。映射当前运行有效。')
                  .fontSize(11).fontColor(Theme.textDim()).width('100%')
                Button('刷新手柄')
                  .width('100%').height(38).fontSize(13)
                  .backgroundColor(Theme.bgCardHi())
                  .fontColor(Theme.textPri())
                  .borderRadius(Theme.radiusSm)
                  .onClick(() => { this.refreshControllers(); })

                ForEach(this.controllerDevices, (device: ControllerInfo) => {
                  Row({ space: 8 }) {
                    Column({ space: 2 }) {
                      Text(device.name).fontSize(12).fontColor(Theme.textSec())
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(device.id).fontSize(10).fontColor(Theme.textDim())
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    Button(device.mapped ? '已映射 1P' : '映射到 1P')
                      .height(34).fontSize(12)
                      .backgroundColor(device.mapped ? Theme.ok() : Theme.accent())
                      .fontColor('#FFFFFF')
                      .borderRadius(Theme.radiusSm)
                      .enabled(!device.mapped)
                      .onClick(() => { this.mapController(device); })
                  }
                  .width('100%')
                  .padding({ top: 6, bottom: 6 })
                }, (device: ControllerInfo) => device.id)
              }
              .width('100%')
              .padding(Theme.pad)
              .backgroundColor(Theme.bgCard())
              .borderRadius(Theme.radius)
              .border({ width: 1, color: Theme.border() })

              // ---- 画面比例 ----
              Column({ space: 8 }) {
              Text('画面比例').fontSize(14).fontColor(Theme.textPri()).width('100%')
              Text('PS2 原生为 4:3。横屏时拉伸不明显；竖屏拉伸较明显。')
                .fontSize(11).fontColor(Theme.textDim()).width('100%')

              ForEach([0, 1, 2, 3], (m: number) => {
                Row() {
                  Text(this.aspectLabel(m)).fontSize(13)
                    .fontColor(this.aspectMode === m ? Theme.accentHi() : Theme.textSec())
                    .layoutWeight(1)
                  if (this.aspectMode === m) {
                    Text('✓').fontSize(14).fontColor(Theme.accentHi())
                  }
                }
                .width('100%')
                .padding({ top: 10, bottom: 10 })
                .backgroundColor(this.aspectMode === m ? Theme.bgCardHi() : Color.Transparent)
                .borderRadius(Theme.radiusSm)
                .onClick(() => { this.setAspect(m); })
              })
            }
            .width('100%')
            .padding(Theme.pad)
            .backgroundColor(Theme.bgCard())
            .borderRadius(Theme.radius)
            .border({ width: 1, color: Theme.border() })

            // ---- 内部渲染分辨率 ----
            Column({ space: 8 }) {
              Text('内部渲染分辨率').fontSize(14).fontColor(Theme.textPri()).width('100%')
              Text('倍率越高越清晰，也越占用 GPU；修改后下次启动游戏生效。')
                .fontSize(11).fontColor(Theme.textDim()).width('100%')

              ForEach([1, 2, 3], (m: number) => {
                Row() {
                  Text(this.upscaleLabel(m)).fontSize(13)
                    .fontColor(Math.round(this.upscaleMultiplier) === m ? Theme.accentHi() : Theme.textSec())
                    .layoutWeight(1)
                  if (Math.round(this.upscaleMultiplier) === m) {
                    Text('✓').fontSize(14).fontColor(Theme.accentHi())
                  }
                }
                .width('100%')
                .padding({ top: 10, bottom: 10 })
                .backgroundColor(Math.round(this.upscaleMultiplier) === m ? Theme.bgCardHi() : Color.Transparent)
                .borderRadius(Theme.radiusSm)
                .onClick(() => { this.setUpscale(m); })
              })
            }
            .width('100%')
            .padding(Theme.pad)
            .backgroundColor(Theme.bgCard())
            .border({ width: 1, color: Theme.border() })

            // ---- 性能：MTVU ----
            Column({ space: 10 }) {
              Text('性能').fontSize(14).fontColor(Theme.textPri()).width('100%')

              Row() {
                Column({ space: 2 }) {
                  Text('MTVU（VU1 独立线程）').fontSize(13).fontColor(Theme.textSec())
				  Text(this.storeBuild ? '商店兼容模式使用 VU1 解释器，MTVU 不可用' :
					'把 VU1 移到独立线程，可提升帧率；个别游戏可能不兼容')
                    .fontSize(10).fontColor(Theme.textDim())
				  Text(this.storeBuild ? '已按商店策略关闭' : '下次启动游戏生效')
                    .fontSize(10).fontColor(Theme.warn())
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

				Toggle({ type: ToggleType.Switch, isOn: this.storeBuild ? false : this.vuThread })
				  .enabled(!this.storeBuild)
                  .onChange((on: boolean) => { this.setVuThread(on); })
              }
              .width('100%')
            }
            .width('100%')
            .padding(Theme.pad)
            .backgroundColor(Theme.bgCard())
            .borderRadius(Theme.radius)
            .border({ width: 1, color: Theme.border() })

            // ---- 虚拟按键 ----
            Column({ space: 10 }) {
              Text('虚拟按键').fontSize(14).fontColor(Theme.textPri()).width('100%')
              Row() {
                Text('显示虚拟按键').fontSize(13).fontColor(Theme.textSec())
                Blank()
                Toggle({ type: ToggleType.Switch, isOn: this.showPad })
                  .onChange((on: boolean) => { this.showPad = on; })
              }
              .width('100%')

              // ---- 布局编辑入口 ----
              // 放在这里而非悬浮球：布局是"设置一次就少动"的东西，
              // 悬浮球留给游玩时的即时操作（存档/暂停）。
              Column({ space: 4 }) {
                Row() {
                  Column({ space: 2 }) {
                    Text('编辑按键布局').fontSize(13).fontColor(Theme.textSec())
                    Text('拖动调整位置、透明度与配色；横竖屏各存一份')
                      .fontSize(10).fontColor(Theme.textDim())
                  }
                  .layoutWeight(1).alignItems(HorizontalAlign.Start)
                  Button('编辑')
                    .height(34).fontSize(12)
                    .backgroundColor(Theme.accent()).fontColor('#FFFFFF')
                    .borderRadius(Theme.radiusSm)
                    .enabled(this.statusRunning)
                    .onClick(() => {
                      // 面板要先关掉：否则设置弹层盖在编辑区上方
                      this.showSettings = false;
                      this.showMemoryCardManager = false;
                      this.enterPadEdit();
                    })
                }
                .width('100%')

                if (!this.statusRunning) {
                  Text('需先启动游戏 —— 布局按实际画面尺寸计算，空跑时无从判断遮挡。')
                    .fontSize(10).fontColor(Theme.warn()).width('100%')
                }
              }
              .width('100%')
            }
            .width('100%')
            .padding(Theme.pad)
            .backgroundColor(Theme.bgCard())
            .borderRadius(Theme.radius)
            .border({ width: 1, color: Theme.border() })

              Text('提示：接入手柄后可关闭虚拟按键，避免遮挡画面。')
                .fontSize(11).fontColor(Theme.textDim()).width('100%')

              Blank()
            }
            .width('100%')
            .padding({ left: Theme.pad, right: Theme.pad, bottom: Theme.pad })
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
        }
        .width('88%')
        .height('86%')
        .padding(Theme.pad)
        .backgroundColor(Theme.bgBase())
        .borderRadius(Theme.radius)
        .border({ width: 1, color: Theme.borderHi() })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.overlayScrim())
        .onClick(() => { this.showSettings = false; this.showMemoryCardManager = false; })
      }

      // ---- 逐游戏设置弹层 ----
      // 每个游戏可独立覆盖画面比例/渲染倍率/MTVU；未覆盖的项继承全局。
      // 值写入上游自己的 gamesettings/<serial>_<CRC>.ini。
      if (this.perGameTarget !== null && this.perGame !== null) {
        Column() {
          Column({ space: Theme.gap }) {
            Row() {
              Column({ space: 2 }) {
                Text('本游戏设置').fontSize(17).fontColor(Theme.textPri()).fontWeight(FontWeight.Medium)
                Text(libGameTitle(this.perGameTarget))
                  .fontSize(11).fontColor(Theme.textDim())
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.perGame.serial + ' · 仅对这款游戏生效，覆盖全局设置')
                  .fontSize(10).fontColor(Theme.textDim())
              }
              .layoutWeight(1).alignItems(HorizontalAlign.Start)
              Button('关闭')
                .height(30).fontSize(13)
                .backgroundColor(Theme.bgCardHi())
                .fontColor(Theme.textPri())
                .borderRadius(15)
                .onClick(() => { this.closePerGameSettings(); })
            }
            .width('100%')

            Scroll() {
              Column({ space: Theme.gap }) {
                // ---- 画面比例 ----
                this.perGameSection('画面比例',
                  this.perGame.aspectSet ? '已为这款游戏单独设置' : '当前跟随全局设置',
                  this.perGame.aspectSet,
                  () => { this.writePerGameSetting('aspect', null); })
                Row({ space: 6 }) {
                  ForEach([0, 1, 2, 3], (m: number) => {
                    Text(this.aspectLabel(m))
                      .fontSize(11)
                      .fontColor(this.effectiveAspect() === m ? '#FFFFFF' : Theme.textSec())
                      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                      .backgroundColor(this.effectiveAspect() === m ? Theme.accent() : Theme.bgCardHi())
                      .borderRadius(Theme.radiusSm)
                      .layoutWeight(1)
                      .textAlign(TextAlign.Center)
                      .onClick(() => { this.writePerGameSetting('aspect', m); })
                  }, (m: number) => 'aspect-' + m.toString())
                }
                .width('100%')

                // ---- 内部渲染倍率 ----
                this.perGameSection('内部渲染倍率',
                  this.perGame.upscaleSet ? '已为这款游戏单独设置' : '当前跟随全局设置',
                  this.perGame.upscaleSet,
                  () => { this.writePerGameSetting('upscale', null); })
                Row({ space: 6 }) {
                  ForEach([1, 2, 3], (m: number) => {
                    Text(this.upscaleLabel(m))
                      .fontSize(11)
                      .fontColor(this.effectiveUpscale() === m ? '#FFFFFF' : Theme.textSec())
                      .padding({ left: 8, right: 8, top: 8, bottom: 8 })
                      .backgroundColor(this.effectiveUpscale() === m ? Theme.accent() : Theme.bgCardHi())
                      .borderRadius(Theme.radiusSm)
                      .layoutWeight(1)
                      .textAlign(TextAlign.Center)
                      .onClick(() => { this.writePerGameSetting('upscale', m); })
                  }, (m: number) => 'up-' + m.toString())
                }
                .width('100%')

                // ---- MTVU ----
                this.perGameSection('MTVU（VU1 独立线程）',
                  this.perGame.vuThreadSet ? '已为这款游戏单独设置' : '当前跟随全局设置',
                  this.perGame.vuThreadSet,
                  () => { this.writePerGameSetting('vuThread', null); })
                Row() {
                  Text('把 VU1 移到独立线程；个别游戏可能不兼容')
                    .fontSize(10).fontColor(Theme.textDim()).layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.effectiveVuThread() })
                    .onChange((on: boolean) => { this.writePerGameSetting('vuThread', on); })
                }
                .width('100%')

                if (this.perGameMessage.length > 0) {
                  Text(this.perGameMessage)
                    .fontSize(11).fontColor(Theme.ok()).width('100%')
                }
                Text('这些值在启动游戏时读取，因此改动对**下次启动**生效。')
                  .fontSize(10).fontColor(Theme.textDim()).width('100%')
              }
              .width('100%')
            }
            .layoutWeight(1)
            .scrollBar(BarState.Auto)
          }
          .width('92%')
          .height('86%')
          .padding(Theme.pad)
          .backgroundColor(Theme.bgBase())
          .borderRadius(Theme.radius)
          .border({ width: 1, color: Theme.borderHi() })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.overlayScrim())
        .onClick(() => { this.closePerGameSettings(); })
      }

      // ---- 封面源管理弹层 ----
      // 内置源可启停、自定义源可增删；当前源决定"下载封面"走哪个库。
      if (this.showCoverSources) {
        Column() {
          Column({ space: Theme.gap }) {
            Row() {
              Column({ space: 2 }) {
                Text('封面源').fontSize(17).fontColor(Theme.textPri()).fontWeight(FontWeight.Medium)
                Text('选择从哪个封面库下载；可按需启停或添加自己的源')
                  .fontSize(10).fontColor(Theme.textDim())
              }
              .layoutWeight(1).alignItems(HorizontalAlign.Start)
              Button('关闭')
                .height(30).fontSize(13)
                .backgroundColor(Theme.bgCardHi())
                .fontColor(Theme.textPri())
                .borderRadius(15)
                .onClick(() => { this.showCoverSources = false; })
            }
            .width('100%')

            Scroll() {
              Column({ space: Theme.gap }) {
                // ---- 内置源 ----
                Text('内置源').fontSize(13).fontColor(Theme.textSec()).width('100%')
                ForEach(this.builtinCoverSources(), (src: CoverSource) => {
                  this.coverSourceRow(src, true)
                }, (src: CoverSource) => src.id)

                // ---- 自定义源 ----
                Text('自定义源').fontSize(13).fontColor(Theme.textSec()).width('100%')
                if (SharedCoverSources.store.customSources().length === 0) {
                  Text('还没有自定义源。若内置源在你的网络下都不可用，可在下面添加。')
                    .fontSize(11).fontColor(Theme.textDim()).width('100%')
                } else {
                  ForEach(SharedCoverSources.store.customSources(), (src: CoverSource) => {
                    this.coverSourceRow(src, false)
                  }, (src: CoverSource) => src.id)
                }

                // ---- 新增自定义源 ----
                Column({ space: 8 }) {
                  Text('添加自定义源').fontSize(13).fontColor(Theme.textSec()).width('100%')
                  TextInput({ placeholder: '名称，例如：我的图床', text: this.newSourceName })
                    .height(38).fontSize(13)
                    .backgroundColor(Theme.bgCardHi())
                    .onChange((v: string) => { this.newSourceName = v; })
                  TextInput({
                    placeholder: 'URL 模板，须含 ${serial} / ${title} / ${filetitle}',
                    text: this.newSourceUrl
                  })
                    .height(38).fontSize(12)
                    .backgroundColor(Theme.bgCardHi())
                    .onChange((v: string) => { this.newSourceUrl = v; })
                  Text('示例：https://你的域名/covers/${serial}.jpg')
                    .fontSize(10).fontColor(Theme.textDim()).width('100%')
                  if (this.newSourceError.length > 0) {
                    Text(this.newSourceError).fontSize(11).fontColor(Theme.warn()).width('100%')
                  }
                  Button('添加')
                    .width('100%').height(38).fontSize(13)
                    .backgroundColor(Theme.accent()).fontColor('#FFFFFF')
                    .borderRadius(Theme.radiusSm)
                    .onClick(() => { this.addCustomCoverSource(); })
                }
                .width('100%')
                .padding(Theme.pad)
                .backgroundColor(Theme.bgCard())
                .borderRadius(Theme.radius)
                .border({ width: 1, color: Theme.border() })
              }
              .width('100%')
            }
            .layoutWeight(1)
            .scrollBar(BarState.Auto)
          }
          .width('92%')
          .height('86%')
          .padding(Theme.pad)
          .backgroundColor(Theme.bgBase())
          .borderRadius(Theme.radius)
          .border({ width: 1, color: Theme.borderHi() })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.overlayScrim())
        .onClick(() => { this.showCoverSources = false; })
      }

      // ---- 独立存档管理页 ----
      // 放在设置入口之上，避免把记忆卡操作继续堆在首页。
      if (this.showMemoryCardManager) {
        Column() {
          Column({ space: Theme.gap }) {
            Row() {
              Button('返回')
                .height(30).fontSize(13)
                .backgroundColor(Theme.bgCardHi())
                .fontColor(Theme.textPri())
                .borderRadius(15)
                .onClick(() => { this.showMemoryCardManager = false; })
              Text('存档管理')
                .fontSize(17).fontColor(Theme.textPri()).fontWeight(FontWeight.Medium)
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
              Button('刷新')
                .height(30).fontSize(13)
                .backgroundColor(Theme.bgCardHi())
                .fontColor(Theme.textPri())
                .borderRadius(15)
                .onClick(() => { this.refreshMemoryCards(); })
            }
            .width('100%')

            Text('PS2 专用记忆卡，可跨模拟器读写；即时存档不在这里。')
              .fontSize(11).fontColor(Theme.textDim()).width('100%')

            Scroll() {
              Column({ space: Theme.gap }) {
                Row({ space: 6 }) {
                  ForEach(this.memoryCardGroupOptions(), (group: string) => {
                    Button(group)
                      .height(32).fontSize(11)
                      .backgroundColor(this.memoryCardGroupFilter === group ?
                        Theme.accent() : Theme.bgCardHi())
                      .fontColor(this.memoryCardGroupFilter === group ? '#FFFFFF' : Theme.textPri())
                      .borderRadius(16)
                      .onClick(() => { this.memoryCardGroupFilter = group; })
                  }, (group: string) => group)
                }
                .width('100%')

                MemoryCardPanel({
                  cards: this.visibleMemoryCards(),
                  message: this.memoryCardMessage,
                  directory: this.memoryCardsDirectory,
                  busy: this.memoryCardBusy,
                  currentGame: this.gameName.length > 0 ? this.currentMemoryCardGroup() : '',
                  onRefresh: () => { this.refreshMemoryCards(); },
                  onImport: () => { this.importMemoryCard(); },
                  onCreate: (sizeMb: number) => { this.createMemoryCard(sizeMb); },
                  onExport: (name: string) => { this.exportMemoryCard(name); },
                  onDelete: (name: string) => { this.confirmDeleteMemoryCard(name); },
                  onAssignCurrentGame: (name: string) => { this.assignMemoryCardToCurrentGame(name); }
                })
              }
              .width('100%')
              .padding({ bottom: Theme.pad })
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
          }
          .width('88%')
          .height('86%')
          .padding(Theme.pad)
          .backgroundColor(Theme.bgBase())
          .borderRadius(Theme.radius)
          .border({ width: 1, color: Theme.borderHi() })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.overlayScrim())
        .onClick(() => { this.showMemoryCardManager = false; })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bgBase())
    .onKeyEventDispatch((event: KeyEvent): boolean => {
      return this.consumeNativeGamepadUiKey(event);
    })
  }
}
