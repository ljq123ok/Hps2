export const startBios: (dataRoot: string, biosDir: string, gamePath: string) => number;
export const setSurface: (surfaceId: string, width: number, height: number) => number;
export const initVirtualPad: () => number;
export const mapVirtualPad: (port: number) => number;
export const vpadButton: (button: number, pressed: boolean) => number;
export const vpadAxis: (axis: number, value: number) => number;
/** 画面比例：0=自动 1=保持4:3 2=铺满 3=宽屏16:9 */
export const setAspectMode: (mode: number) => number;
export const getAspectMode: () => number;
/** 屏幕方向变化后调用，通知 GS 重建视口与投影 */
export const notifyResize: (width: number, height: number) => number;
export const stop: () => number;
export const getStatus: () => string;
