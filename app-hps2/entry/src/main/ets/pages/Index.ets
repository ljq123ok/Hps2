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
import { StatusBar } from '../components/StatusBar';
import { Immersive } from '../common/Immersive';
import { ErrorHint, FailKind } from '../common/ErrorHint';
import { LogExport } from '../common/LogExport';
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
  error: string;
  fps: number;
  jitAvailable: boolean;
  jitStage: string;
  jitErrno: number;
  jitMessage: string;
  jitAction: string;
}

/** JIT 自检结果（对应 native 的 checkJit()，见 libhps2core/index.d.ts） */
interface JitCheckResult {
  available: boolean;
  stage: number;
  stageName: string;
  errno: number;
  message: string;
  action: string;
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
  @State gameFps: number = 0;
  @State busy: boolean = false;

  // ---- JIT 能力状态（产品决策：不降级，不可用则阻止启动）----
  // jitChecked 区分"还没查"与"查了但不可用"：
  // 前者不该显示红色警告，后者必须明确告诉用户不能启动。
  @State jitChecked: boolean = false;
  @State jitAvailable: boolean = false;
  @State jitMessage: string = '';
  @State jitAction: string = '';
  @State jitStage: string = '';
  @State jitErrno: number = 0;
  @State jitChecking: boolean = false;

  // ---- 新前端的 UI 状态 ----
  /** 页面模式：home=设置/游戏库  game=全屏游玩 */
  @State viewMode: string = 'home';
  /** 是否显示虚拟按键（接入手柄后可关闭） */
  @State showPad: boolean = true;
  /** 设置弹层 */
  @State showSettings: boolean = false;
  /** SDL 已识别的真实手柄；蓝牙手柄通过系统 HID 进入这里。 */
  @State controllerDevices: Array<ControllerInfo> = [];
  @State controllerStatus: string = '请先启动游戏，再刷新手柄列表';
  /** 画面比例：0=自动 1=保持4:3 2=铺满 3=宽屏16:9 */
  @State aspectMode: number = 0;
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

  private biosSelectionFile(): string {
    return this.biosDir() + '/selected.json';
  }

  private videoSettingsFile(): string {
    return this.dataRoot() + '/video-settings.json';
  }

  aboutToAppear(): void {
    // Native 状态只在当前进程内有效；先恢复持久化设置，再读取 UI 初始值。
    this.restoreVideoSettings();
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
      hilog.info(DOMAIN, TAG, 'biosDir=%{public}s', dir);
      this.restoreBiosSelection();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'mkdir bios dir failed: %{public}s', JSON.stringify(e));
    }
    try {
      const gdir = this.gameDir();
      if (!fs.accessSync(gdir)) {
        fs.mkdirSync(gdir);
      }
      hilog.info(DOMAIN, TAG, 'gameDir=%{public}s', gdir);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'mkdir games dir failed: %{public}s', JSON.stringify(e));
    }
    // 核心要求 <AppRoot>/resources 存在（SetResourcesDirectory 会校验），
    // 首次启动时从 HAP 的 rawfile 解压出来。
    this.ensureResources();
    this.refreshStatus();

    // 启动前先查 JIT 能力：让用户在选 BIOS 之前就知道能不能跑，
    // 而不是点了启动才发现失败。
    this.checkJit();
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
    try {
      const raw: string = hps2core.checkJit();
      const r = JSON.parse(raw) as JitCheckResult;
      this.jitAvailable = r.available;
      this.jitMessage = r.message;
      this.jitAction = r.action;
      this.jitStage = r.stageName;
      this.jitErrno = r.errno;
      this.jitChecked = true;
      hilog.info(DOMAIN, TAG, 'checkJit available=%{public}d stage=%{public}s errno=%{public}d',
        r.available ? 1 : 0, r.stageName, r.errno);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'checkJit failed: %{public}s', err.message);
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

      hilog.info(DOMAIN, TAG, 'extracting resources to %{public}s', resDir);
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
      hilog.error(DOMAIN, TAG, 'extract resources failed: %{public}s', JSON.stringify(err));
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
      hilog.info(DOMAIN, TAG, 'selected %{public}s uri=%{public}s', kind, srcUri);

      const clean = srcUri.split('?')[0];
      const segs = clean.split('/');
      const fileName = decodeURIComponent(segs[segs.length - 1]) || (kind + '.bin');
      const destPath = destDir + '/' + fileName;
      hilog.info(DOMAIN, TAG, '%{public}s dest=%{public}s', kind, destPath);

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
      return destPath + '|' + fileName + '|' + this.humanSize(stat.size);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'pick %{public}s failed: %{public}s', kind, JSON.stringify(err));
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
      hilog.info(DOMAIN, TAG, 'saved BIOS selection %{public}s', fileName);
    } catch (e) {
      // BIOS 已复制成功；记录失败不阻止本次启动，但保留诊断日志。
      hilog.error(DOMAIN, TAG, 'save BIOS selection failed: %{public}s', JSON.stringify(e));
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
        hilog.error(DOMAIN, TAG, 'saved BIOS missing: %{public}s', restoredPath);
        return;
      }

      if (displayName.length === 0) {
        const stat = fs.statSync(restoredPath);
        displayName = fileName + ' (' + this.humanSize(stat.size) + ')';
      }
      this.biosPath = restoredPath;
      this.biosName = displayName;
      if (!fs.accessSync(marker)) {
        this.saveBiosSelection(fileName, displayName);
      }
      hilog.info(DOMAIN, TAG, 'restored BIOS selection %{public}s', restoredPath);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'restore BIOS selection failed: %{public}s', JSON.stringify(e));
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
      hilog.info(DOMAIN, TAG, 'selected %{public}s uri=%{public}s', kind, srcUri);

      // 持久化读权限：否则应用重启后该 URI 失效。
      // 失败不致命 —— 本次会话内仍可用，只是下次启动要重选。
      try {
        const policy: fileshare.PolicyInfo = {
          uri: srcUri,
          operationMode: fileshare.OperationMode.READ_MODE
        };
        await fileshare.persistPermission([policy]);
        hilog.info(DOMAIN, TAG, 'persistPermission ok for %{public}s', kind);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, TAG, 'persistPermission failed (%{public}s): %{public}s',
          kind, err.message);
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
      const sizeText = size > 0 ? this.humanSize(size) : '未知大小';
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
      hilog.error(DOMAIN, TAG, 'pick %{public}s failed: %{public}s', kind, JSON.stringify(err));
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
      hilog.error(DOMAIN, TAG, 'checkBios failed: %{public}s', JSON.stringify(e));
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
        '启动阶段: ' + this.statusStage,
        '运行中: ' + (this.statusRunning ? '是' : '否'),
        'JIT 可用: ' + (this.jitAvailable ? '是' : '否'),
        'JIT 阶段: ' + this.jitStage,
        'JIT errno: ' + this.jitErrno.toString(),
        '当前错误: ' + (this.statusError.length > 0 ? this.statusError : '(无)'),
        '错误类别: ' + ErrorHint.kindLabel(this.errorKind as FailKind),
        'BIOS 检查: ' + (this.biosCheckChecked ? this.biosCheckMessage : '(未检查)'),
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
      hilog.error(DOMAIN, TAG, 'exportLog failed: %{public}s', err.message);
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
  private exitGame(): void {
    this.overlayExpanded = false;
    this.beginLoading('正在停止模拟器…');
    // 用 setTimeout 让加载提示先绘制出来 ——
    // stop() 是同步调用，直接调会阻塞 UI 导致提示来不及显示。
    setTimeout(() => {
      try {
        this.stopBoot();
      } finally {
        this.endLoading();
        this.viewMode = 'home';
        // 回首页必须恢复系统栏，否则用户看不到导航条、难以切换应用
        this.setImmersive(false);
        this.setGameOrientation(false);
      }
    }, 50);
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
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'listSaveSlots failed: %{public}s', JSON.stringify(e));
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
      hilog.error(DOMAIN, TAG, 'saveState failed: %{public}s', err.message);
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
      hilog.error(DOMAIN, TAG, 'loadState failed: %{public}s', err.message);
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
      hilog.info(DOMAIN, TAG, 'game ready at sandbox: %{public}s', destPath);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'copy game failed: %{public}s', JSON.stringify(err));
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
      hilog.error(DOMAIN, TAG, 'saveGameSelection failed: %{public}s', JSON.stringify(e));
    }
  }

  private gameSelectionFile(): string {
    return this.dataRoot() + '/game_selection.json';
  }

  private clearGame(): void {
    this.gamePath = '';
    this.gameName = '';
  }

  private humanSize(n: number): string {
    if (n >= 1048576) {
      return (n / 1048576).toFixed(1) + ' MB';
    }
    if (n >= 1024) {
      return (n / 1024).toFixed(1) + ' KB';
    }
    return n + ' B';
  }

  private async startBoot(): Promise<void> {
    if (!this.biosPath) {
      this.statusError = '请先选择 BIOS 文件';
      return;
    }

    // JIT 硬门禁（UI 侧前置）：不可用时不发起启动。
    // native 侧还有一道权威门禁，这里是为了给出即时、明确的反馈。
    // 刻意**不做降级**：不提供"用解释器模式继续"之类的选项。
    if (this.jitChecked && !this.jitAvailable) {
      this.setError(`JIT 不可用，已拒绝启动。${this.jitMessage}`);
      return;
    }

    this.clearError();
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
      hilog.error(DOMAIN, TAG, 'startBios exception: %{public}s', err.message);
      this.statusError = '调用核心失败：' + err.message;
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
      if (st.jitStage) {
        this.jitChecked = true;
        this.jitAvailable = st.jitAvailable;
        this.jitMessage = st.jitMessage;
        this.jitAction = st.jitAction;
        this.jitStage = st.jitStage;
        this.jitErrno = st.jitErrno;
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
      // 按键映射不在这里做 —— 见上方注释。native 会在 VM 初始化完成后
      // 自行映射到端口 0（1P）。
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'setupVirtualPad failed: %{public}s', JSON.stringify(err));
      this.statusError = '虚拟手柄准备失败：' + err.message;
    }
  }

  private startPolling(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
    }
    this.timerId = setInterval(() => this.refreshStatus(), 500);
  }

  private refreshStatus(): void {
    try {
      const raw: string = hps2core.getStatus();
      const st = JSON.parse(raw) as BootStatus;
      this.statusStage = st.stageName;
      this.statusRunning = st.running;
      this.gameFps = st.fps > 0 ? st.fps : 0;
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
    if (this.gameFps <= 0) return '运行中';
    return '运行中  ' + (Math.round(this.gameFps * 10) / 10) + ' FPS';
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
        const settings: VideoSettingsSelection = { upscaleMultiplier: multiplier };
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
        onSurfaceSize: (w: number, h: number) => {
          this.surfaceW = w;
          this.surfaceH = h;
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
            onPickBios: () => { this.chooseBios(); },
            onPickGame: () => { this.chooseGame(); },
            onClearGame: () => { this.clearGame(); },
            onStart: () => { this.startBoot(); },
            onCheckJit: () => { this.checkJit(); },
            onExportLog: () => { this.exportLog(); },
            onOpenSettings: () => {
              this.showSettings = true;
              this.refreshControllers();
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
              Text(this.statusRunning ? `${this.gameFps.toFixed(0)} FPS` : this.statusStage)
                .fontSize(11)
                .fontColor(this.statusRunning ? OVERLAY_OK : OVERLAY_FG_DIM)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor(OVERLAY_BG)
                .borderRadius(12)

              Button('存档')
                .width(this.ballBtnW()).height(32).fontSize(12)
                .backgroundColor(OVERLAY_BG)
                .fontColor(OVERLAY_FG)
                .borderRadius(16)
                .onClick(() => {
                  this.refreshSaveSlots();
                  this.saveMessage = '';
                  this.showSavePanel = true;
                  this.overlayExpanded = false;
                })

              Button(this.showPad ? '隐藏按键' : '显示按键')
                .width(this.ballBtnW()).height(32).fontSize(12)
                .backgroundColor(OVERLAY_BG)
                .fontColor(this.showPad ? OVERLAY_ACCENT : OVERLAY_FG)
                .borderRadius(16)
                .onClick(() => {
                  this.showPad = !this.showPad;
                  this.overlayExpanded = false;
                })

              Button('设置')
                .width(this.ballBtnW()).height(32).fontSize(12)
                .backgroundColor(OVERLAY_BG)
                .fontColor(OVERLAY_FG)
                .borderRadius(16)
                .onClick(() => {
                  this.showSettings = true;
                  this.overlayExpanded = false;
                })

              Button('返回')
                .width(this.ballBtnW()).height(32).fontSize(12)
                .backgroundColor(OVERLAY_BG)
                .fontColor(OVERLAY_FG)
                .borderRadius(16)
                .onClick(() => { this.exitGame(); })

              Button('收起')
                .width(this.ballBtnW()).height(28).fontSize(11)
                .backgroundColor(OVERLAY_BG)
                .fontColor(OVERLAY_FG_DIM)
                .borderRadius(14)
                .onClick(() => { this.overlayExpanded = false; })
            }
            .padding(8)
            .backgroundColor(OVERLAY_BG)
            .borderRadius(Theme.radius)
            .position({ x: this.ballLeft(), y: this.ballTop() })
          } else {
            // ---- 收起态：FPS 悬浮球（可拖动）----
            Column({ space: 1 }) {
              Text(this.statusRunning ? this.gameFps.toFixed(0) : '--')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.statusRunning ? OVERLAY_OK : OVERLAY_FG_DIM)
              Text('FPS')
                .fontSize(8)
                .fontColor(OVERLAY_FG_DIM)
            }
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
                .onClick(() => { this.showSettings = false; })
            }
            .width('100%')

          Scroll() {
            Column({ space: Theme.gap }) {
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
        .onClick(() => { this.showSettings = false; })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bgBase())
  }
}
