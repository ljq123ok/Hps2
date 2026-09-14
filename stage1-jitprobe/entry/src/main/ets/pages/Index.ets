/*
 * Hps2 —— JIT 能力自检与诊断界面
 *
 * 产品决策（用户明确要求）：
 *   **不做降级**。PS2 模拟器离开 JIT 没有意义，因此当 JIT 不可用时，
 *   界面不提供"以解释器继续"之类的降级入口，而是**明确告诉用户
 *   当前不可用、以及具体该怎么操作到可用**。
 *
 * 界面分三态：
 *   1. 自检中
 *   2. JIT 不可用  -> 显示原因 + 可操作引导（主界面）
 *   3. JIT 可用    -> 显示返回值 123 + 完整测试明细
 */
import hilog from '@ohos.hilog';
import jitprobe from 'libjitprobe.so';

const DOMAIN = 0x3201;
const TAG = 'HPS2_JIT';

interface StepResult {
  name: string;
  ok: boolean;
  detail: string;
}

interface SelfCheck {
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
  @State platformInfo: string = '(未读取)';
  @State summary: string = '';
  @State steps: StepResult[] = [];
  @State running: boolean = false;
  @State basicReturn: string = '-';
  @State check: SelfCheck | null = null;
  @State checking: boolean = true;

  aboutToAppear(): void {
    this.platformInfo = jitprobe.platformInfo();
    hilog.info(DOMAIN, TAG, 'platform: %{public}s', this.platformInfo);
    this.recheck();
  }

  // 重跑自检。用户按引导操作（如重启）后点「重新检测」即走这里。
  private recheck(): void {
    this.checking = true;
    this.steps = [];
    this.summary = '';
    this.basicReturn = '-';
    try {
      const raw: string = jitprobe.selfCheck();
      this.check = JSON.parse(raw) as SelfCheck;
      hilog.info(DOMAIN, TAG, 'selfCheck: %{public}s', raw);
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, 'selfCheck 异常: %{public}s', err.message);
      this.check = {
        available: false, stage: -1, stageName: 'exception', errno: -1,
        message: '自检过程抛出异常: ' + err.message,
        action: '请反馈此错误。'
      };
    }
    this.checking = false;
    // 可用时才继续跑完整测试集
    if (this.check !== null && this.check.available) {
      this.runFullTests();
    }
  }

  private runFullTests(): void {
    this.running = true;
    try {
      const s: string = jitprobe.runAll();
      this.summary = s;
      const m = s.match(/basicReturn=(-?\d+)/);
      this.basicReturn = m ? m[1] : '(无)';
      const raw: string = jitprobe.getSteps();
      this.steps = JSON.parse(raw) as StepResult[];
      hilog.info(DOMAIN, TAG, 'summary: %{public}s', s);
    } catch (e) {
      const err = e as Error;
      this.summary = '测试抛出异常: ' + err.message;
      hilog.error(DOMAIN, TAG, 'exception: %{public}s', err.message);
    }
    this.running = false;
  }

  private passCount(): number {
    let n = 0;
    for (const s of this.steps) {
      if (s.ok) {
        n++;
      }
    }
    return n;
  }

  @Builder
  stepRow(s: StepResult) {
    Row() {
      Text(s.ok ? '✔' : '✘')
        .fontSize(18)
        .fontColor(s.ok ? '#16A34A' : '#DC2626')
        .width(28)
      Column() {
        Text(s.name).fontSize(14).fontWeight(FontWeight.Medium).width('100%')
        Text(s.detail).fontSize(12).fontColor('#6B7280').width('100%').margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(10)
    .backgroundColor(s.ok ? '#F0FDF4' : '#FEF2F2')
    .borderRadius(8)
    .margin({ bottom: 6 })
  }

  // ---------- 三态之一：自检中 ----------
  @Builder
  checkingView() {
    Column() {
      LoadingProgress().width(64).height(64).color('#2563EB')
      Text('正在检测 JIT 能力…').fontSize(15).margin({ top: 16 })
    }
    .width('100%').layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  // ---------- 三态之二：JIT 不可用（引导用户操作到可用）----------
  @Builder
  unavailableView() {
    Column() {
      Text('⛔')
        .fontSize(56)
        .margin({ bottom: 8 })
      Text('JIT 当前不可用')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor('#DC2626')
        .margin({ bottom: 6 })
      Text('Hps2 是 PS2 模拟器，必须先获得 JIT 支持才能运行。\n为此不做降级处理，请先让 JIT 恢复可用。')
        .fontSize(12)
        .fontColor('#6B7280')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 18 })

      // 失败详情
      Column() {
        Row() {
          Text('检测详情').fontSize(13).fontWeight(FontWeight.Medium)
          Blank()
        }.width('100%')
        Text(`失败阶段：${this.check ? this.check.stageName : '-'}`)
          .fontSize(12).fontColor('#374151').width('100%').margin({ top: 6 })
        Text(`错误码：errno=${this.check ? this.check.errno : '-'}（EINVAL 表示系统拒绝了可执行内存请求）`)
          .fontSize(11).fontColor('#6B7280').width('100%').margin({ top: 4 })
        Text(this.check ? this.check.message : '')
          .fontSize(12).fontColor('#374151').width('100%').margin({ top: 6 })
      }
      .width('100%').padding(12)
      .backgroundColor('#FEF2F2')
      .borderRadius(8)
      .border({ width: 1, color: '#FECACA' })
      .margin({ bottom: 14 })

      // 操作指引
      Column() {
        Row() {
          Text('请按以下步骤操作').fontSize(13).fontWeight(FontWeight.Medium)
          Blank()
        }.width('100%')
        Text(this.check ? this.check.action : '')
          .fontSize(13).fontColor('#1F2937').width('100%').margin({ top: 8 })

        Divider().margin({ top: 12, bottom: 12 })

        Text('① 重启手机')
          .fontSize(13).fontWeight(FontWeight.Medium).width('100%')
        Text('长按电源键 → 重启。已实测：重启后 JIT 即恢复可用。')
          .fontSize(11).fontColor('#6B7280').width('100%').margin({ top: 2, bottom: 10 })

        Text('② 保持设备处于开发者模式')
          .fontSize(13).fontWeight(FontWeight.Medium).width('100%')
        Text('设置 → 系统和更新 → 开发者选项 → 保持开启。')
          .fontSize(11).fontColor('#6B7280').width('100%').margin({ top: 2, bottom: 10 })

        Text('③ 关闭坚盾守护模式')
          .fontSize(13).fontWeight(FontWeight.Medium).width('100%')
        Text('设置 → 隐私和安全 → 坚盾守护模式 → 关闭。\n该模式会系统级禁用 JIT，且对已授权应用同样生效。')
          .fontSize(11).fontColor('#6B7280').width('100%').margin({ top: 2 })
      }
      .width('100%').padding(14)
      .backgroundColor('#FFFFFF')
      .borderRadius(10)
      .border({ width: 1, color: '#E5E7EB' })
      .margin({ bottom: 16 })

      Button('重新检测')
        .width('100%')
        .onClick(() => this.recheck())
    }
    .width('100%').layoutWeight(1)
    .justifyContent(FlexAlign.Start)
    .padding(16)
  }

  // ---------- 三态之三：JIT 可用 ----------
  @Builder
  availableView() {
    Column() {
      Column() {
        Text('生成代码的返回值').fontSize(12).fontColor('#6B7280')
        Text(this.basicReturn)
          .fontSize(44).fontWeight(FontWeight.Bold)
          .fontColor(this.basicReturn === '123' ? '#16A34A' : '#DC2626')
        Text(this.basicReturn === '123'
          ? '✔ JIT 可用 —— 与期望值 123 一致'
          : '返回值异常，请查看下方明细')
          .fontSize(11).fontColor('#6B7280').textAlign(TextAlign.Center)
      }
      .width('100%').padding(16)
      .backgroundColor('#FFFFFF').borderRadius(12)
      .border({ width: 1, color: '#E5E7EB' })
      .margin({ bottom: 12 })

      Row() {
        Text(`通过 ${this.passCount()} / ${this.steps.length}`)
          .fontSize(12).fontColor('#374151')
        Blank()
        Button('重新检测').fontSize(12).height(30).onClick(() => this.recheck())
      }.width('100%').margin({ bottom: 8 })

      if (this.steps.length > 0) {
        List() {
          ForEach(this.steps, (s: StepResult) => {
            ListItem() { this.stepRow(s) }
          }, (s: StepResult) => s.name)
        }.layoutWeight(1).width('100%')
      } else {
        Blank().layoutWeight(1)
      }
    }
    .width('100%').layoutWeight(1)
  }

  build() {
    Column() {
      Text('Hps2')
        .fontSize(20).fontWeight(FontWeight.Bold).width('100%')
      Text(`设备：${this.platformInfo}`)
        .fontSize(11).fontColor('#6B7280').width('100%').margin({ top: 2, bottom: 12 })

      if (this.checking) {
        this.checkingView()
      } else if (this.check !== null && !this.check.available) {
        this.unavailableView()
      } else {
        this.availableView()
      }
    }
    .width('100%').height('100%').padding(16)
    .backgroundColor('#F9FAFB')
  }
}
