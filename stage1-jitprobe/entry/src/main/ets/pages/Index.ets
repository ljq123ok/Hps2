/*
 * HPS2 阶段 1：JIT 探针界面
 *
 * 界面上必须能一眼看到：
 *   - 生成代码的实际返回值（任务书要求必须显示 123）
 *   - 每一步的通过/失败与失败原因（errno）
 *   - 平台事实（arch / 页大小 / 是否 OHOS 目标）
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

@Entry
@Component
struct Index {
  @State platformInfo: string = '(未读取)';
  @State summary: string = '';
  @State steps: StepResult[] = [];
  @State running: boolean = false;
  @State basicReturn: string = '-';

  aboutToAppear(): void {
    this.platformInfo = jitprobe.platformInfo();
    hilog.info(DOMAIN, TAG, 'platform: %{public}s', this.platformInfo);
    // 自动运行：探针的目的是产出结论，不应依赖人工点击。
    // 这样 hdc 部署后直接抓日志即可，人工查看也能看到同样结果。
    this.runTests();
  }

  private runTests(): void {
    this.running = true;
    this.steps = [];
    this.summary = '';
    try {
      const s: string = jitprobe.runAll();
      this.summary = s;
      // 从汇总里提取 basicReturn，单独大号显示
      const m = s.match(/basicReturn=(-?\d+)/);
      this.basicReturn = m ? m[1] : '(无)';
      const raw: string = jitprobe.getSteps();
      this.steps = JSON.parse(raw) as StepResult[];
      hilog.info(DOMAIN, TAG, 'summary: %{public}s', s);
    } catch (e) {
      const err = e as Error;
      this.summary = '探针抛出异常: ' + err.message;
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
        Text(s.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .width('100%')
        Text(s.detail)
          .fontSize(12)
          .fontColor('#6B7280')
          .width('100%')
          .margin({ top: 2 })
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

  build() {
    Column() {
      // 顶部标题
      Text('HPS2 · HarmonyOS JIT 能力探针')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .margin({ bottom: 4 })

      Text('阶段 1：验证三方 HAP 能否在真机上执行运行时生成的 AArch64 代码')
        .fontSize(12)
        .fontColor('#6B7280')
        .width('100%')
        .margin({ bottom: 12 })

      // 平台信息
      Column() {
        Row() {
          Text('平台事实').fontSize(13).fontWeight(FontWeight.Medium)
          Blank()
        }.width('100%')
        Text(this.platformInfo)
          .fontSize(11)
          .fontColor('#374151')
          .width('100%')
          .margin({ top: 4 })
      }
      .width('100%')
      .padding(10)
      .backgroundColor('#F3F4F6')
      .borderRadius(8)
      .margin({ bottom: 12 })

      // 核心结果：生成代码的返回值
      Column() {
        Text('生成代码的返回值').fontSize(12).fontColor('#6B7280')
        Text(this.basicReturn)
          .fontSize(44)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.basicReturn === '123' ? '#16A34A' : '#9CA3AF')
        Text(this.basicReturn === '123'
          ? '✔ 与期望值 123 一致 —— 真机 JIT 路径可用'
          : '尚未得到 123；请查看下方失败原因')
          .fontSize(11)
          .fontColor('#6B7280')
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .padding(16)
      .backgroundColor('#FFFFFF')
      .borderRadius(12)
      .border({ width: 1, color: '#E5E7EB' })
      .margin({ bottom: 12 })

      // 运行按钮
      Button(this.running ? '运行中…' : '运行全部测试')
        .width('100%')
        .enabled(!this.running)
        .onClick(() => this.runTests())
        .margin({ bottom: 12 })

      // 汇总
      if (this.summary.length > 0) {
        Column() {
          Text('汇总').fontSize(13).fontWeight(FontWeight.Medium).width('100%')
          Text(`通过 ${this.passCount()} / ${this.steps.length}`)
            .fontSize(12)
            .fontColor('#374151')
            .width('100%')
            .margin({ top: 4 })
          Text(this.summary)
            .fontSize(11)
            .fontColor('#6B7280')
            .width('100%')
            .margin({ top: 4 })
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#F9FAFB')
        .borderRadius(8)
        .margin({ bottom: 12 })
      }

      // 分步明细
      if (this.steps.length > 0) {
        Text('分步结果').fontSize(13).fontWeight(FontWeight.Medium)
          .width('100%').margin({ bottom: 6 })
        List() {
          ForEach(this.steps, (s: StepResult) => {
            ListItem() {
              this.stepRow(s)
            }
          }, (s: StepResult) => s.name)
        }
        .layoutWeight(1)
        .width('100%')
      } else {
        Blank().layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor('#F9FAFB')
  }
}
