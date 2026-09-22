/*
 * Hps2 — BIOS 文件基本规格检查实现。设计说明见 hps2_bioscheck.h。
 */

#include "hps2_bioscheck.h"

#include <cstdio>
#include <cstring>

namespace Hps2BiosCheck
{
	namespace
	{
		/**
		 * 已知的 PS2 BIOS 文件规格。
		 *
		 * 依据：PS2 各型号的 BIOS ROM 大小 —— 早期 2MB（如 SCPH-10000）、
		 * 主流 4MB（SCPH-3xxxx/5xxxx/7xxxx）、后期 8MB。
		 * 只列这些，不把"任何文件大小"都当通过 —— 否则检查失去意义。
		 */
		constexpr uint64_t kKnownSizes[] = {
			2ull * 1024 * 1024,
			4ull * 1024 * 1024,
			8ull * 1024 * 1024,
		};

		bool IsKnownSize(uint64_t n)
		{
			for (const uint64_t s : kKnownSizes)
			{
				if (n == s)
					return true;
			}
			return false;
		}

		std::string HumanSize(uint64_t n)
		{
			if (n >= 1024ull * 1024)
			{
				char buf[64];
				std::snprintf(buf, sizeof(buf), "%.1f MB",
					static_cast<double>(n) / (1024.0 * 1024.0));
				return buf;
			}
			return std::to_string(n) + " B";
		}
	}

	Result Check(const std::string& path)
	{
		Result r;

		std::FILE* fp = std::fopen(path.c_str(), "rb");
		if (!fp)
		{
			r.message = "无法读取该文件。";
			return r;
		}

		// 取大小
		if (std::fseek(fp, 0, SEEK_END) == 0)
		{
			const long end = std::ftell(fp);
			if (end > 0)
				r.size = static_cast<uint64_t>(end);
		}
		r.size_text = HumanSize(r.size);

		// 读开头，找 PS2 BIOS 的特征串。
		//
		// PS2 BIOS ROM 内固定含 "Sony Computer Entertainment" 字样。
		// 在开头 256KB 内搜索即可命中（不同版本位置略有差异）。
		char buf[256 * 1024];
		std::memset(buf, 0, sizeof(buf));
		std::fseek(fp, 0, SEEK_SET);
		const size_t n = std::fread(buf, 1, sizeof(buf), fp);
		std::fclose(fp);

		if (n > 0)
		{
			const char* needle = "Sony Computer Entertainment";
			const size_t needle_len = std::strlen(needle);
			if (n >= needle_len)
			{
				for (size_t i = 0; i + needle_len <= n; ++i)
				{
					if (std::memcmp(buf + i, needle, needle_len) == 0)
					{
						r.signature_ok = true;
						break;
					}
				}
			}
		}

		r.size_ok = IsKnownSize(r.size);

		if (r.size_ok && r.signature_ok)
		{
			r.message = "文件规格正常（" + r.size_text + "）。";
		}
		else if (!r.size_ok && !r.signature_ok)
		{
			r.message = "该文件大小 " + r.size_text + " 不是常见的 PS2 BIOS 规格，"
			            "且未找到 PS2 BIOS 特征串 —— 很可能不是有效的 PS2 BIOS。";
		}
		else if (!r.size_ok)
		{
			r.message = "该文件大小 " + r.size_text + " 不是常见的 PS2 BIOS 规格"
			            "（常见为 2MB / 4MB / 8MB）—— 请确认文件是否正确。";
		}
		else
		{
			r.message = "该文件大小正常（" + r.size_text + "），但未找到 PS2 BIOS "
			            "特征串 —— 可能已损坏或不是完整的 PS2 BIOS。";
		}

		return r;
	}
}
