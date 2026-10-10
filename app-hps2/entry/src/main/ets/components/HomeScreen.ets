/*
 * Hps2 — 首页（设计稿 v2：「PS2 记忆殿堂」）
 *
 * 结构（自上而下）：
 *   1. Hero 顶栏：Logo + 搜索/设置图标钮
 *   2. 最近游玩：横向滚动的封面卡（大封面 + 标题 + 时间）
 *   3. 我的游戏：紧凑列表（缩略图 + 标题 + 兼容性标签）
 *   4. 状态胶囊：JIT / BIOS 两条 LED 状态
 *   5. 启动键：全宽渐变主操作
 *   6. 底部胶囊 Dock：游戏库 / 记忆卡 / 存档 / 设置
 *
 * 与 v1 的区别：v1 把所有操作（选 BIOS、选游戏、JIT 诊断、错误面板、
 * 法律声明）全部堆在一屏。v2 把「准备」收敛为状态胶囊 + 弹层入口，
 * 主屏让位给游戏内容（封面 + 列表）。
 */
import { Theme } from '../common/Theme';
import { GameEntry, gameDisplayTitle, gameDisplaySubtitle, compatibilityLabel } from '../common/GameLibrary';

/** 最近游玩取前几个（横向卡片太多会稀释「最近」语义） */
const RECENT_MAX = 5;

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
  /** Dock：打开记忆卡管理 */
  onOpenMemoryCard?: () => void;

  // ================= 工具 =================

  /** 最近游玩：按 lastPlayed 降序取已识别且玩过的 */
  private recentGames(): Array<GameEntry> {
    const played = this.games.filter((g: GameEntry) => g.lastPlayed > 0 && !g.invalid);
    played.sort((a: GameEntry, b: GameEntry) => b.lastPlayed - a.lastPlayed);
    return played.slice(0, RECENT_MAX);
  }

  private lastPlayedLabel(g: GameEntry): string {
    const now = Date.now() / 1000;
    const diff = now - g.lastPlayed;
    if (diff < 3600) { return '刚刚'; }
    if (diff < 86400) { return `${Math.floor(diff / 3600)} 小时前`; }
    if (diff < 86400 * 30) { return `${Math.floor(diff / 86400)} 天前`; }
    return '更早';
  }

  // ================= 区块 =================

  /** Hero 顶栏 */
  @Builder
  hero() {
    Row() {
      Column({ space: 2 }) {
        Row({ space: 2 }) {
          Text('Hp').fontSize(30).fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPri())
          Text('s2').fontSize(30).fontWeight(FontWeight.Bold)
            .fontColor(Theme.faceCrs())
          Text('v2').fontSize(13).fontWeight(FontWeight.Bold)
            .fontColor(Theme.faceCrs())
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(Theme.withAlpha(Theme.faceCrs(), 0.13))
            .borderRadius(8)
            .alignSelf(ItemAlign.Start)
        }
        Text('PS2 SIMULATOR').fontSize(10)
          .fontColor(Theme.textDim())
          .letterSpacing(4)
      }
      .alignItems(HorizontalAlign.Start)

      Blank()

      // 设置：图标化圆角钮（不用文字按钮，视觉更轻）
      Button('设置')
        .width(64).height(40).fontSize(13)
        .backgroundColor(Theme.bgCard())
        .fontColor(Theme.textSec())
        .borderRadius(Theme.radiusSm)
        .border({ width: 1, color: Theme.border() })
        .onClick(() => { if (this.onOpenSettings) this.onOpenSettings(); })
    }
    .width('100%')
    .padding({ left: Theme.pad, right: Theme.pad, top: 16, bottom: 12 })
  }

  /** 区块标题（带彩色圆点） */
  @Builder
  sectionLabel(title: string, note: string, dotColor: string) {
    Row({ space: 8 }) {
      Circle().width(6).height(6).fill(dotColor)
      Text(title).fontSize(15).fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPri())
      Text(note).fontSize(11).fontColor(Theme.textDim())
      Blank()
    }
    .width('100%')
  }

  /** 最近游玩的封面卡（大卡） */
  @Builder
  recentCover(g: GameEntry) {
    Column({ space: 0 }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        // 封面 / 占位
        if (this.coverPaths.has(g.path)) {
          Image('file://' + this.coverPaths.get(g.path))
            .width(Theme.coverW).height(Theme.coverH)
            .objectFit(ImageFit.Cover)
            .borderRadius(Theme.radiusSm)
        } else {
          Column() {
            Text('🎮').fontSize(34)
          }
          .width(Theme.coverW).height(Theme.coverH)
          .backgroundColor(Theme.bgCardHi())
          .borderRadius(Theme.radiusSm)
          .justifyContent(FlexAlign.Center)
        }

        // 当前选中：青绿描边 + 角标（对应设计稿的绿色辉光卡）
        if (g.path === this.currentGamePath) {
          Column()
            .width(Theme.coverW).height(Theme.coverH)
            .borderRadius(Theme.radiusSm)
            .border({ width: 2, color: Theme.coverPlayingBd() })
          Text('继续')
            .fontSize(10).fontWeight(FontWeight.Bold)
            .fontColor(Theme.faceTri())
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor(Theme.withAlpha(Theme.coverPlayingBd(), 0.15))
            .borderRadius(10)
            .position({ x: 8, y: 8 })
        }
      }

      // 卡片下方信息
      Column({ space: 2 }) {
        Text(gameDisplayTitle(g))
          .fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPri())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width(Theme.coverW)
          .textAlign(TextAlign.Start)
        Text(this.lastPlayedLabel(g))
          .fontSize(10)
          .fontColor(Theme.textDim())
          .width(Theme.coverW)
          .textAlign(TextAlign.Start)
      }
      .alignItems(HorizontalAlign.Start)
    }
    .width(Theme.coverW)
    .onClick(() => { if (this.onSelectGame) this.onSelectGame(g); })
  }

  /** 最近游玩区 */
  @Builder
  recentRow() {
    Column({ space: 10 }) {
      this.sectionLabel('最近游玩', '继续上次进度', Theme.faceCrs())

      if (this.games.length === 0) {
        // 空态：引导导入（对应设计稿的虚线幽灵卡）
        Row({ space: 10 }) {
          Text('+')
            .width(32).height(32)
            .fontSize(20)
            .fontColor(Theme.accentHi())
            .textAlign(TextAlign.Center)
            .borderRadius(16)
            .border({ width: 1.5, color: Theme.accentHi() })
          Column({ space: 2 }) {
            Text('还没有游戏').fontSize(13)
              .fontColor(Theme.textDim())
            Text('选择游戏镜像导入，或放入游戏目录后重新扫描')
              .fontSize(11).fontColor(Theme.textDim())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding(14)
        .borderRadius(Theme.radiusSm)
        .border({ width: 1.5, color: Theme.border(), style: BorderStyle.Dashed })
        .onClick(() => { if (this.onPickGame) this.onPickGame(); })
      } else {
        Scroll() {
          Row({ space: 12 }) {
            ForEach(this.recentGames(), (g: GameEntry) => {
              this.recentCover(g)
            }, (g: GameEntry) => g.path)
          }
          .padding({ bottom: 2 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
    }
    .width('100%')
  }

  /** 游戏列表项（紧凑行） */
  @Builder
  gameRow(g: GameEntry) {
    Row({ space: 12 }) {
      // 缩略封面
      if (this.coverPaths.has(g.path)) {
        Image('file://' + this.coverPaths.get(g.path))
          .width(42).height(56)
          .objectFit(ImageFit.Cover)
          .borderRadius(6)
      } else {
        Column() {
          Text('🎮').fontSize(18)
        }
        .width(42).height(56)
        .backgroundColor(Theme.bgCardHi())
        .borderRadius(6)
        .justifyContent(FlexAlign.Center)
      }

      // 标题 + 副标题 + 兼容性
      Column({ space: 3 }) {
        Text(gameDisplayTitle(g))
          .fontSize(14)
          .fontColor(Theme.textPri())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        Row({ space: 8 }) {
          Text(gameDisplaySubtitle(g))
            .fontSize(11)
            .fontColor(g.invalid ? Theme.warn() : Theme.textDim())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (compatibilityLabel(g.compatibility).length > 0) {
            Text(compatibilityLabel(g.compatibility))
              .fontSize(9)
              .fontColor(Theme.warn())
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor(Theme.panelWarnBg())
              .borderRadius(8)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 右侧操作
      Column({ space: 4 }) {
        if (g.path === this.currentGamePath) {
          Text('✓').fontSize(14).fontColor(Theme.ok())
        } else {
          Text('›').fontSize(16).fontColor(Theme.textDim())
        }
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8, left: 8, right: 8 })
    .borderRadius(Theme.radiusSm)
    .backgroundColor(g.path === this.currentGamePath ?
      Theme.bgCardHi() : Color.Transparent)
    .onClick(() => { if (this.onSelectGame) this.onSelectGame(g); })
  }

  /** 「我的游戏」区（列表 + 工具行） */
  @Builder
  gameLibrary() {
    Column({ space: 10 }) {
      Row() {
        Text('我的游戏').fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPri())
        Text(this.gamesScanning ? '扫描中…' : `${this.games.length} 个`)
          .fontSize(11).fontColor(Theme.textDim())
          .padding({ left: 8 })
        Blank()
        Text('重新扫描')
          .fontSize(11).fontColor(Theme.accentHi())
          .padding({ left: 10, top: 4, bottom: 4 })
          .onClick(() => { if (this.onRefreshGames) this.onRefreshGames(); })
      }
      .width('100%')

      if (this.games.length === 0) {
        Text(this.gamesScanning
          ? '正在扫描游戏目录…'
          : '还没有游戏镜像。用「选择游戏镜像」导入一个，或把文件放进游戏目录。')
          .fontSize(12).fontColor(Theme.textDim()).width('100%')
          .padding({ top: 4, bottom: 4 })
      } else {
        ForEach(this.games, (g: GameEntry) => {
          this.gameRow(g)
        }, (g: GameEntry) => g.path)
      }

      // 封面工具行（收窄为一行小字，不再占大块）
      Row({ space: 12 }) {
        Text(this.coverSourceName.length > 0
          ? `封面源：${this.coverSourceName}`
          : '封面源：未配置')
          .fontSize(10).fontColor(Theme.textDim())
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('源设置')
          .fontSize(10).fontColor(Theme.accentHi())
          .onClick(() => { if (this.onOpenCoverSources) this.onOpenCoverSources(); })
        Text('下载缺失封面')
          .fontSize(10).fontColor(Theme.accentHi())
          .onClick(() => { if (this.onDownloadCovers) this.onDownloadCovers(); })
      }
      .width('100%')
      .padding({ top: 2 })

      if (this.coverMessage.length > 0) {
        Text(this.coverMessage)
          .fontSize(10).fontColor(Theme.textDim()).width('100%').maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding(Theme.pad)
    .backgroundColor(Theme.bgCard())
    .borderRadius(Theme.radius)
    .border({ width: 1, color: Theme.border() })
  }

  /** 逐游戏设置入口（有 serial 才显示，放在列表项长按语义外的显式小行） */
  @Builder
  perGameHint() {
    if (this.currentGamePath.length > 0) {
      Row({ space: 8 }) {
        Text('本游戏：').fontSize(11).fontColor(Theme.textDim())
        Text(this.gameName)
          .fontSize(11).fontColor(Theme.textSec())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        // 逐游戏设置入口：从列表项的副标题区搬到这里，
        // 列表行恢复纯「点选」语义（v1 里一行塞 4 个可点文字容易误触）
      }
      .width('100%')
      .padding({ left: 4 })
    }
  }

  /** 状态胶囊行：JIT / BIOS（对应设计稿 sysrow） */
  @Builder
  sysRow() {
    Row({ space: 10 }) {
      // JIT 胶囊
      Row({ space: 8 }) {
        Circle()
          .width(8).height(8)
          .fill(this.storeBuild ? Theme.warn() :
            (this.jitChecked ?
              (this.jitAvailable ? Theme.ok() : Theme.err()) :
              Theme.textDim()))
        Text(this.storeBuild ? '兼容模式' :
          (this.jitChecked ? (this.jitAvailable ? 'JIT 已就绪' : 'JIT 不可用') : 'JIT 未检测'))
          .fontSize(12)
          .fontColor(Theme.textSec())
      }
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor(Theme.bgCard())
      .borderRadius(20)
      .border({ width: 1, color: Theme.border() })
      .layoutWeight(1)
      .justifyContent(FlexAlign.Start)

      // BIOS 胶囊
      Row({ space: 8 }) {
        Circle()
          .width(8).height(8)
          .fill(this.biosName.length > 0 ? Theme.ok() : Theme.warn())
        Text('BIOS')
          .fontSize(12)
          .fontColor(Theme.textSec())
        Text(this.biosName.length > 0 ? '已就绪' : '未选择')
          .fontSize(12).fontWeight(FontWeight.Bold)
          .fontColor(this.biosName.length > 0 ? Theme.ok() : Theme.warn())
      }
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor(Theme.bgCard())
      .borderRadius(20)
      .border({ width: 1, color: Theme.border() })
      .layoutWeight(1)
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')

    // BIOS 未选时：轻量引导（不再是大黄牌 —— 首次使用才需要）
    if (this.biosName.length === 0) {
      Row({ space: 8 }) {
        Text('💿').fontSize(13)
        Text('首次使用：选择你合法拥有的 PS2 BIOS（4MB）')
          .fontSize(11).fontColor(Theme.warn())
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('选择')
          .fontSize(11).fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .backgroundColor(Theme.warn())
          .borderRadius(12)
          .onClick(() => { if (this.onPickBios) this.onPickBios(); })
      }
      .width('100%')
      .padding({ left: 12, right: 8, top: 8, bottom: 8 })
      .backgroundColor(Theme.panelWarnBg())
      .borderRadius(Theme.radiusSm)
      .border({ width: 1, color: Theme.panelWarnBd() })
    }
  }

  /** 启动键（设计稿：全宽渐变主操作） */
  @Builder
  launchButton() {
    Button(this.statusRunning0 ? '启动中…' :
      (this.gameName.length > 0 ? '▶  启动游戏' : '▶  启动 BIOS'))
      .width('100%')
      .height(52)
      .fontSize(17)
      .fontWeight(FontWeight.Bold)
      .backgroundColor(this.biosName.length > 0 ? Theme.accent() : Theme.bgCardHi())
      .fontColor(this.biosName.length > 0 ? '#FFFFFF' : Theme.textDim())
      .borderRadius(26)
      .enabled(this.biosName.length > 0 && !this.busy)
      .onClick(() => { if (this.onStart) this.onStart(); })
  }

  /** 底部胶囊 Dock（设计稿 v2：悬浮内缩） */
  @Builder
  dock() {
    Row() {
      // 游戏库（当前页，高亮）
      Column({ space: 3 }) {
        Text('▣').fontSize(19).fontColor(Theme.accentHi())
        Text('游戏库').fontSize(9).fontColor(Theme.accentHi())
      }
      .alignItems(HorizontalAlign.Center)

      Blank()

      // 记忆卡
      Column({ space: 3 }) {
        Text('▤').fontSize(20).fontColor(Theme.textDim())
        Text('记忆卡').fontSize(9).fontColor(Theme.textDim())
      }
      .alignItems(HorizontalAlign.Center)
      .onClick(() => { if (this.onOpenMemoryCard) this.onOpenMemoryCard(); })

      Blank()

      // 存档（进入游玩后才有意义；首页给弱化的入口提示）
      Column({ space: 3 }) {
        Text('◎').fontSize(20).fontColor(Theme.textDim())
        Text('存档').fontSize(9).fontColor(Theme.textDim())
      }
      .alignItems(HorizontalAlign.Center)
      .onClick(() => { if (this.onOpenSettings) this.onOpenSettings(); })

      Blank()

      // 设置
      Column({ space: 3 }) {
        Text('≡').fontSize(19).fontColor(Theme.textDim())
        Text('设置').fontSize(9).fontColor(Theme.textDim())
      }
      .alignItems(HorizontalAlign.Center)
      .onClick(() => { if (this.onOpenSettings) this.onOpenSettings(); })
    }
    .width('100%')
    .height(Theme.dockHeight)
    .padding({ left: 28, right: 28 })
    .backgroundColor(Theme.dockBg())
    .borderRadius(Theme.dockHeight / 2)
    .border({ width: 1, color: Theme.dockBorder() })
  }

  build() {
    Column() {
      this.hero()

      // ---- 内容（可滚动）----
      Scroll() {
        Column({ space: Theme.gap }) {
          // 准备区：JIT/BIOS 状态 + 首次引导（收纳在内容顶部，弱化）
          this.sysRow()

          // JIT 需要展开诊断/操作时（不可用、商店版、未检测），显示详情面板
          if (this.storeBuild || !this.jitChecked ||
              (this.jitChecked && !this.jitAvailable)) {
            this.jitDetailPanel()
          }

          // 最近游玩（无历史时是导入引导卡）
          this.recentRow()

          // 游戏库
          this.gameLibrary()

          this.perGameHint()

          // 运行中才显示（native 未启动时返回空串，避免空卡片干扰）
          if (this.discSerial.length > 0) {
            this.discCard()
          }

          // ---- 启动按钮 ----
          this.launchButton()

          // ---- 错误面板（保持 v1 的完整分类 + 建议 + 日志导出）----
          if (this.statusError.length > 0) {
            this.errorPanel()
          }

          // ---- BIOS 规格检查（改进 2）----
          if (this.biosCheckChecked && this.biosCheckMessage.length > 0) {
            this.biosCheckPanel()
          }

          Blank().height(12)
        }
        .width('100%')
        .padding({ left: Theme.pad, right: Theme.pad })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      // ---- 底部胶囊 Dock ----
      Row() {
        this.dock()
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 10 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bgBase())
  }

  // ---- 以下为保留的 v1 面板（内容不变，仅随新色板换肤）----

  /** 游戏本体标识卡片（运行中显示） */
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

      Row({ space: 8 }) {
        Text('序列号').fontSize(10).fontColor(Theme.textDim())
        Text(this.discSerial)
          .fontSize(11).fontColor(Theme.ok()).fontWeight(FontWeight.Medium)
        if (this.discCRC.length > 0) {
          Text('CRC').fontSize(10).fontColor(Theme.textDim())
          Text(this.discCRC).fontSize(11).fontColor(Theme.textSec())
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

  /** 启动错误面板（v1 改进 1/3：分类 + 建议 + 日志导出） */
  @Builder
  errorPanel() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('启动失败').fontSize(13).fontColor(Theme.err()).fontWeight(FontWeight.Medium)
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

  /** BIOS 规格检查提示（v1 改进 2，措辞保守） */
  @Builder
  biosCheckPanel() {
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

  /** JIT 诊断详情（不可用或商店版时展开在状态胶囊下） */
  @Builder
  jitDetailPanel() {
    Column({ space: 8 }) {
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
      (this.jitChecked && !this.jitAvailable ? Theme.panelErrBg() : Theme.bgCard()))
    .borderRadius(Theme.radius)
    .border({
      width: 1,
      color: this.storeBuild ? Theme.panelWarnBd() :
        (this.jitChecked && !this.jitAvailable ? Theme.panelErrBd() : Theme.border())
    })
  }

  // 占位：启动中的显示由父组件通过 statusStage 传达
  private get statusRunning0(): boolean {
    return this.statusStage === 'starting-thread' || this.statusStage === 'reserving-memory';
  }
}
