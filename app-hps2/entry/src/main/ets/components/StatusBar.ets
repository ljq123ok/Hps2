/*
 * Hps2 — 底部状态栏
 *
 * 设计来源：设计稿 02 底部的 "JIT: Ready / BIOS: OK"。
 *
 * 为什么值得保留这个设计：
 *   本项目实测发现 JIT 可用性是**运行期属性**（会随状态变化，
 *   见 docs/jit-regression.md 与 docs/jit-state-pollution.md）。
 *   把它做成常驻可见的状态，用户就能第一时间知道自己处在什么环境，
 *   而不是等游戏卡顿了才困惑。
 */
import { Theme } from '../common/Theme';

@Component
export struct StatusBar {
  @Prop jitChecked: boolean = false;
  @Prop jitAvailable: boolean = false;
  @Prop storeBuild: boolean = false;
  @Prop executionMode: string = 'unknown';
  @Prop biosReady: boolean = false;
  @Prop gameReady: boolean = false;
  @Prop running: boolean = false;

  @Builder
  dot(ok: boolean, label: string) {
    Row({ space: 6 }) {
      Circle()
        .width(8)
        .height(8)
        .fill(ok ? Theme.ok() : (this.jitChecked ? Theme.err() : Theme.textDim()))
      Text(label)
        .fontSize(12)
        .fontColor(ok ? Theme.textSec() : Theme.textDim())
    }
  }

  build() {
    Row() {
	  // 商店版把解释器作为显式执行模式，不把 JIT 策略禁用渲染成故障。
	  if (this.storeBuild) {
		Row({ space: 6 }) {
		  Circle().width(8).height(8).fill(Theme.warn())
		  Text(this.executionMode === 'interpreter' ? 'CPU: 解释器' : 'CPU: 兼容模式')
			.fontSize(12).fontColor(Theme.warn())
		}
	  } else if (!this.jitChecked) {
        this.dot(false, 'JIT: 检测中')
      } else {
        Row({ space: 6 }) {
          Circle()
            .width(8).height(8)
            .fill(this.jitAvailable ? Theme.ok() : Theme.err())
          Text(this.jitAvailable ? 'JIT: 可用' : 'JIT: 不可用')
            .fontSize(12)
            .fontColor(this.jitAvailable ? Theme.ok() : Theme.err())
        }
      }

      Blank()

      Row({ space: 14 }) {
        this.dot(this.biosReady, 'BIOS')
        if (this.gameReady) {
          this.dot(true, '游戏')
        }
        if (this.running) {
          Text('运行中')
            .fontSize(12)
            .fontColor(Theme.accentHi())
        }
      }
    }
    .width('100%')
    .padding({ left: Theme.pad, right: Theme.pad, top: 10, bottom: 10 })
    .backgroundColor(Theme.bgCard())
    .border({ width: { top: 1 }, color: Theme.border() })
  }
}
