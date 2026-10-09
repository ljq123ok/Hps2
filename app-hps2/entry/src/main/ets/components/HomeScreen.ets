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
import { GameEntry, gameDisplayTitle, gameDisplaySubtitle, compatibilityLabel } from '../common/GameLibrary';
import { StatusBar } from './StatusBar';

@Component
export struct HomeScreen {
  // ---- 由父组件持有的状态 ----
  @Prop biosName: string = '';
  @Prop gameName: string = '';
  @Prop picking: string = '';
  @Prop statusStage: string = '';
  @Prop statusError: string = '';
  /** 失败类别标签（改进 1）；空则只显示原始错误 */
  @Prop errorKindLabel: string = '';
  @Prop errorAdvice: string = '';
  /** BIOS 规格检查（改进 2） */
  @Prop biosCheckChecked: boolean = false;
  @Prop biosCheckMessage: string = '';
  @Prop biosCheckSuspicious: boolean = false;
  /** 日志导出反馈（改进 3） */
  @Prop logExportMessage: string = '';
  @Prop busy: boolean = false;
  @Prop jitChecked: boolean = false;
  @Prop jitAvailable: boolean = false;
  @Prop jitMessage: string = '';
  @Prop jitAction: string = '';
  @Prop jitStage: string = '';
  @Prop jitErrno: number = 0;
  @Prop jitDiagnostics: string = '{}';
  @Prop jitPrctlExperimentResult: string = '';
  @Prop storeBuild: boolean = false;
  @Prop executionMode: string = 'unknown';
  @Prop degraded: boolean = false;
  /** 游戏本体识别（运行中由 native 上报；未启动时为空串） */
  @Prop discSerial: string = '';
  @Prop discTitle: string = '';
  @Prop discCRC: string = '';
  /** 游戏库列表（games/ 目录下的镜像元数据） */
  @Prop games: Array<GameEntry> = [];
  /** 游戏库是否正在扫描 */
  @Prop gamesScanning: boolean = false;
  /** 当前已选中的游戏路径（用于在列表里高亮） */
  @Prop currentGamePath: string = '';
  /** path -> 本地封面文件路径（有封面的项才在表里）*/
  @Prop coverPaths: Map<string, string> = new Map();
  /** 正在下载封面的游戏路径 */
  @Prop coverBusy: Set<string> = new Set();
  /** 封面操作的结果说明 */
  @Prop coverMessage: string = '';
  /** 当前封面源的显示名（用于按钮文案）*/
  @Prop coverSourceName: string = '';

  // ---- 事件回调 ----
  onPickBios?: () => void;
  onPickGame?: () => void;
  onClearGame?: () => void;
  /** 从游戏库列表选中一项 */
  onSelectGame?: (g: GameEntry) => void;
  /** 重新扫描游戏库 */
  onRefreshGames?: () => void;
  /** 为所有缺封面的游戏下载 */
  onDownloadCovers?: () => void;
  /** 只为指定游戏下载封面 */
  onDownloadCoverFor?: (g: GameEntry) => void;
  /** 打开指定游戏的独立设置 */
  onOpenPerGameSettings?: (g: GameEntry) => void;
  /** 打开封面源设置 */
  onOpenCoverSources?: () => void;
  onStart?: () => void;
  onCheckJit?: () => void;
  onJitPrctlExperiment?: () => void;
  onOpenSettings?: () => void;
  onExportLog?: () => void;


  /**
   * 游戏库列表。
   *
   * 【为什么要有它】此前只能保存**一个**游戏（gameName/gamePath），
   * 换一个就得重新走一遍文件选择器 + 复制。现在把 games/ 目录里已有的
   * 镜像都列出来，点一下即可切换。
   *
   * 扫描由 native 完成（serial/title/CRC 来自镜像内 ELF 头），
   * 故列表内容可能滞后于目录 —— 提供"重新扫描"按钮手动刷新。
   */
  @Builder
  gameLibrary() {
    Column({ space: 8 }) {
      Row() {
        Text('游戏库').fontSize(15).fontColor(Theme.textPri()).fontWeight(FontWeight.Medium)
        Blank()
        if (this.gamesScanning) {
          Text('扫描中…').fontSize(12).fontColor(Theme.textDim())
        } else {
          Text(`${this.games.length} 个`)
            .fontSize(12).fontColor(Theme.textDim())
        }
        Text('重新扫描')
          .fontSize(12)
          .fontColor(Theme.accentHi())
          .padding({ left: 10, top: 4, bottom: 4 })
          .onClick(() => { if (this.onRefreshGames) this.onRefreshGames(); })
      }
      .width('100%')

      // ---- 封面：下载 + 源选择 ----
      Row({ space: 8 }) {
        Text(this.coverSourceName.length > 0
          ? `封面源：${this.coverSourceName}`
          : '封面源：未配置')
          .fontSize(11).fontColor(Theme.textDim())
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('源设置')
          .fontSize(11).fontColor(Theme.accentHi())
          .padding(4)
          .onClick(() => { if (this.onOpenCoverSources) this.onOpenCoverSources(); })
        Text('下载缺失封面')
          .fontSize(11).fontColor(Theme.accentHi())
          .padding(4)
          .onClick(() => { if (this.onDownloadCovers) this.onDownloadCovers(); })
      }
      .width('100%')

      if (this.coverMessage.length > 0) {
        Text(this.coverMessage)
          .fontSize(10).fontColor(Theme.textDim())
          .width('100%').maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      if (this.games.length === 0) {
        Text(this.gamesScanning
          ? '正在扫描游戏目录…'
          : '还没有游戏镜像。用上面的「选择游戏镜像」导入一个，或把文件放进游戏目录。')
          .fontSize(12).fontColor(Theme.textDim()).width('100%')
      } else {
        ForEach(this.games, (g: GameEntry) => {
          this.gameRow(g)
        }, (g: GameEntry) => g.path)
      }
    }
    .width('100%')
    .padding(Theme.pad)
    .backgroundColor(Theme.bgCard())
    .borderRadius(Theme.radius)
    .border({ width: 1, color: Theme.border() })
  }

  /** 游戏库里的单项：封面 + 标题 + serial/大小 + 兼容性提示 */
  @Builder
  gameRow(g: GameEntry) {
    Row({ space: 10 }) {
      // 封面缩略图：有则显示，无则占位（不放"暂无"文字，避免列表噪杂）
      if (this.coverPaths.has(g.path)) {
        Image('file://' + this.coverPaths.get(g.path))
          .width(44)
          .height(60)
          .objectFit(ImageFit.Cover)
          .borderRadius(4)
          .border({ width: 1, color: Theme.border() })
      } else {
        Stack() {
          Text('🎮').fontSize(20).fontColor(Theme.textDim())
        }
        .width(44)
        .height(60)
        .backgroundColor(Theme.bgCardHi())
        .borderRadius(4)
        .border({ width: 1, color: Theme.border() })
      }

      Column({ space: 3 }) {
        Text(gameDisplayTitle(g))
          .fontSize(14)
          .fontColor(Theme.textPri())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(gameDisplaySubtitle(g))
          .fontSize(11)
          .fontColor(g.invalid ? Theme.warn() : Theme.textDim())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        if (compatibilityLabel(g.compatibility).length > 0) {
          Text('兼容性：' + compatibilityLabel(g.compatibility))
            .fontSize(10).fontColor(Theme.warn())
            .width('100%').textAlign(TextAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column({ space: 4 }) {
        // 当前选中的那个给出明确标记，避免"点了没反应"的错觉
        if (g.path === this.currentGamePath) {
          Text('✓ 已选')
            .fontSize(11)
            .fontColor(Theme.ok())
        }
        // 逐游戏设置入口（未识别的镜像没有 serial/CRC，无法定位其设置文件）
        if (!g.invalid && g.serial.length > 0) {
          Text('设置')
            .fontSize(10)
            .fontColor(Theme.accentHi())
            .onClick(() => { if (this.onOpenPerGameSettings) this.onOpenPerGameSettings(g); })
        }
        // 无封面且能定位（有 serial）时提供单条下载入口
        if (!this.coverPaths.has(g.path) && !g.invalid && g.serial.length > 0) {
          if (this.coverBusy.has(g.path)) {
            Text('下载中…').fontSize(10).fontColor(Theme.textDim())
          } else {
            Text('下封面')
              .fontSize(10)
              .fontColor(Theme.accentHi())
              .onClick(() => { if (this.onDownloadCoverFor) this.onDownloadCoverFor(g); })
          }
        }
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: 8, right: 8 })
    .borderRadius(Theme.radiusSm)
    .backgroundColor(g.path === this.currentGamePath ? Theme.bgCardHi() : Color.Transparent)
    .onClick(() => { if (this.onSelectGame) this.onSelectGame(g); })
  }

  /** 列表项通用样式 */
  @Builder
  pickRow(icon: string, title: string, value: string, hint: string,
          btnText: string, onTap: () => void, hasValue: boolean,
          onClear?: () => void, disableReplace: boolean = false) {
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
        .enabled(!disableReplace || !hasValue)
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
		Text(this.storeBuild ? '运行模式' : 'JIT 状态')
		  .fontSize(14).fontColor(Theme.textPri()).fontWeight(FontWeight.Medium)
        Blank()
		if (this.storeBuild) {
		  Text('兼容模式（解释器）')
			.fontSize(13).fontWeight(FontWeight.Medium).fontColor(Theme.warn())
		} else if (!this.jitChecked) {
          Text('未检测').fontSize(12).fontColor(Theme.textDim())
        } else {
          Text(this.jitAvailable ? '可用' : '不可用')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.jitAvailable ? Theme.ok() : Theme.err())
        }
      }
      .width('100%')

	  if (this.storeBuild) {
		Text('商店版不申请可执行内存，固定使用解释器运行。')
		  .fontSize(12).fontColor(Theme.warn()).width('100%')
		Text('性能受限：帧率和游戏兼容性可能明显低于 JIT 开发版。')
		  .fontSize(11).fontColor(Theme.textSec()).width('100%')
		Text(`当前后端：${this.executionMode === 'interpreter' ? '解释器' : '待启动'}`)
		  .fontSize(11).fontColor(Theme.textDim()).width('100%')
	  } else if (this.jitChecked && !this.jitAvailable) {
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

      if (this.jitChecked) {
        Text(this.jitDiagnostics)
          .fontSize(10).fontColor(Theme.textDim()).width('100%')
          .maxLines(8).textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      if (!this.storeBuild) {
        Button('重新检测')
          .width('100%').height(34).fontSize(13)
          .backgroundColor(Theme.bgCardHi())
          .fontColor(Theme.textPri())
          .borderRadius(Theme.radiusSm)
          .onClick(() => { if (this.onCheckJit) this.onCheckJit(); })
      }
      if (!this.storeBuild) {
        Button('运行 prctl A/B 实验（请先停止模拟）')
          .width('100%').height(34).fontSize(12)
          .backgroundColor(Theme.bgCardHi())
          .fontColor(Theme.textPri())
          .borderRadius(Theme.radiusSm)
          .onClick(() => { if (this.onJitPrctlExperiment) this.onJitPrctlExperiment(); })
        if (this.jitPrctlExperimentResult.length > 0) {
          Text(this.jitPrctlExperimentResult)
            .fontSize(10).fontColor(Theme.textDim()).width('100%')
            .maxLines(5).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
    }
    .width('100%')
    .padding(Theme.pad)
	.backgroundColor(this.storeBuild ? Theme.panelWarnBg() :
	  (this.jitChecked && !this.jitAvailable ? '#2A1518' : Theme.bgCard()))
    .borderRadius(Theme.radius)
    .border({
      width: 1,
	  color: this.storeBuild ? Theme.panelWarnBd() :
		(this.jitChecked && !this.jitAvailable ? '#5B2A2F' : Theme.border())
    })
  }

  /**
   * 游戏本体标识卡片。
   *
   * 只在**运行中且已识别出 serial** 时显示 —— 未启动时 native 返回空串，
   * 显示一张空卡片只会干扰视线。BIOS-only 启动（无光盘）同样不显示，
   * 因为那时没有"游戏本体"可言。
   *
   * 为什么值得单独做一张卡：记忆卡的自动归类完全依赖 serial，
   * 但此前用户看不到它 —— 归类结果成了无法验证的黑盒。
   */
  @Builder
  discCard() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text('🎮').fontSize(15)
        Text(this.discTitle.length > 0 ? this.discTitle : '已识别游戏')
          .fontSize(14).fontColor(Theme.textPri()).fontWeight(FontWeight.Medium)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')

      // 序列号与 CRC 并排：前者是记忆卡归类的依据，后者与存档文件名一致
      Row({ space: 8 }) {
        Text('序列号')
          .fontSize(10).fontColor(Theme.textDim())
        Text(this.discSerial)
          .fontSize(11).fontColor(Theme.ok()).fontWeight(FontWeight.Medium)

        if (this.discCRC.length > 0) {
          Text('CRC').fontSize(10).fontColor(Theme.textDim())
          Text(this.discCRC)
            .fontSize(11).fontColor(Theme.textSec())
        }
      }
      .width('100%')

      Text('记忆卡按序列号归类，存档文件名含 CRC。')
        .fontSize(10).fontColor(Theme.textDim()).width('100%')
    }
    .width('100%')
    .padding(Theme.pad)
    .backgroundColor(Theme.bgCard())
    .borderRadius(Theme.radius)
    .border({ width: 1, color: Theme.border() })
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

        // 不使用 ⚙ 字形：部分系统字体会把 emoji 版本裁成半个图标。
        // 使用完整文字按钮，保证设置入口在不同字体和分辨率下都可见。
        Button('设置')
          .width(72).height(40).fontSize(14)
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
            this.picking === 'bios' ? '处理中…' :
              (this.biosName.length > 0 ? '已选择（到设置中更换）' : '选择 BIOS 文件'),
            () => { if (this.onPickBios) this.onPickBios(); },
            this.biosName.length > 0, undefined, true)

          this.pickRow('🎮', '游戏镜像', this.gameName,
            '可选 —— 不选则只启动 BIOS',
            this.picking === 'game' ? '处理中…' : '选择游戏镜像',
            () => { if (this.onPickGame) this.onPickGame(); },
            this.gameName.length > 0,
            () => { if (this.onClearGame) this.onClearGame(); })

          // 游戏库：列出 sandbox games/ 目录里已有的镜像，点选即切换
          this.gameLibrary()

          // 运行中才显示（native 未启动时返回空串，避免空卡片干扰）
          if (this.discSerial.length > 0) {
            this.discCard()
          }

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
            Column({ space: 10 }) {
              // 标题行：有分类时显示类别标签，让用户一眼看出该重启还是该换文件
              Row({ space: 8 }) {
                Text('启动失败')
                  .fontSize(13).fontColor(Theme.err()).fontWeight(FontWeight.Medium)
                if (this.errorKindLabel.length > 0) {
                  Text(this.errorKindLabel)
                    .fontSize(11)
                    .fontColor(Theme.textPri())
                    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                    .backgroundColor(Theme.panelErrBd())
                    .borderRadius(8)
                }
              }
              .width('100%')

              Text(this.statusError).fontSize(12).fontColor(Theme.err()).width('100%')

              // 处置建议（改进 1 的核心价值：告诉用户下一步做什么）
              if (this.errorAdvice.length > 0) {
                Column({ space: 4 }) {
                  Text('怎么办').fontSize(11).fontColor(Theme.warn()).width('100%')
                  Text(this.errorAdvice)
                    .fontSize(11).fontColor(Theme.textSec()).width('100%')
                }
                .width('100%')
                .padding(10)
                .backgroundColor(Theme.bgCardHi())
                .borderRadius(Theme.radiusSm)
              }

              // 改进 3：一键导出诊断日志
              Button('复制诊断日志')
                .width('100%').height(36).fontSize(13)
                .backgroundColor(Theme.bgCardHi())
                .fontColor(Theme.textPri())
                .borderRadius(Theme.radiusSm)
                .onClick(() => { if (this.onExportLog) this.onExportLog(); })

              if (this.logExportMessage.length > 0) {
                Text(this.logExportMessage)
                  .fontSize(11).fontColor(Theme.textSec()).width('100%')
              }
            }
            .width('100%')
            .padding(Theme.pad)
            .backgroundColor(Theme.panelErrBg())
            .borderRadius(Theme.radius)
            .border({ width: 1, color: Theme.panelErrBd() })
          }

          // BIOS 规格检查提示（改进 2）。
          // 措辞保守：只能说"可能不是有效 BIOS"，不能断言有效性。
          if (this.biosCheckChecked && this.biosCheckMessage.length > 0) {
            Column({ space: 6 }) {
              Row({ space: 6 }) {
                Text(this.biosCheckSuspicious ? '⚠' : '✓')
                  .fontSize(13)
                  .fontColor(this.biosCheckSuspicious ? Theme.warn() : Theme.ok())
                Text(this.biosCheckSuspicious ? 'BIOS 可能需要更换' : 'BIOS 规格正常')
                  .fontSize(12)
                  .fontColor(this.biosCheckSuspicious ? Theme.warn() : Theme.ok())
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')
              Text(this.biosCheckMessage)
                .fontSize(11).fontColor(Theme.textSec()).width('100%')
            }
            .width('100%')
            .padding(Theme.pad)
            .backgroundColor(this.biosCheckSuspicious ? Theme.panelWarnBg() : Theme.bgCard())
            .borderRadius(Theme.radius)
            .border({
              width: 1,
              color: this.biosCheckSuspicious ? Theme.panelWarnBd() : Theme.border()
            })
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
		storeBuild: this.storeBuild,
		executionMode: this.executionMode,
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
