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
import hps2core from 'libhps2core.so';
import { Theme } from '../common/Theme';
import { HomeScreen } from '../components/HomeScreen';
import { GameScreen } from '../components/GameScreen';
import { StatusBar } from '../components/StatusBar';

const DOMAIN = 0x3202;
const TAG = 'HPS2_CORE';

interface BootStatus {
  stage: number;
  stageName: string;
  running: boolean;
  error: string;
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
  @State statusError: string = '';
  @State statusRunning: boolean = false;
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
  /** 画面比例：0=自动 1=保持4:3 2=铺满 3=宽屏16:9 */
  @State aspectMode: number = 0;

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

  aboutToAppear(): void {
    // 让 native 侧与 UI 的初始比例一致（默认「自动」）。
    try {
      this.aspectMode = hps2core.getAspectMode();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getAspectMode failed');
    }
    try {
      const dir = this.biosDir();
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
      hilog.info(DOMAIN, TAG, 'biosDir=%{public}s', dir);
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
    // PS2 BIOS 常见后缀：.bin / .rom，也有无后缀的
    const r = await this.pickAndCopy('bios',
      ['.bin', '.BIN', '.rom', '.ROM', '.p2b'], this.biosDir());
    if (r.length > 0) {
      const parts = r.split('|');
      this.biosPath = parts[0];
      this.biosName = parts[1] + ' (' + parts[2] + ')';
    }
  }

  private async chooseGame(): Promise<void> {
    // PS2 游戏镜像常见格式
    const r = await this.pickAndCopy('game',
      ['.iso', '.ISO', '.chd', '.CHD', '.bin', '.BIN', '.img', '.IMG', '.gz'],
      this.gameDir());
    if (r.length > 0) {
      const parts = r.split('|');
      this.gamePath = parts[0];
      this.gameName = parts[1] + ' (' + parts[2] + ')';
    }
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

  private startBoot(): void {
    if (!this.biosPath) {
      this.statusError = '请先选择 BIOS 文件';
      return;
    }

    // JIT 硬门禁（UI 侧前置）：不可用时不发起启动。
    // native 侧还有一道权威门禁，这里是为了给出即时、明确的反馈。
    // 刻意**不做降级**：不提供"用解释器模式继续"之类的选项。
    if (this.jitChecked && !this.jitAvailable) {
      this.statusError = `JIT 不可用，已拒绝启动。${this.jitMessage} ${this.jitAction}`;
      return;
    }

    this.statusError = '';
    try {
      const ok: number = hps2core.startBios(this.dataRoot(), this.biosDir(), this.gamePath);
      hilog.info(DOMAIN, TAG, 'startBios returned %{public}d', ok);
      if (ok !== 1) {
        this.statusError = '核心启动被拒绝，详见日志（tag=HPS2_CORE）';
      }
      // 启动成功后只**挂载**虚拟手柄，不做按键映射。
      //
      // 映射必须等 VM 初始化完成（输入源懒创建）——
      // 那段逻辑已移到 native 的 VM 线程里（napi_init.cpp 的 VMThreadMain，
      // 在 VMManager::Initialize() 之后），因为在那之前调用会让
      // InputManager::GetGenericBindingMapping() 解引用空指针而闪退。
      this.setupVirtualPad();

      // 启动后刷新一次 JIT 状态：native 的硬门禁可能刚判过一次。
      this.syncJitFromStatus();
      this.startPolling();
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'startBios exception: %{public}s', err.message);
      this.statusError = '调用核心失败：' + err.message;
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
      this.statusError = st.error ? st.error : this.statusError;
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

  /**
   * 设置画面比例并立即生效。
   *
   * native 侧会改 GSConfig.AspectRatio 并调 MTGS::ApplySettings()，
   * 使配置在运行期即时生效（无需重启 VM）。
   * 机制依据：GSRenderer.cpp:412 的 CalculateDrawDstRect 里
   * targetAr 默认取窗口比例，而 Stretch 不在任何分支中 => 铺满。
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
      if (this.viewMode === 'home') {
        HomeScreen({
          biosName: this.biosName,
          gameName: this.gameName,
          picking: this.picking,
          statusStage: this.statusStage,
          statusError: this.statusError,
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
          onOpenSettings: () => { this.showSettings = true; }
        })
      } else {
        // 游玩页：全屏画面 + 虚拟按键 + 悬浮退出按钮
        Stack({ alignContent: Alignment.TopEnd }) {
          GameScreen({
            playing: true,
            showPad: this.showPad,
            onSurfaceSize: (w: number, h: number) => {
              this.surfaceW = w;
              this.surfaceH = h;
            }
          })

          // 悬浮控制条：游玩时不显示设置项，只留必要操作
          Row({ space: 10 }) {
            Text(this.statusRunning ? `运行中` : this.statusStage)
              .fontSize(11)
              .fontColor(this.statusRunning ? Theme.ok() : Theme.textSec())
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor(Theme.overlayChip())
              .borderRadius(14)

            Button('按键')
              .height(30).fontSize(12)
              .backgroundColor(Theme.overlayChip())
              .fontColor(this.showPad ? Theme.accentHi() : Theme.textSec())
              .borderRadius(15)
              .onClick(() => { this.showPad = !this.showPad; })

            Button('返回')
              .height(30).fontSize(12)
              .backgroundColor(Theme.overlayChip())
              .fontColor(Theme.textPri())
              .borderRadius(15)
              .onClick(() => { this.stopBoot(); this.viewMode = 'home'; })
          }
          .padding(10)
        }
        .width('100%')
        .height('100%')
      }

      // ---- 设置弹层 ----
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

            // ---- 画面比例 ----
            Column({ space: 10 }) {
              Text('画面比例').fontSize(14).fontColor(Theme.textPri()).width('100%')
              Text('PS2 原生为 4:3。横屏时拉伸不明显，竖屏拉伸较明显。')
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
                .onClick(() => { this.setAspect(m); })
              })
            }
            .width('100%')
            .padding(Theme.pad)
            .backgroundColor(Theme.bgCard())
            .borderRadius(Theme.radius)
            .border({ width: 1, color: Theme.border() })

            Text('提示：接入手柄后建议关闭虚拟按键，避免遮挡画面。')
              .fontSize(11).fontColor(Theme.textDim()).width('100%')

            Blank()
          }
          .width('85%')
          .height('70%')
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
