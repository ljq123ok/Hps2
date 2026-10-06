/*
 * Hps2 — 虚拟手柄的可定制布局
 *
 * 【为什么需要独立模块】
 *   VirtualPad 的坐标原本全部由公式算出（btn()/midY()/controlLeftX() 等），
 *   用户完全无法调整。不同机型的握持姿势、屏幕比例差异很大，
 *   固定布局必然有人觉得别扭（本项目早期就因按键挤压/压住画面反复修过）。
 *
 * 【设计要点】
 *   1. 存**归一化偏移**而非绝对坐标 —— 绝对像素换机型就错位。
 *      偏移量按屏宽/屏高比例存储，恢复时再乘回去。
 *   2. 横竖屏**各存一套** —— VirtualPad.ets 里已引用 PPSSPP 1.20 的经验：
 *      "触控按键布局与画面显示布局在横竖屏下分别独立设置"。
 *      两种方向的黑边空间差别很大（竖屏上下各约 172vp，横屏左右仅约 79vp），
 *      共用一套必然有一边别扭。
 *   3. 拖拽单位是**控件组**而非单个按键（对齐设计稿 03-edit-layout.jpg）：
 *      摇杆连底座一起移动、四键成组移动。单键拖拽复杂度高但价值有限。
 *
 * 【持久化】与 video-settings.json 同目录、同风格（JSON + 容错读取），
 *   写入失败不阻止游戏运行 —— 与既有设置的约定保持一致。
 */
import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';

const DOMAIN = 0x3202;
const TAG = 'HPS2_CORE';

/** 可拖拽的控件组标识 */
export enum PadGroup {
  // 肩键/扳机左右**分开** —— 对齐设计稿：LT 与 RT 各有独立选框。
  // 合成"顶部整条"会得到一个横跨全屏的大框，既难拖也易误触。
  LEFT_SHOULDER = 'leftShoulder',   // L1 / L2
  RIGHT_SHOULDER = 'rightShoulder', // R1 / R2
  DPAD = 'dpad',                    // 十字键
  FACE = 'face',                    // △○□× 四键
  SYSTEM = 'system',                // SELECT / START（设计稿中是一个框）
  LEFT_STICK = 'leftStick',
  RIGHT_STICK = 'rightStick',
}

/** 全部组（用于遍历、重置、序列化） */
export const ALL_PAD_GROUPS: Array<PadGroup> = [
  PadGroup.LEFT_SHOULDER,
  PadGroup.RIGHT_SHOULDER,
  PadGroup.DPAD,
  PadGroup.FACE,
  PadGroup.SYSTEM,
  PadGroup.LEFT_STICK,
  PadGroup.RIGHT_STICK,
];

/** 单个组的归一化偏移（相对默认位置，按屏宽/屏高比例） */
export interface PadOffset {
  dx: number;   // 屏幕宽度的比例，如 0.05 = 右移 5% 屏宽
  dy: number;   // 屏幕高度的比例
}

/** 一种屏幕方向下的完整布局 */
export interface PadLayoutVariant {
  offsets: Map<string, PadOffset>;
  /** 按键不透明度 0.15–1.0（设计稿默认 60%）*/
  opacity: number;
}

/** 落盘结构（Map 不能直接 JSON 序列化，故用普通对象） */
interface PadLayoutFile {
  version: number;
  landscape: PadLayoutData;
  portrait: PadLayoutData;
}

interface PadLayoutData {
  offsets: Record<string, PadOffset>;
  opacity: number;
}

/**
 * 按键配色。
 *
 * 【为什么不跟随日夜主题】VirtualPad.ets 已有明确结论：按键叠在**游戏画面**上，
 * 画面可能雪白也可能漆黑；跟随 UI 主题会导致浅色模式下按键"消失"。
 * 因此这里存的是按键自身的**基色**（白色系），只调透明度，不引入深浅两套。
 *
 * 设计稿提供 7 个色块；这里映射为按钮基色 + 文字色，
 * 保证在任何游戏画面上都有足够对比度。
 */
export interface PadStyle {
  name: string;
  /** 按钮背景（含 alpha 的 #AARRGGBB）*/
  bg: string;
  /** 按钮边框 */
  border: string;
  /** 文字/图形颜色 */
  fg: string;
}

export const PAD_STYLES: Array<PadStyle> = [
  { name: '默认', bg: '#40FFFFFF', border: '#80FFFFFF', fg: '#FFFFFF' },
  { name: '灰', bg: '#40000000', border: '#80000000', fg: '#E8E8E8' },
  { name: '蓝', bg: '#503A7EFF', border: '#903A7EFF', fg: '#FFFFFF' },
  { name: '红', bg: '#50E5484D', border: '#90E5484D', fg: '#FFFFFF' },
  { name: '绿', bg: '#5046A758', border: '#9046A758', fg: '#FFFFFF' },
  { name: '黄', bg: '#50F5C24B', border: '#90F5C24B', fg: '#FFFFFF' },
  { name: '紫', bg: '#50A855F7', border: '#90A855F7', fg: '#FFFFFF' },
];

/** 布局的默认值（与 VirtualPad 的公式输出叠加时，偏移全 0） */
export function defaultVariant(): PadLayoutVariant {
  return {
    offsets: new Map<string, PadOffset>(),
    // 设计稿默认 60%。0.6 在"看得清"与"不遮挡画面"之间，
    // 且低于 1.0 时游戏画面仍可透出，符合设计稿的半透明观感。
    opacity: 0.6,
  };
}

/** 取某组的偏移；没有自定义时返回零偏移 */
export function offsetOf(v: PadLayoutVariant, group: PadGroup): PadOffset {
  const o = v.offsets.get(group as string);
  if (o && Number.isFinite(o.dx) && Number.isFinite(o.dy)) {
    return o;
  }
  return { dx: 0, dy: 0 };
}

/**
 * 设置某组偏移，并做**边界钳制**。
 *
 * 为什么必须钳制：拖出屏幕外的按键用户再也点不到，且没有任何提示 ——
 * 等于把虚拟手柄弄坏了。钳制范围保守（±45% 屏宽 / ±45% 屏高），
 * 既留足摆放自由，又保证控件主体始终可见。
 */
export function setOffset(v: PadLayoutVariant, group: PadGroup, dx: number, dy: number): void {
  const limit = 0.45;
  const cx = Math.max(-limit, Math.min(limit, dx));
  const cy = Math.max(-limit, Math.min(limit, dy));
  v.offsets.set(group as string, { dx: cx, dy: cy });
}

/** 透明度合法范围（低于 0.15 会看不清，高于 1.0 无意义）*/
export const PAD_OPACITY_MIN: number = 0.15;
export const PAD_OPACITY_MAX: number = 1.0;

export function clampOpacity(v: number): number {
  if (!Number.isFinite(v)) {
    return 0.6;
  }
  return Math.max(PAD_OPACITY_MIN, Math.min(PAD_OPACITY_MAX, v));
}

/** 配色索引（存索引而非对象，便于将来增删色板） */
export function clampStyleIndex(i: number): number {
  if (!Number.isInteger(i) || i < 0 || i >= PAD_STYLES.length) {
    return 0;
  }
  return i;
}

export class PadLayoutStore {
  private landscape: PadLayoutVariant = defaultVariant();
  private portrait: PadLayoutVariant = defaultVariant();
  private styleIndex: number = 0;

  private filePath(root: string): string {
    return root + '/pad-layout.json';
  }

  /** 按方向取布局（landscape=true 表示横屏）*/
  variant(landscape: boolean): PadLayoutVariant {
    return landscape ? this.landscape : this.portrait;
  }

  style(): PadStyle {
    return PAD_STYLES[clampStyleIndex(this.styleIndex)];
  }

  getStyleIndex(): number {
    return this.styleIndex;
  }

  setStyleIndex(i: number): void {
    this.styleIndex = clampStyleIndex(i);
  }

  /** 恢复默认（Reset 按钮）：清空偏移、透明度回默认，配色回默认 */
  resetCurrent(landscape: boolean): void {
    if (landscape) {
      this.landscape = defaultVariant();
    } else {
      this.portrait = defaultVariant();
    }
    this.styleIndex = 0;
  }

  private toData(v: PadLayoutVariant): PadLayoutData {
    const offsets: Record<string, PadOffset> = {};
    v.offsets.forEach((val: PadOffset, key: string) => {
      offsets[key] = val;
    });
    return { offsets: offsets, opacity: clampOpacity(v.opacity) };
  }

  /**
   * 写入磁盘。
   *
   * 失败只记日志，不抛出 —— 与 saveVideoSettings 的约定一致：
   * 本次运行已经应用成功，持久化失败不该影响游戏。
   */
  save(root: string): void {
    try {
      const data: PadLayoutFile = {
        version: 1,
        landscape: this.toData(this.landscape),
        portrait: this.toData(this.portrait),
      };
      // 配色索引单独一个字段，避免与 version 1 的旧文件冲突
      const payload = JSON.stringify(data) + '\n' + this.styleIndex.toString();
      const file = fs.openSync(this.filePath(root),
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, payload);
      } finally {
        fs.closeSync(file);
      }
      hilog.info(DOMAIN, TAG, 'saved pad layout (style=%{public}d)', this.styleIndex);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save pad layout failed');
    }
  }

  /**
   * 从磁盘恢复。
   *
   * 容错原则：任何字段缺失/类型不对/越界都**退回默认值**，
   * 绝不让坏文件导致虚拟手柄不可用（那会让游戏没法玩）。
   */
  load(root: string): void {
    try {
      const path = this.filePath(root);
      if (!fs.accessSync(path)) {
        return;
      }
      const raw = fs.readTextSync(path);
      if (!raw || raw.length === 0) {
        return;
      }

      // 末行为配色索引，其余为 JSON（见 save 的 payload 拼装）
      const nl = raw.lastIndexOf('\n');
      const jsonPart = nl >= 0 ? raw.substring(0, nl) : raw;
      if (nl >= 0) {
        const stylePart = raw.substring(nl + 1).trim();
        const si = Number.parseInt(stylePart, 10);
        if (Number.isInteger(si)) {
          this.styleIndex = clampStyleIndex(si);
        }
      }

      const data = JSON.parse(jsonPart) as PadLayoutFile;
      this.landscape = this.readVariant(data.landscape);
      this.portrait = this.readVariant(data.portrait);
      hilog.info(DOMAIN, TAG, 'restored pad layout (style=%{public}d)', this.styleIndex);
    } catch (e) {
      // 坏文件：保持默认布局，不阻断游戏
      hilog.error(DOMAIN, TAG, 'load pad layout failed, using defaults');
      this.landscape = defaultVariant();
      this.portrait = defaultVariant();
      this.styleIndex = 0;
    }
  }

  private readVariant(d: PadLayoutData | undefined): PadLayoutVariant {
    const v = defaultVariant();
    if (!d) {
      return v;
    }
    v.opacity = clampOpacity(d.opacity);
    const src = d.offsets;
    if (src) {
      for (const g of ALL_PAD_GROUPS) {
        const o = src[g as string];
        if (o && Number.isFinite(o.dx) && Number.isFinite(o.dy)) {
          // 复用 setOffset，确保从磁盘加载的值同样经过钳制 ——
          // 手改 JSON 或旧版本写入的越界值都会被收回来。
          setOffset(v, g, o.dx, o.dy);
        }
      }
    }
    return v;
  }
}
