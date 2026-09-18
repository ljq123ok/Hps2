/*
 * Hps2 — 虚拟手柄的按键/轴编号
 *
 * 数值取自 SDL3 的 SDL_GamepadButton / SDL_GamepadAxis 枚举
 * （thirdparty-ohos/prefix/include/SDL3/SDL_gamepad.h），
 * 必须是原生值 —— 不能自行编号，否则 SDL 侧无法识别。
 *
 * PS2 对应关系来自 PCSX2 的 SDL 通用映射表
 * （pcsx2/Input/SDLInputSource.cpp:510-524 与 133-138）：
 *   SOUTH -> ×      EAST  -> ○      WEST -> □      NORTH -> △
 *   BACK  -> Select START -> Start
 *   LEFT_SHOULDER -> L1   RIGHT_SHOULDER -> R1
 *   DPAD_UP/DOWN/LEFT/RIGHT -> 十字键
 *   LEFT_TRIGGER / RIGHT_TRIGGER 是**轴** -> L2 / R2
 *   左摇杆 -> LEFTX/LEFTY，右摇杆 -> RIGHTX/RIGHTY
 */
export class VpadButton {
  static readonly SOUTH: number = 0;   // ×
  static readonly EAST: number = 1;    // ○
  static readonly WEST: number = 2;    // □
  static readonly NORTH: number = 3;   // △
  static readonly BACK: number = 4;    // Select
  static readonly START: number = 6;   // Start
  static readonly LEFT_SHOULDER: number = 9;   // L1
  static readonly RIGHT_SHOULDER: number = 10; // R1
  static readonly DPAD_UP: number = 11;
  static readonly DPAD_DOWN: number = 12;
  static readonly DPAD_LEFT: number = 13;
  static readonly DPAD_RIGHT: number = 14;
}

export class VpadAxis {
  static readonly LEFTX: number = 0;
  static readonly LEFTY: number = 1;
  static readonly RIGHTX: number = 2;
  static readonly RIGHTY: number = 3;
  static readonly LEFT_TRIGGER: number = 4;   // L2（0..32767）
  static readonly RIGHT_TRIGGER: number = 5;  // R2（0..32767）
}
