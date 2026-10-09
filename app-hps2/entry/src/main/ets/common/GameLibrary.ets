/*
 * Hps2 — 游戏库的共享类型与展示助手
 *
 * 【为什么单独成模块】
 *   列表数据既要给 Index（扫描、选中逻辑）用，也要给 HomeScreen（渲染）用。
 *   类型定义在本项目里按既有约定放在 common/ 下（同类：PadLayout.ets、
 *   GamepadKeyMap.ets），避免两个组件各写一份 interface 而漂移。
 *
 * 【数据来源】native 的 listGames(gamesDir) 扫描 games/ 目录得出：
 *   - serial / title / crc / 兼容性等级来自镜像内的 ELF 头与 GameDB
 *   - 扫描失败时 invalid=true，此时只有 name/path/size 可用
 *     （仍列出来，让用户看出"这个镜像没被识别"，而不是凭空消失）
 */

/** 游戏库里的一项（对应 native listGames() 的单个元素）*/
export interface GameEntry {
  name: string;
  path: string;
  size: number;
  /** true = 未能识别（镜像损坏/非 PS2 镜像）；此时 serial/title 均为空 */
  invalid: boolean;
  serial: string;
  title: string;
  titleEn: string;
  region: number;
  type: number;
  crc: number;
  compatibility: number;
  lastPlayed: number;
}

/** 人类可读的文件大小 */
export function humanSize(n: number): string {
  if (!Number.isFinite(n) || n <= 0) {
    return '0 B';
  }
  if (n >= 1073741824) {
    return (n / 1073741824).toFixed(2) + ' GB';
  }
  if (n >= 1048576) {
    return (n / 1048576).toFixed(1) + ' MB';
  }
  if (n >= 1024) {
    return (n / 1024).toFixed(1) + ' KB';
  }
  return n + ' B';
}

/** 列表项主标题：优先游戏库识别出的正式名称，退回文件名 */
export function gameDisplayTitle(g: GameEntry): string {
  if (g.title && g.title.length > 0) {
    return g.title;
  }
  if (g.titleEn && g.titleEn.length > 0) {
    return g.titleEn;
  }
  return g.name;
}

/** 列表项副标题：serial + 大小（未识别时如实说明）*/
export function gameDisplaySubtitle(g: GameEntry): string {
  if (g.invalid) {
    return '未能识别（' + humanSize(g.size) + '）';
  }
  const parts: Array<string> = [];
  if (g.serial && g.serial.length > 0) {
    parts.push(g.serial);
  }
  parts.push(humanSize(g.size));
  return parts.join(' · ');
}

/**
 * 兼容性等级文字。
 *
 * 数值取自上游 GameDatabaseSchema::CompatibilityRating：
 *   0=Unknown 1=Nothing 2=Intro 3=Menu 4=InGame 5=Playable 6=Perfect
 * 只对"能看出问题"的等级给出提示，其余留空以免干扰视线。
 */
export function compatibilityLabel(rating: number): string {
  switch (rating) {
    case 1: return '无法运行';
    case 2: return '仅片头';
    case 3: return '仅菜单';
    case 4: return '可进游戏';
    default: return '';
  }
}
