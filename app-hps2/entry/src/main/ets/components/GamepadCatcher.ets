/*
 * Hps2 — 蓝牙手柄事件接收器
 *
 * 职责：把系统的 KeyEvent / AxisEvent 翻译成虚拟手柄调用，
 * 复用现有链路送到 PCSX2：
 *
 *   手柄 → 系统解析 → 本组件 onKeyEvent/onAxisEvent
 *        → hps2core.vpadButton()/vpadAxis()
 *        → SDL_SetJoystickVirtual* → SDLInputSource → PCSX2 Pad
 *
 * 【为什么单独做一个组件】
 * onKeyEvent 只在**组件获得焦点**时触发。用一个零尺寸、
 * 主动请求焦点的组件专职接收手柄事件，比让整个游戏画面容器承担
 * 更清晰，也避免与虚拟按键的触摸处理互相干扰。
 *
 * 【三家手柄通用】系统层的按键码统一（Xbox/PS/Switch 共用
 * KEYCODE_BUTTON_A/B/X/Y），差异只在物理标注；按位置映射到
 * PS2 的 ×○□△ 即可三家通用。详见 common/GamepadKeyMap.ets。
 */
import hilog from '@ohos.hilog';
import hps2core from 'libhps2core.so';
import { keyCodeToVpad, keyCodeToVpadAxis, axisModelToVpad, normalizeAxisValue }
  from '../common/GamepadKeyMap';

const DOMAIN = 0x3202;
const TAG = 'HPS2_PAD';

@Component
export struct GamepadCatcher {
  /**
   * 是否启用（游玩中才需要）。
   *
   * 命名注意：不能叫 `enabled` —— ArkUI 的 CustomComponent 基类已有
   * 同名属性，会报 "Property 'enabled' is not assignable to the same
   * property in base type 'CustomComponent'"（本次编译期实测）。
   */
  @Prop padEnabled: boolean = true;
  /** 首次收到手柄事件时回调一次，供上层自动隐藏虚拟按键 */
  onFirstEvent?: () => void;

  private firstEventReported: boolean = false;

  /** 一次性诊断：打印原始 keyCode，便于核对不同手柄的实际码值 */
  /** 焦点 id（与 .id() 一致，供 requestFocus 使用） */
  static readonly FOCUS_ID: string = 'hps2_gamepad_catcher';

  private static seenCodes: Set<number> = new Set<number>();
  private static seenAxes: Set<number> = new Set<number>();

  private reportFirst(): void {
    if (!this.firstEventReported) {
      this.firstEventReported = true;
      hilog.info(DOMAIN, TAG, 'gamepad input detected (first event)');
      if (this.onFirstEvent) {
        this.onFirstEvent();
      }
    }
  }

  build() {
    Column()
      // 指定 id：onAppear 时用它主动请求焦点（见下方说明）
      .id(GamepadCatcher.FOCUS_ID)
      // 零尺寸：不参与视觉布局，只用来接收事件
      .width(1)
      .height(1)
      .opacity(0)
      // 关键：必须可获焦并主动请求，否则 onKeyEvent 不会触发
      .focusable(true)
      .defaultFocus(true)
      .onKeyEvent((event: KeyEvent): boolean => {
        if (!this.padEnabled) {
          return false;
        }
        // 只处理按下/抬起；MoveRepeat 等忽略（避免重复触发）
        const isDown = (event.type === KeyType.Down);

        // 诊断：首次见到某个码值时打印一次，便于核对实际手柄
        if (!GamepadCatcher.seenCodes.has(event.keyCode)) {
          GamepadCatcher.seenCodes.add(event.keyCode);
          hilog.info(DOMAIN, TAG, 'KEY code=%{public}d type=%{public}d src=%{public}d',
            event.keyCode, event.type, event.keySource);
        }

        // 1) 普通按键
        const btn = keyCodeToVpad(event.keyCode);
        if (btn >= 0) {
          this.reportFirst();
          hps2core.vpadButton(btn, isDown);
          return true;
        }

        // 2) L2/R2 若以"按键"形式上报，转成轴（按下满量程、抬起归零）
        const ax = keyCodeToVpadAxis(event.keyCode);
        if (ax >= 0) {
          this.reportFirst();
          hps2core.vpadAxis(ax, isDown ? 32767 : 0);
          return true;
        }

        return false;
      })
      // 【关键】手柄摇杆用的是 FocusAxisEvent + onFocusAxisEvent，
      // **不是** AxisEvent + onAxisEvent。
      //   AxisEvent        : 触摸/鼠标的滚轮、捏合（有 displayX/Y、x/y）
      //   FocusAxisEvent   : 手柄摇杆（有 axisMap: Map<AxisModel, number>）
      // 名字里的 "Focus" 也印证了它与焦点相关 —— 与 onKeyEvent 同理。
      // （我最初用 onAxisEvent，编译期报 "Property 'axisMap' does not
      //   exist on type 'AxisEvent'"，据此更正。）
      // 【为什么要手动请求焦点】
      // 本组件在 viewMode='game' 时才挂载，而页面早已构建完毕 ——
      // defaultFocus 只在**页面首次构建**时生效，此时再设无效。
      // 若不主动请求，onKeyEvent/onFocusAxisEvent 都不会触发，
      // 表现为"手柄按了没反应"。
      // 用 FocusController.requestFocus(id) 在挂载后显式取得焦点。
      .onAppear(() => {
        try {
          // 组件自带 getUIContext()，比经 UIAbilityContext.windowStage
          // 再取 mainWindow 的链路更短、失败点更少。
          this.getUIContext().getFocusController().requestFocus(GamepadCatcher.FOCUS_ID);
          hilog.info(DOMAIN, TAG, 'requested focus for gamepad catcher');
        } catch (e) {
          // 拿不到焦点不致命：onKeyEvent 仍可能在其它控件获得焦点时
          // 通过事件冒泡到达。但需记录，便于排查"手柄无反应"。
          hilog.error(DOMAIN, TAG, 'requestFocus failed: %{public}s', JSON.stringify(e));
        }
      })
      // 焦点可能被其它可获焦控件抢走（例如用户点了设置面板），
      // 这里在失焦时不做什么；下次挂载会重新请求。
      .onFocusAxisEvent((event: FocusAxisEvent): void => {
        if (!this.padEnabled) {
          return;
        }
        // axisMap 一次给出当前变化的所有轴
        try {
          const map = event.axisMap;
          if (!map) {
            return;
          }
          map.forEach((value: number, axis: number) => {
            const vax = axisModelToVpad(axis);
            if (vax < 0) {
              return;
            }
            if (!GamepadCatcher.seenAxes.has(axis)) {
              GamepadCatcher.seenAxes.add(axis);
              hilog.info(DOMAIN, TAG, 'AXIS model=%{public}d raw=%{public}d', axis, value);
            }
            this.reportFirst();
            hps2core.vpadAxis(vax, normalizeAxisValue(axis, value));
          });
        } catch (e) {
          hilog.error(DOMAIN, TAG, 'onAxisEvent failed: %{public}s', JSON.stringify(e));
        }
      })
  }
}
