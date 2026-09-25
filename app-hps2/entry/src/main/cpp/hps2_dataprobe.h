/*
 * Hps2 — 阶段 0 数据外置探针（Native 侧）
 *
 * ============================================================================
 * 【为什么必须做成 App 内的代码，而不是 hdc 脚本】
 *
 * 本探针要回答的核心问题是：**应用 UID 能否用普通 POSIX 路径读写公共目录**。
 * 这个问题**不能用 hdc shell 回答** —— shell 的 uid=2000(shell)，SELinux
 * 上下文是 u:r:sh:s0，与应用的 u:r:app:s0 是两套完全不同的策略。
 * 实测：
 *     hdc shell ls /storage/media            -> Permission denied
 *     hdc shell ls /storage/Users/currentUser -> No such file or directory
 * 而应用侧完全可能正常访问。因此必须由**应用进程自己**去实测。
 *
 * ============================================================================
 * 【为什么第 4 项（Native POSIX）才是真正的闸门】
 *
 * 整个 PCSX2 核心（CDVD、记忆卡、ISO 读取）都通过 POSIX open/read/lseek
 * 访问文件，只认**真实路径**。ArkTS 能访问不等于 native 能：
 *   - ArkTS 的 fs 走的是 OpenHarmony 的文件管理框架（可能经 hmdfs/fuse
 *     甚至 URI 授权），而 native 走的是原始 openat(2)；
 *   - 二者在**跨挂载点**、**SELinux 标签**、**FUSE 语义**上的表现可能不同。
 * 若 ArkTS 能而 native 不能，则"数据外置"对模拟器无意义 —— 核心读不到
 * ISO 和记忆卡。故这一项 PASS/FAIL 直接决定方案取舍。
 *
 * ============================================================================
 * 【设计原则】只读 + 自带清理，绝不碰用户既有数据
 *
 * 探针只在 <目标根>/Hps2Probe/ 这个**自建**子目录内做事，且**不删除**
 * 任何非自建文件。它不接触 games/、memcards/ 等真实数据目录。
 */
#pragma once

#include <string>

namespace Hps2DataProbe
{
	/**
	 * 在给定的外部根目录下执行 Native POSIX 读写探测（第 4 项）。
	 *
	 * 依次验证：mkdir -p、open(O_CREAT|O_RDWR)、write、fsync、lseek、
	 * read 回读比对、rename、stat、unlink。
	 * 全部经过真实 POSIX 调用（与 PCSX2 核心访问文件的方式一致）。
	 *
	 * @param root     外部数据根（ArkTS 侧解析出的公共目录）
	 * @param out_json 输出 JSON，含各项结果与 errno
	 * @return 全部通过返回 true
	 */
	bool RunNativeProbe(const std::string& root, std::string& out_json);

	/**
	 * 探测任意路径的 POSIX 可访问性（stat + opendir + 试创建）。
	 * 用于诊断"目录是否存在""是否可枚举"，不写入任何内容。
	 */
	std::string StatPathJson(const std::string& path);

	/**
	 * 从根开始逐级 stat 给定路径的每一层祖先，返回 JSON 数组。
	 *
	 * 【为什么需要】errno=2(ENOENT) 有两种截然不同的成因：
	 *   a) 该路径在应用视角下确实不存在（挂载/命名空间隔离）；
	 *   b) 某一级祖先不可访问，使整条路径"看起来不存在"。
	 * 二者对方案的含义完全不同（前者基本无解，后者可能靠授权解决），
	 * 故必须逐级定位到**断在哪一层**。
	 *
	 * 每层附带 access(F_OK)/access(X_OK)，区分"存在但不可进入"与"不存在"。
	 */
	std::string ProbePathChain(const std::string& path);

	/**
	 * 列出目录条目（只读）。用于枚举应用**实际可见**的挂载点，
	 * 从而判断公共目录在应用命名空间里究竟位于何处。
	 * 返回 JSON: {"path":..,"ok":..,"entries":["a","b"],"errno":n}
	 */
	std::string ListDirJson(const std::string& path);
}
