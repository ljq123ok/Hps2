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
    // 确保 bios 目录存在
    try {
      const dir = this.biosDir();
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
      hilog.info(DOMAIN, TAG, 'biosDir=%{public}s', dir);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'mkdir bios dir failed: %{public}s', JSON.stringify(e));
    }
    this.refreshStatus();
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
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
      // 从 URI 末段取文件名
      const segs = srcUri.split('/');
      const fileName = segs[segs.length - 1] || 'bios.bin';
      const destPath = this.biosDir() + '/' + fileName;

      hilog.info(DOMAIN, TAG, 'copying BIOS from uri to %{public}s', destPath);
      fs.copyFileSync(srcUri, destPath);

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
