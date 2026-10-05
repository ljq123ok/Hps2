import { Theme } from '../common/Theme';

export interface MemoryCardInfo {
  name: string;
  path: string;
  size: number;
  fileType: string;
  formatted: boolean;
  gameIds: Array<string>;
  matchedGameSerial: string;
  groupName: string;
}

@Component
export struct MemoryCardPanel {
  @Prop cards: Array<MemoryCardInfo> = [];
  @Prop message: string = '';
  @Prop directory: string = '';
  @Prop busy: boolean = false;
  @Prop currentGame: string = '';

  onRefresh?: () => void;
  onImport?: () => void;
  onCreate?: (sizeMb: number) => void;
  onExport?: (name: string) => void;
  onDelete?: (name: string) => void;
  onAssignCurrentGame?: (name: string) => void;

  private formatSize(bytes: number): string {
    if (bytes >= 1024 * 1024) {
      return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
    }
    return (bytes / 1024).toFixed(0) + ' KB';
  }

  @Builder
  cardRow(card: MemoryCardInfo) {
    Column({ space: 8 }) {
      Row() {
        Column({ space: 3 }) {
          Text(card.name)
            .fontSize(14)
            .fontColor(Theme.textPri())
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${card.fileType} · ${this.formatSize(card.size)}`)
            .fontSize(11)
            .fontColor(card.formatted ? Theme.ok() : Theme.warn())
          Text('分类：' + card.groupName)
            .fontSize(10)
            .fontColor(Theme.textDim())
          if (card.gameIds.length > 0) {
            Text('目录序列号：' + card.gameIds.join('、'))
              .fontSize(10)
              .fontColor(Theme.textSec())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          } else if (card.formatted) {
            Text('未解析到游戏序列号')
              .fontSize(10)
              .fontColor(Theme.textDim())
          }
          if (card.matchedGameSerial.length > 0) {
            Text('已匹配当前游戏：' + card.matchedGameSerial)
              .fontSize(10)
              .fontColor(Theme.ok())
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button('导出')
          .height(30)
          .fontSize(12)
          .backgroundColor(Theme.bgCardHi())
          .fontColor(Theme.textPri())
          .borderRadius(Theme.radiusSm)
          .enabled(!this.busy)
          .onClick(() => { if (this.onExport) this.onExport(card.name); })

        Button('删')
          .height(30)
          .fontSize(12)
          .backgroundColor(Theme.panelErrBg())
          .fontColor(Theme.err())
          .borderRadius(Theme.radiusSm)
          .enabled(!this.busy)
          .onClick(() => { if (this.onDelete) this.onDelete(card.name); })

        if (this.currentGame.length > 0 && card.groupName !== this.currentGame) {
          Button('归类')
            .height(30)
            .fontSize(12)
            .backgroundColor(Theme.accent())
            .fontColor('#FFFFFF')
            .borderRadius(Theme.radiusSm)
            .enabled(!this.busy)
            .onClick(() => {
              if (this.onAssignCurrentGame) this.onAssignCurrentGame(card.name);
            })
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .border({ width: 1, color: Theme.border() })
    .borderRadius(Theme.radiusSm)
    .padding(10)
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 3 }) {
          Text('PS2 记忆卡')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPri())
          Text('跨模拟器通用文件；不包含 Hps2 即时存档')
            .fontSize(11)
            .fontColor(Theme.textDim())
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button('刷新')
          .height(32)
          .fontSize(12)
          .backgroundColor(Theme.bgCardHi())
          .fontColor(Theme.textPri())
          .borderRadius(Theme.radiusSm)
          .enabled(!this.busy)
          .onClick(() => { if (this.onRefresh) this.onRefresh(); })

      }
      .width('100%')

      Text('应用记忆卡目录：' + (this.directory.length > 0 ? this.directory : '应用启动后生成'))
        .fontSize(10)
        .fontColor(Theme.textSec())
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text('导出后的 .ps2 文件可在文件管理器自由复制、移动、改名或删除；需要使用时再导入。')
        .fontSize(10)
        .fontColor(Theme.warn())
        .width('100%')

      Row({ space: 8 }) {
        Button('导入记忆卡')
          .layoutWeight(1)
          .height(36)
          .fontSize(12)
          .backgroundColor(Theme.accent())
          .fontColor('#FFFFFF')
          .borderRadius(Theme.radiusSm)
          .enabled(!this.busy)
          .onClick(() => { if (this.onImport) this.onImport(); })

        Button('新建 8MB')
          .height(36)
          .fontSize(12)
          .backgroundColor(Theme.bgCardHi())
          .fontColor(Theme.textPri())
          .borderRadius(Theme.radiusSm)
          .enabled(!this.busy)
          .onClick(() => { if (this.onCreate) this.onCreate(8); })
      }
      .width('100%')

      Row({ space: 8 }) {
        ForEach([16, 32, 64], (sizeMb: number) => {
          Button('新建 ' + sizeMb.toString() + 'MB')
            .layoutWeight(1)
            .height(32)
            .fontSize(11)
            .backgroundColor(Theme.bgCardHi())
            .fontColor(Theme.textPri())
            .borderRadius(Theme.radiusSm)
            .enabled(!this.busy)
            .onClick(() => { if (this.onCreate) this.onCreate(sizeMb); })
        }, (sizeMb: number) => sizeMb.toString())
      }
      .width('100%')

      if (this.cards.length === 0) {
        Text('暂无记忆卡。可导入其他模拟器的 .ps2/.mcr/.mcd 文件。')
          .fontSize(11)
          .fontColor(Theme.textDim())
          .width('100%')
          .padding({ top: 6, bottom: 6 })
      } else {
        ForEach(this.cards, (card: MemoryCardInfo) => {
          this.cardRow(card)
        }, (card: MemoryCardInfo) => card.name)
      }

      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(11)
          .fontColor(Theme.accentHi())
          .width('100%')
      }
    }
    .width('100%')
    .padding(Theme.pad)
    .backgroundColor(Theme.bgCard())
    .borderRadius(Theme.radius)
    .border({ width: 1, color: Theme.border() })
  }
}
