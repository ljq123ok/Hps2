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

  // 通过系统文件管理器选择 BIOS，并复制进沙箱
  private async chooseBios(): Promise<void> {
    this.busy = true;
    try {
      const ctx = getContext(this);
      const options = new picker.DocumentSelectOptions();
      // PS2 BIOS 常见为 .bin / .rom / .BIN
      options.fileSuffixFilters = ['.bin', '.BIN', '.rom', '.ROM', '.p2b'];

      const docPicker = new picker.DocumentViewPicker(ctx);
      const uris: Array<string> = await docPicker.select(options);

      if (!uris || uris.length === 0) {
        hilog.info(DOMAIN, TAG, 'user cancelled BIOS selection');
        this.busy = false;
        return;
      }

      const srcUri = uris[0];
      hilog.info(DOMAIN, TAG, 'selected uri=%{public}s', srcUri);

      // 从 URI 末段取文件名（去掉可能的查询串）
      const clean = srcUri.split('?')[0];
      const segs = clean.split('/');
      const fileName = decodeURIComponent(segs[segs.length - 1]) || 'bios.bin';
      const destPath = this.biosDir() + '/' + fileName;
      hilog.info(DOMAIN, TAG, 'dest path=%{public}s', destPath);

      // 用 fd 方式复制：先以只读打开源 URI 拿到 fd，再写入目标。
      // 直接 copyFileSync(uri, path) 在某些 picker URI 上会报
      // ENOENT（No such file or directory），因为 URI 需要先经
      // 文件系统解析成 fd。fd 方式更稳。
      let srcFile: fs.File | null = null;
      let dstFile: fs.File | null = null;
      try {
        srcFile = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
        hilog.info(DOMAIN, TAG, 'src fd=%{public}d', srcFile.fd);

        // 目标：先删掉可能存在的旧文件，避免复制到自己的怪异情况
        if (fs.accessSync(destPath)) {
          fs.unlinkSync(destPath);
        }
        dstFile = fs.openSync(destPath,
          fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        hilog.info(DOMAIN, TAG, 'dst fd=%{public}d', dstFile.fd);

        fs.copyFileSync(srcFile.fd, dstFile.fd);
      } finally {
        if (srcFile !== null) {
          fs.closeSync(srcFile);
        }
        if (dstFile !== null) {
          fs.closeSync(dstFile);
        }
      }

      // 校验：PS2 BIOS 通常为 4MB
      const stat = fs.statSync(destPath);
      hilog.info(DOMAIN, TAG, 'BIOS copied, size=%{public}d', stat.size);

      this.biosPath = destPath;
      this.biosName = fileName + ' (' + this.humanSize(stat.size) + ')';
      this.statusError = '';
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'chooseBios failed: %{public}s', JSON.stringify(err));
      this.statusError = '选择 BIOS 失败：' + (err.message ? err.message : JSON.stringify(err));
    }
    this.busy = false;
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
      const ok: number = hps2core.startBios(this.dataRoot(), this.biosDir());
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
      Text('HarmonyOS PS2 模拟器 · 阶段 2 核心接入验证')
        .fontSize(11).fontColor('#6B7280').width('100%').margin({ top: 2, bottom: 14 })

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

        Button(this.busy ? '处理中…' : '选择 BIOS 文件')
          .width('100%').enabled(!this.busy)
          .onClick(() => { this.chooseBios(); })
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
        Button('启动核心')
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
