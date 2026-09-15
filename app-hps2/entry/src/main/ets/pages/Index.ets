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

const DOMAIN = 0x3202;
const TAG = 'HPS2_CORE';

interface BootStatus {
  stage: number;
  stageName: string;
  running: boolean;
  error: string;
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
    this.statusError = '';
    try {
      const ok: number = hps2core.startBios(this.dataRoot(), this.biosDir(), this.gamePath);
      hilog.info(DOMAIN, TAG, 'startBios returned %{public}d', ok);
      if (ok !== 1) {
        this.statusError = '核心启动被拒绝，详见日志（tag=HPS2_CORE）';
      }
      this.startPolling();
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'startBios exception: %{public}s', err.message);
      this.statusError = '调用核心失败：' + err.message;
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

  private stopBoot(): void {
    try {
      hps2core.stop();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'stop failed: %{public}s', JSON.stringify(e));
    }
    this.refreshStatus();
  }

  @Builder
  statusView() {
    Column() {
      Text(`阶段：${this.statusStage}`)
        .fontSize(13).fontColor('#374151').width('100%')
      Text(this.statusRunning ? '运行中' : '未运行')
        .fontSize(11).fontColor(this.statusRunning ? '#16A34A' : '#9CA3AF')
        .width('100%').margin({ top: 2 })
    }
    .width('100%').padding(12)
    .backgroundColor('#F3F4F6').borderRadius(8)
  }

  build() {
    Column() {
      Text('Hps2').fontSize(22).fontWeight(FontWeight.Bold).width('100%')
      Text('HarmonyOS PS2 模拟器')
        .fontSize(11).fontColor('#6B7280').width('100%').margin({ top: 2, bottom: 10 })

      // 游戏画面显示区。
      // XComponent 的 surface 就是 GS 的渲染目标；native 侧通过
      // setSurface() 把它交给 EGL/OpenGL。
      Column() {
        XComponent({
          id: 'hps2_view',
          type: XComponentType.SURFACE,
          controller: this.xcController
        })
          .width('100%')
          .height('100%')
          .onLoad(() => {
            hilog.info(DOMAIN, TAG, 'XComponent onLoad');
            // onLoad 时 surface 已就绪，但尺寸可能还没定；
            // onSurfaceChanged 会再给一次准确尺寸。
            if (this.surfaceW > 0 && this.surfaceH > 0) {
              this.pushSurface(this.surfaceW, this.surfaceH);
            }
          })
          .onDestroy(() => {
            hilog.info(DOMAIN, TAG, 'XComponent onDestroy');
            this.surfaceReady = false;
          })
      }
      .width('100%')
      .aspectRatio(4 / 3)          // PS2 输出为 4:3
      .backgroundColor('#000000')
      .borderRadius(8)
      .clip(true)
      .margin({ bottom: 10 })
      .onAreaChange((_, area) => {
        // 布局尺寸确定后把 surface 尺寸同步给 native
        const w = Number(area.width);
        const h = Number(area.height);
        this.surfaceW = w;
        this.surfaceH = h;
        if (w > 0 && h > 0) {
          this.pushSurface(w, h);
        }
      })

      // BIOS 选择区
      Column() {
        Row() {
          Text('BIOS').fontSize(14).fontWeight(FontWeight.Medium)
          Blank()
        }.width('100%')
        Text(this.biosName.length > 0 ? this.biosName : '尚未选择')
          .fontSize(12)
          .fontColor(this.biosName.length > 0 ? '#16A34A' : '#9CA3AF')
          .width('100%').margin({ top: 6, bottom: 10 })

        Button(this.picking === 'bios' ? '处理中…' : '选择 BIOS 文件')
          .width('100%').enabled(this.picking === '')
          .onClick(() => { this.chooseBios(); })
      }
      .width('100%').padding(14)
      .backgroundColor('#FFFFFF').borderRadius(10)
      .border({ width: 1, color: '#E5E7EB' })
      .margin({ bottom: 12 })

      // 游戏镜像选择（可选）
      Column() {
        Row() {
          Text('游戏镜像（可选）').fontSize(14).fontWeight(FontWeight.Medium)
          Blank()
          if (this.gameName.length > 0) {
            Text('清除')
              .fontSize(12).fontColor('#2563EB')
              .onClick(() => this.clearGame())
          }
        }.width('100%')
        Text(this.gameName.length > 0 ? this.gameName : '未选择 —— 将只启动 BIOS')
          .fontSize(12)
          .fontColor(this.gameName.length > 0 ? '#16A34A' : '#9CA3AF')
          .width('100%').margin({ top: 6, bottom: 10 })

        Button(this.picking === 'game' ? '处理中…' : '选择游戏镜像')
          .width('100%').enabled(this.picking === '')
          .onClick(() => { this.chooseGame(); })
      }
      .width('100%').padding(14)
      .backgroundColor('#FFFFFF').borderRadius(10)
      .border({ width: 1, color: '#E5E7EB' })
      .margin({ bottom: 12 })

      // 合法性提示（必须显著）
      Column() {
        Text('⚠ 关于 BIOS')
          .fontSize(12).fontWeight(FontWeight.Medium).width('100%')
        Text('本应用不内置、不分发 BIOS。请使用你自行合法拥有的 PS2 BIOS 文件。\n' +
             '应用只读取你主动选择的文件，并复制到应用私有目录中使用。')
          .fontSize(11).fontColor('#6B7280').width('100%').margin({ top: 4 })
      }
      .width('100%').padding(12)
      .backgroundColor('#FFFBEB').borderRadius(8)
      .border({ width: 1, color: '#FDE68A' })
      .margin({ bottom: 12 })

      // 运行控制
      Row() {
        Button(this.gamePath.length > 0 ? '启动游戏' : '启动 BIOS')
          .layoutWeight(1)
          .enabled(this.biosPath.length > 0 && !this.statusRunning)
          .onClick(() => this.startBoot())
        Blank().width(10)
        Button('停止')
          .layoutWeight(1)
          .enabled(this.statusRunning)
          .onClick(() => this.stopBoot())
      }
      .width('100%').margin({ bottom: 12 })

      this.statusView()

      if (this.statusError.length > 0) {
        Column() {
          Text('错误').fontSize(12).fontWeight(FontWeight.Medium).width('100%')
          Text(this.statusError).fontSize(11).fontColor('#DC2626').width('100%').margin({ top: 4 })
        }
        .width('100%').padding(12)
        .backgroundColor('#FEF2F2').borderRadius(8)
        .border({ width: 1, color: '#FECACA' })
        .margin({ top: 12 })
      }

      Blank().layoutWeight(1)
    }
    .width('100%').height('100%').padding(16)
    .backgroundColor('#F9FAFB')
  }
}
