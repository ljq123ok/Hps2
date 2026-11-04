import { Theme } from '../common/Theme';
import { PrivateGameFile } from '../common/GameStorage';
import { humanSize } from '../common/GameLibrary';

@Component
export struct GameStoragePanel {
  @Prop location: string = '';
  @Prop message: string = '';
  @Prop busy: boolean = false;
  @Prop files: Array<PrivateGameFile> = [];
  onPrepare: () => void = () => {};
  onChooseDirectory: () => void = () => {};
  onChooseGame: () => void = () => {};
  onScan: () => void = () => {};
  onRefresh: () => void = () => {};
  onDelete: (file: PrivateGameFile) => void = (_file: PrivateGameFile) => {};
  onClose: () => void = () => {};

  build() {
    Column() {
      Column({ space: 12 }) {
        Row() {
          Text('游戏目录与空间').fontSize(17).fontColor(Theme.textPri()).layoutWeight(1)
          Button('关闭').height(32).fontSize(12).enabled(!this.busy)
            .onClick(() => { this.onClose(); })
        }.width('100%')
        Scroll() {
          Column({ space: 12 }) {
            Text('建议在本机“下载 / Download”中建立 PS2 文件夹，将游戏放进去。')
              .fontSize(13).fontColor(Theme.textPri()).width('100%')
            Text('本机支持时可直接创建；也可在系统目录选择器右上角点新建文件夹，建立 PS2 后确认选择。')
              .fontSize(12).fontColor(Theme.textSec()).width('100%')
            Button('创建 Download/PS2').width('100%').enabled(!this.busy)
              .onClick(() => { this.onPrepare(); })
            Button('选择或新建游戏目录').width('100%').enabled(!this.busy)
              .onClick(() => { this.onChooseDirectory(); })
            Text(this.location ? '已记录位置：' + this.location : '尚未设置游戏位置')
              .fontSize(12).fontColor(Theme.textSec()).width('100%')
            Text('目录存在不代表可以直接读取。选择一个游戏后会检查；不能直接读取时，复制前会再次征求确认。')
              .fontSize(12).fontColor(Theme.textDim()).width('100%')
            Button('选择游戏并验证直读').width('100%').enabled(!this.busy)
              .onClick(() => { this.onChooseGame(); })
            Button('扫描此目录').width('100%').enabled(!this.busy && this.location.length > 0)
              .onClick(() => { this.onScan(); })
            if (this.message) {
              Text(this.message).fontSize(12).fontColor(Theme.warn()).width('100%')
            }
            Divider()
            Text('应用内游戏文件：' + humanSize(this.files.reduce(
              (sum: number, file: PrivateGameFile) => sum + file.size, 0)))
              .fontSize(14).fontColor(Theme.textPri()).width('100%')
            Text('这里列出旧版留下的副本及未完成的复制文件。清理只影响应用内的这份文件；原目录文件和存档不会被删除。')
              .fontSize(12).fontColor(Theme.textDim()).width('100%')
            Button('刷新占用').enabled(!this.busy).onClick(() => { this.onRefresh(); })
            if (this.files.length === 0) {
              Text('没有应用内游戏文件').fontSize(12).fontColor(Theme.textSec())
            }
            ForEach(this.files, (file: PrivateGameFile) => {
              Row({ space: 8 }) {
                Column({ space: 3 }) {
                  Text(file.incomplete ? '未完成的复制' : file.name)
                    .fontSize(12).fontColor(Theme.textPri()).maxLines(2)
                  Text(humanSize(file.size)).fontSize(11).fontColor(Theme.textDim())
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                Button('清理').height(32).fontSize(12).enabled(!this.busy)
                  .onClick(() => { this.onDelete(file); })
              }.width('100%')
            }, (file: PrivateGameFile) => file.name)
          }.width('100%').padding({ bottom: 12 })
        }.layoutWeight(1).width('100%')
      }.width('90%').height('88%').padding(16)
        .backgroundColor(Theme.bgBase()).borderRadius(Theme.radius)
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      .backgroundColor(Theme.overlayScrim())
  }
}
