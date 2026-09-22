/*
 * Hps2 — BIOS 文件基本规格检查
 *
 * 【为什么需要】外部反馈"别人启动不了"。经核查，我们的文件选择器
 * **只按后缀名过滤**（.bin/.BIN/.rom/.ROM/.p2b），用户可以选中任何
 * .bin —— 包括其它机种（PS1/PSP）的 bin、损坏文件、不完整的下载。
 * 这些都能选上，但核心无法据其启动，用户只会看到"启动失败"。
 *
 * 【边界声明（重要）】本检查只能排除**明显无效**的文件，
 * **不能证明**该文件是合法且完整的 PS2 BIOS，也无法判断其来源是否合法。
 * 因此 UI 的措辞必须是"可能不是有效的 PS2 BIOS"，
 * 而不是"这是有效的 BIOS" —— 后者会误导用户。
 */
#pragma once

#include <cstdint>
#include <string>

namespace Hps2BiosCheck
{
	/** 检查结果 */
	struct Result
	{
		bool size_ok = false;        // 大小是否为已知的 PS2 BIOS 规格
		bool signature_ok = false;   // 开头是否含 PS2 BIOS 特征串
		uint64_t size = 0;           // 实际大小（字节）
		std::string size_text;       // 人类可读的大小
		std::string message;         // 面向用户的一句话说明
	};

	/** 检查指定路径的文件。文件不存在或无法读取时 size=0。 */
	Result Check(const std::string& path);
}
