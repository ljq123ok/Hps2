export const startBios: (dataRoot: string, biosDir: string, gamePath: string) => number;
export const setSurface: (surfaceId: string, width: number, height: number) => number;
export const initVirtualPad: () => number;
/** GameControllerKit 已接管实体手柄时返回 1。 */
export const hasOfficialGamepad: () => number;
export const mapVirtualPad: (port: number) => number;
/** 返回当前已被 SDL 识别的真实手柄，JSON: [{ id, name }] */
export const enumerateControllers: () => string;
/** 将指定真实手柄映射到 PS2 手柄端口，当前会话生效 */
export const mapController: (device: string, port: number) => number;
export const vpadButton: (button: number, pressed: boolean) => number;
export const vpadAxis: (axis: number, value: number) => number;
/** 画面比例：0=自动 1=保持4:3 2=铺满 3=宽屏16:9 */
export const setAspectMode: (mode: number) => number;
export const getAspectMode: () => number;
export const setUpscaleMultiplier: (multiplier: number) => number;
export const getUpscaleMultiplier: () => number;
/** MTVU（VU1 独立线程）。上游默认开启，我们早期为稳定性关闭。**下次启动游戏生效** */
export const setVuThread: (enabled: boolean) => number;
export const getVuThread: () => number;
/** 屏幕方向变化后调用，通知 GS 重建视口与投影 */
export const notifyResize: (width: number, height: number) => number;
/** 暂停/恢复当前 VM；返回 1 表示请求已接受，0 表示没有可用 VM。 */
export const setPaused: (paused: boolean) => number;
export const stop: () => number;
export const getStatus: () => string;
/** 即时存档：存到指定槽（1-based），返回 {ok, message} 的 JSON */
export const saveState: (slot: number) => string;
/** 即时存档：从指定槽读取（1-based） */
export const loadState: (slot: number) => string;
/** 删除指定槽的即时存档及其备份（1-based） */
export const deleteSaveState: (slot: number) => string;
/** 各槽状态：[{slot, hasSave}, ...] */
export const listSaveSlots: () => string;

// ---------------------------------------------------------------------------
// 阶段 0 数据外置探针（临时；阶段 3 落地后移除）
// ---------------------------------------------------------------------------
/**
 * 第 4 项闸门：用与 PCSX2 核心相同的 POSIX 方式探测外部目录。
 *
 * 依次执行 mkdir/open/write/fsync/lseek/read 回读比对/stdio/close/
 * rename/stat/unlink，返回 JSON：
 *   { root, probeDir, ok, steps: { <name>: { ok, errno, detail } } }
 *
 * 为什么必须由 native 测：ArkTS 的 fs 走文件管理框架，native 走原始
 * openat(2)，二者在 SELinux 标签与 FUSE 语义上可能表现不同；而核心
 * 只用后者。ArkTS 能访问不等于核心能用。
 */
export const runDataProbe: (root: string) => string;

/**
 * 只读诊断：路径是否存在、是否目录、权限位、属主、可否枚举。
 * 返回 JSON，不写入任何内容。
 */
export const statDataPath: (path: string) => string;

/**
 * 逐级祖先诊断：返回从根到该路径每一层的 stat/access 结果（JSON 数组）。
 * 用于定位访问能力断在哪一层（区分"不存在"与"存在但不可进入"）。
 */
export const probePathChain: (path: string) => string;

/** 只读枚举目录条目，用于确认应用实际可见的挂载点。 */
export const listDataDir: (path: string) => string;
