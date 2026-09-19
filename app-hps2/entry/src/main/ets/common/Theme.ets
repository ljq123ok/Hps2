/*
 * Hps2 — 视觉主题
 *
 * 日夜模式方案：**使用鸿蒙原生资源限定符**，而不是在代码里手写两套色值。
 *
 * 为什么这样选：
 *   - resources/base/element/color.json    → 浅色（默认）
 *   - resources/dark/element/color.json    → 深色
 *   系统按当前配色模式自动选用对应目录的资源，应用无需判断、无需重启、
 *   且随系统设置自动切换。
 *
 * 用法约定：
 *   颜色一律通过 `Theme.xxx()` **方法**获取（内部调 resourceManager），
 *   不要写成静态常量 —— 静态常量在模块加载时求值一次，
 *   之后切换系统日夜模式不会更新。
 *
 * 若需要固定某种模式（不随系统），可在 EntryAbility 里设置
 * ApplicationContext.setColorMode()。
 */
import resourceManager from '@ohos.resourceManager';
import common from '@ohos.app.ability.common';

export class Theme {
  /**
   * 读取颜色资源。
   *
   * 注意：resourceManager 可能在某些时机（如 aboutToAppear 之前）不可用，
   * 因此包一层 try/catch 并给一个兜底色，避免整个界面因取色失败而白屏。
   */
  private static color(name: string, fallback: string): string {
    try {
      const ctx = getContext() as common.UIAbilityContext;
      const mgr: resourceManager.ResourceManager = ctx.resourceManager;
      const id: number = mgr.getColorByNameSync(name);
      const v = mgr.getColorSync(id);
      // getColorSync 返回 number（ARGB），转成 #AARRGGBB
      const argb = v >>> 0;
      return '#' + argb.toString(16).padStart(8, '0').toUpperCase();
    } catch (e) {
      return fallback;
    }
  }

  // ---- 背景层次 ----
  static bgDeep(): string    { return Theme.color('hps2_bg_deep', '#0B0F17'); }
  static bgBase(): string    { return Theme.color('hps2_bg_base', '#111827'); }
  static bgCard(): string    { return Theme.color('hps2_bg_card', '#1B2233'); }
  static bgCardHi(): string  { return Theme.color('hps2_bg_card_hi', '#232C41'); }
  static bgGlass(): string   { return Theme.color('hps2_bg_glass', '#26FFFFFF'); }

  // ---- 文字 ----
  static textPri(): string   { return Theme.color('hps2_text_pri', '#F9FAFB'); }
  static textSec(): string   { return Theme.color('hps2_text_sec', '#9CA3AF'); }
  static textDim(): string   { return Theme.color('hps2_text_dim', '#6B7280'); }

  // ---- 强调色 ----
  static accent(): string    { return Theme.color('hps2_accent', '#3B82F6'); }
  static accentHi(): string  { return Theme.color('hps2_accent_hi', '#60A5FA'); }
  static ok(): string        { return Theme.color('hps2_ok', '#22C55E'); }
  static warn(): string      { return Theme.color('hps2_warn', '#F59E0B'); }
  static err(): string       { return Theme.color('hps2_err', '#EF4444'); }

  // ---- 边框 ----
  static border(): string    { return Theme.color('hps2_border', '#2A3548'); }
  static borderHi(): string  { return Theme.color('hps2_border_hi', '#3B4A63'); }

  // ---- 提示面板 ----
  static panelWarnBg(): string { return Theme.color('hps2_panel_warn_bg', '#2A2416'); }
  static panelWarnBd(): string { return Theme.color('hps2_panel_warn_bd', '#5B4A1F'); }
  static panelErrBg(): string  { return Theme.color('hps2_panel_err_bg', '#2A1518'); }
  static panelErrBd(): string  { return Theme.color('hps2_panel_err_bd', '#5B2A2F'); }

  // ---- 虚拟按键 / 叠加层 ----
  static padBtnBg(): string     { return Theme.color('hps2_pad_btn_bg', '#33FFFFFF'); }
  static padBtnBorder(): string { return Theme.color('hps2_pad_btn_border', '#66FFFFFF'); }
  static overlayScrim(): string { return Theme.color('hps2_overlay_scrim', '#B3000000'); }
  static overlayChip(): string  { return Theme.color('hps2_overlay_chip', '#99000000'); }
  // 游戏画面黑边恒为黑色（与主题无关 —— 那是画面区域，不是 UI）
  static letterbox(): string    { return '#000000'; }

  // ---- 尺寸（与主题无关，保持静态常量）----
  static readonly radius: number = 14;
  static readonly radiusSm: number = 10;
  static readonly gap: number = 12;
  static readonly pad: number = 16;
  static readonly btnSize: number = 52;
}
