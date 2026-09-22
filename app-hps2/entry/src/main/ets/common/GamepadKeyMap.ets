/*
 * Hps2 — 蓝牙手柄按键映射
 *
 * 【核心事实】HarmonyOS **已把手柄输入解析成标准按键/轴事件**转发给应用：
 *   - 按键：KeyEvent.keyCode，取值见 @ohos.multimodalInput.keyCode
 *   - 摇杆：AxisEvent.axisMap，键为 AxisModel（**标准 Linux evdev 码**）
 * 因此应用**不需要**自己发现设备、不需要 hidraw、不需要 udev。
 *
 * 【关于 Xbox / PlayStation / Switch 三家手柄】
 * 系统层的按键码是**统一的**（KEYCODE_BUTTON_A/B/X/Y 等），
 * 三家手柄的差异只在**物理布局与标注**：
 *
 *   Xbox      : A(下) B(右) X(左) Y(上)
 *   PlayStation: ×(下) ○(右) □(左) △(上)   —— 与 Xbox 位置一一对应
 *   Switch    : B(下) A(右) Y(左) X(上)   —— 与 Xbox **位置相同、字母互换**
 *
 * 关键结论：**位置对应关系三家一致**，因此把系统按键码映射到
 * PlayStation 的 ×○□△ 即可同时正确支持三家 —— 玩家按哪个位置，
 * 游戏里就是对应的那个键。
 *
 * 无需为三家分别写映射表；这也避免了"接哪种手柄就要换哪套配置"的问题。
 *
 * 【映射去向】复用现有虚拟手柄链路：
 *   手柄事件 → vpadButton()/vpadAxis()
 *   → SDL_SetJoystickVirtual* → SDLInputSource → PCSX2 Pad
 * 即：真实手柄与屏幕虚拟按键走**同一条下游**，只是事件来源不同。
 */

/** 系统按键码 → SDL 虚拟手柄按键编号；未映射返回 -1 */
export function keyCodeToVpad(code: number): number {
  switch (code) {
    // --- 面键：按**物理位置**映射到 PS2 的 ×○□△ ---
    // 下（Xbox A / PS × / Switch B）
    case 2301: return 0;   // SOUTH -> ×
    // 右（Xbox B / PS ○ / Switch A）
    case 2302: return 1;   // EAST  -> ○
    // 左（Xbox X / PS □ / Switch Y）
    case 2304: return 2;   // WEST  -> □
    // 上（Xbox Y / PS △ / Switch X）
    case 2305: return 3;   // NORTH -> △

    // --- 肩键 ---
    case 2307: return 9;   // L1
    case 2308: return 10;  // R1

    // --- Select / Start ---
    // Xbox View / PS Select / Switch -       (KEYCODE_BUTTON_SELECT)
    case 2311: return 4;   // BACK
    // Xbox Menu / PS Start  / Switch +       (KEYCODE_BUTTON_START)
    case 2312: return 6;   // START

    // --- 摇杆按下（L3/R3）---
    case 2314: return 7;   // LEFT_STICK  -> L3
    case 2315: return 8;   // RIGHT_STICK -> R3

    // --- 十字键 ---
    case 2012: return 11;  // DPAD_UP
    case 2013: return 12;  // DPAD_DOWN
    case 2014: return 13;  // DPAD_LEFT
    case 2015: return 14;  // DPAD_RIGHT

    default: return -1;
  }
}

/** 系统按键码 → 虚拟手柄的 L2/R2 轴编号；非扳机返回 -1 */
export function keyCodeToVpadAxis(code: number): number {
  switch (code) {
    // 部分手柄（尤其 Switch 类）把扳机作为**按钮**上报，而非轴。
    // 这里统一转成对应轴：按下给满量程、抬起归零。
    case 2309: return 4;   // KEYCODE_BUTTON_L2 -> LEFT_TRIGGER
    case 2310: return 5;   // KEYCODE_BUTTON_R2 -> RIGHT_TRIGGER
    default: return -1;
  }
}

/** AxisModel（evdev 码）→ 虚拟手柄轴编号；未映射返回 -1 */
export function axisModelToVpad(axis: number): number {
  switch (axis) {
    case 0: return 0;   // ABS_X   -> LEFTX
    case 1: return 1;   // ABS_Y   -> LEFTY
    case 8: return 2;   // ABS_RX  -> RIGHTX
    case 9: return 3;   // ABS_RY  -> RIGHTY
    case 2: return 4;   // ABS_Z   -> LEFT_TRIGGER  (L2)
    case 3: return 5;   // ABS_RZ  -> RIGHT_TRIGGER (R2)
    default: return -1;
  }
}

/** 是否是需要归一化的摇杆轴（扳机通常是 0..255 单极，摇杆是双极） */
export function isStickAxis(axis: number): boolean {
  return axis === 0 || axis === 1 || axis === 8 || axis === 9;
}

/**
 * 把系统轴值换算成虚拟手柄需要的 -32768..32767。
 *
 * 【为什么不能写死】不同手柄/驱动的轴值范围不同：
 *   - 摇杆常见 -32768..32767，也可能是 -255..255
 *   - 扳机常见 0..255（单极），也可能是 -32768..32767
 * 因此这里按"是否双极"分别处理，并按实际范围归一化。
 *
 * 注意：本函数只做**数学换算**，不猜测设备；
 * 若实测发现某手柄范围异常，应在此处按其真实范围调整。
 */
export function normalizeAxisValue(axis: number, raw: number): number {
  if (isStickAxis(axis)) {
    // 双极轴：假定输入为 -32768..32767；若设备给的是其它范围，
    // 按比例缩放到该区间。
    if (raw >= -32768 && raw <= 32767) {
      return Math.round(raw);
    }
    // 可能是 -255..255 之类的范围
    const v = Math.max(-255, Math.min(255, raw));
    return Math.round(v / 255 * 32767);
  }
  // 单极轴（扳机）：0..max -> 0..32767
  const v = Math.max(0, raw);
  if (v <= 255) {
    return Math.round(v / 255 * 32767);
  }
  return Math.min(32767, Math.round(v));
}
