/*
 * Hps2 — 视觉主题常量
 *
 * 集中管理颜色与尺寸，避免散落在各组件里。
 * 配色参考设计稿：深色底 + 蓝色强调 + 半透明玻璃质感。
 */
export class Theme {
  // 背景层次（由深到浅）
  static readonly bgDeep: string = '#0B0F17';       // 最底层
  static readonly bgBase: string = '#111827';       // 页面背景
  static readonly bgCard: string = '#1B2233';       // 卡片
  static readonly bgCardHi: string = '#232C41';     // 卡片高亮/悬停
  static readonly bgGlass: string = '#26FFFFFF';    // 玻璃层（半透明白）

  // 文字
  static readonly textPri: string = '#F9FAFB';
  static readonly textSec: string = '#9CA3AF';
  static readonly textDim: string = '#6B7280';

  // 强调色
  static readonly accent: string = '#3B82F6';       // 主蓝
  static readonly accentHi: string = '#60A5FA';     // 亮蓝
  static readonly ok: string = '#22C55E';           // 成功/可用
  static readonly warn: string = '#F59E0B';         // 警告
  static readonly err: string = '#EF4444';          // 错误

  // 边框
  static readonly border: string = '#2A3548';
  static readonly borderHi: string = '#3B4A63';

  // 尺寸
  static readonly radius: number = 14;
  static readonly radiusSm: number = 10;
  static readonly gap: number = 12;
  static readonly pad: number = 16;

  // 虚拟按键
  static readonly btnSize: number = 52;
  static readonly btnOpacity: string = '#33FFFFFF';
  static readonly btnBorder: string = '#66FFFFFF';
}
