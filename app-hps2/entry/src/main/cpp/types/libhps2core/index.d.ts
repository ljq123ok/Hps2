export const startBios: (dataRoot: string, biosDir: string, gamePath: string) => number;
export const setSurface: (surfaceId: string, width: number, height: number) => number;
export const initVirtualPad: () => number;
export const mapVirtualPad: (port: number) => number;
export const vpadButton: (button: number, pressed: boolean) => number;
export const vpadAxis: (axis: number, value: number) => number;
export const stop: () => number;
export const getStatus: () => string;
