/*
 * Hps2 — 首页（设置 / 游戏库）
 *
 * 设计来源：设计稿 02。
 *
 * 与旧前端的区别：
 *   旧版把「BIOS 选择 + 游戏选择 + 启动按钮 + 状态」全部堆在一屏，
 *   还和小小的游戏画面挤在一起 —— 用户反馈「不可游玩」。
 *   新版把设置与游玩**分开**：这个页面只管准备（选 BIOS / 选游戏），
 *   点「启动」后切到全屏游玩页（GameScreen）。
 */
import { Theme } from '../common/Theme';
import { StatusBar } from './StatusBar';

@Component
export struct HomeScreen {
  // ---- 由父组件持有的状态 ----
  @Prop biosName: string = '';
  @Prop gameName: string = '';
  @Prop picking: string = '';
  @Prop statusStage: string = '';
  @Prop statusError: string = '';
  @Prop busy: boolean = false;
  @Prop jitChecked: boolean = false;
  @Prop jitAvailable: boolean = false;
  @Prop jitMessage: string = '';
  @Prop jitAction: string = '';
  @Prop jitStage: string = '';
  @Prop jitErrno: number = 0;

  // ---- 事件回调 ----
  onPickBios?: () => void;
  onPickGame?: () => void;
  onClearGame?: () => void;
  onStart?: () => void;
  onCheckJit?: () => void;
  onOpenSettings?: () => void;

  /** 列表项通用样式 */
  @Builder
  pickRow(icon: string, title: string, value: string, hint: string,
          btnText: string, onTap: () => void, hasValue: boolean,
          onClear?: () => void) {
    Column({ space: 10 }) {
      Row() {
        Text(icon).fontSize(18).width(28)
        Column({ space: 2 }) {
          Text(title).fontSize(15).fontColor(Theme.textPri()).fontWeight(FontWeight.Medium)
          Text(hasValue ? value : hint)
            .fontSize(12)
            .fontColor(hasValue ? Theme.ok() : Theme.textDim())
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (hasValue && onClear) {
          Text('清除')
            .fontSize(12)
            .fontColor(Theme.accentHi())
            .padding(6)
            .onClick(() => { if (onClear) onClear(); })
        }
      }
      .width('100%')

      Button(btnText)
        .width('100%')
        .height(40)
        .fontSize(14)
        .backgroundColor(Theme.accent())
        .borderRadius(Theme.radiusSm)
        .onClick(onTap)
    }
    .width('100%')
    .padding(Theme.pad)
    .backgroundColor(Theme.bgCard())
    .borderRadius(Theme.radius)
    .border({ width: 1, color: Theme.border() })
  }

  @Builder
  jitCard() {
    Column({ space: 8 }) {
      Row() {
        Text('JIT 状态').fontSize(14).fontColor(Theme.textPri()).fontWeight(FontWeight.Medium)
        Blank()
        if (!this.jitChecked) {
          Text('未检测').fontSize(12).fontColor(Theme.textDim())
        } else {
          Text(this.jitAvailable ? '可用' : '不可用')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.jitAvailable ? Theme.ok() : Theme.err())
        }
      }
      .width('100%')

      if (this.jitChecked && !this.jitAvailable) {
        Text(this.jitMessage)
          .fontSize(12).fontColor(Theme.err()).width('100%')
        Text(this.jitAction)
          .fontSize(11).fontColor(Theme.textSec()).width('100%')
        Text(`诊断：阶段=${this.jitStage} errno=${this.jitErrno}`)
          .fontSize(11).fontColor(Theme.textDim()).width('100%')
        // 本项目实测：JIT 不可用有两种成因，处置不同
        // （见 docs/jit-regression.md 与 docs/jit-state-pollution.md）
        Text('提示：若曾用其它签名安装过本应用，请先完全卸载再重装。')
          .fontSize(11).fontColor(Theme.warn()).width('100%')
      } else if (this.jitChecked) {
        Text('已通过「申请 → 写入 → 提交可执行 → 执行并校验」完整往返')
          .fontSize(11).fontColor(Theme.textSec()).width('100%')
      } else {
        Text('尚未检测。JIT 是 PS2 模拟的性能前提。')
          .fontSize(11).fontColor(Theme.textSec()).width('100%')
      }

      if (!this.jitChecked || !this.jitAvailable) {
        Button('重新检测')
          .width('100%').height(34).fontSize(13)
          .backgroundColor(Theme.bgCardHi())
          .fontColor(Theme.textPri())
          .borderRadius(Theme.radiusSm)
          .onClick(() => { if (this.onCheckJit) this.onCheckJit(); })
      }
    }
    .width('100%')
    .padding(Theme.pad)
    .backgroundColor(this.jitChecked && !this.jitAvailable ? '#2A1518' : Theme.bgCard())
    .borderRadius(Theme.radius)
    .border({
      width: 1,
      color: this.jitChecked && !this.jitAvailable ? '#5B2A2F' : Theme.border()
    })
  }

  build() {
    Column() {
      // ---- 顶栏 ----
      Row() {
        Column({ space: 2 }) {
          Text('Hps2')
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPri())
          Text('PS2 模拟器')
            .fontSize(12)
            .fontColor(Theme.textDim())
        }
        .alignItems(HorizontalAlign.Start)

        Blank()

        Button('⚙')
          .width(40).height(40).fontSize(18)
          .backgroundColor(Theme.bgCard())
          .fontColor(Theme.textSec())
          .borderRadius(20)
          .onClick(() => { if (this.onOpenSettings) this.onOpenSettings(); })
      }
      .width('100%')
      .padding({ left: Theme.pad, right: Theme.pad, top: 14, bottom: 14 })

      // ---- 内容（可滚动）----
      Scroll() {
        Column({ space: Theme.gap }) {
          this.jitCard()

          this.pickRow('💿', 'BIOS', this.biosName,
            '需要你自己合法拥有的 PS2 BIOS（4MB）',
            this.picking === 'bios' ? '处理中…' : '选择 BIOS 文件',
            () => { if (this.onPickBios) this.onPickBios(); },
            this.biosName.length > 0)

          this.pickRow('🎮', '游戏镜像', this.gameName,
            '可选 —— 不选则只启动 BIOS',
            this.picking === 'game' ? '处理中…' : '选择游戏镜像',
            () => { if (this.onPickGame) this.onPickGame(); },
            this.gameName.length > 0,
            () => { if (this.onClearGame) this.onClearGame(); })

          // ---- 启动按钮 ----
          Button(this.statusRunning0 ? '启动中…' : (this.gameName.length > 0 ? '启动游戏' : '启动 BIOS'))
            .width('100%')
            .height(52)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .backgroundColor(this.biosName.length > 0 ? Theme.accent() : Theme.bgCardHi())
            .fontColor(this.biosName.length > 0 ? '#FFFFFF' : Theme.textDim())
            .borderRadius(Theme.radius)
            .enabled(this.biosName.length > 0 && !this.busy)
            .onClick(() => { if (this.onStart) this.onStart(); })

          if (this.statusError.length > 0) {
            Column({ space: 6 }) {
              Text('错误').fontSize(13).fontColor(Theme.err()).fontWeight(FontWeight.Medium)
              Text(this.statusError).fontSize(12).fontColor(Theme.err())
            }
            .width('100%')
            .padding(Theme.pad)
            .backgroundColor(Theme.panelErrBg())
            .borderRadius(Theme.radius)
            .border({ width: 1, color: Theme.panelErrBd() })
          }

          // ---- 法律声明 ----
          Column({ space: 6 }) {
            Text('⚠ 关于 BIOS').fontSize(12).fontColor(Theme.warn()).width('100%')
            Text('本应用不内置、不分发 BIOS。请使用你自行合法拥有的 PS2 BIOS 文件。\n' +
                 '应用只读取你主动选择的文件，并复制到应用私有目录中使用。')
              .fontSize(11).fontColor(Theme.textSec()).width('100%')
          }
          .width('100%')
          .padding(Theme.pad)
          .backgroundColor(Theme.panelWarnBg())
          .borderRadius(Theme.radius)
          .border({ width: 1, color: Theme.panelWarnBd() })

          Blank().height(20)
        }
        .width('100%')
        .padding({ left: Theme.pad, right: Theme.pad })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      // ---- 底部状态栏 ----
      StatusBar({
        jitChecked: this.jitChecked,
        jitAvailable: this.jitAvailable,
        biosReady: this.biosName.length > 0,
        gameReady: this.gameName.length > 0,
        running: false
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bgBase())
  }

  // 占位：启动中的显示由父组件通过 statusStage 传达
  private get statusRunning0(): boolean {
    return this.statusStage === 'starting-thread' || this.statusStage === 'reserving-memory';
  }
}
