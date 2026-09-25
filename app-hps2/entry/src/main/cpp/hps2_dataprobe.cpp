/*
 * Hps2 — 阶段 0 数据外置探针（Native 侧实现）
 *
 * 见 hps2_dataprobe.h 的设计说明。本文件只做一件事：
 * 用**与 PCSX2 核心完全相同的方式**（POSIX fd + stdio）去读写外部目录，
 * 并把每一项结果结构化输出。
 *
 * 注意本文件刻意**不使用任何上游 PCSX2 类型**：探针要验证的是"裸 POSIX
 * 在当前 OHOS 沙箱策略下能否工作"，若借道上游的 FileSystem 封装，一旦
 * 失败就分不清是策略问题还是封装问题。
 */
#include "hps2_dataprobe.h"

#include <hilog/log.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3202
#define LOG_TAG "HPS2_DATAPROBE"

#define PLOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO,  LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define PLOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace Hps2DataProbe
{
	namespace
	{
		/** JSON 字符串转义（路径可能含中文，UTF-8 原样透传即可） */
		std::string Esc(const std::string& s)
		{
			std::string o;
			o.reserve(s.size() + 8);
			for (char c : s)
			{
				switch (c)
				{
					case '"':  o += "\\\""; break;
					case '\\': o += "\\\\"; break;
					case '\n': o += "\\n";  break;
					case '\r': o += "\\r";  break;
					case '\t': o += "\\t";  break;
					default:
						if (static_cast<unsigned char>(c) < 0x20)
						{
							char buf[8];
							std::snprintf(buf, sizeof(buf), "\\u%04x", c);
							o += buf;
						}
						else
						{
							o += c;
						}
				}
			}
			return o;
		}

		/** 一项探测结果 */
		struct Step
		{
			std::string name;
			bool ok = false;
			int err = 0;                 // 失败时的 errno（0 表示无错误）
			std::string detail;          // 附加说明（如读回字节数）
		};

		std::string StepJson(const Step& s)
		{
			std::string j = "{\"ok\":" + std::string(s.ok ? "true" : "false");
			j += ",\"errno\":" + std::to_string(s.err);
			if (!s.detail.empty())
				j += ",\"detail\":\"" + Esc(s.detail) + "\"";
			j += "}";
			return j;
		}

		/** 递归创建目录（等价 mkdir -p），返回最终目录是否可用 */
		bool MkdirP(const std::string& path, int& first_errno)
		{
			if (path.empty())
				return false;

			std::string cur;
			cur.reserve(path.size());
			size_t i = 0;
			if (path[0] == '/')
			{
				cur = "/";
				i = 1;
			}

			bool all_ok = true;
			while (i <= path.size())
			{
				const size_t slash = path.find('/', i);
				const std::string seg = path.substr(i, slash == std::string::npos ? std::string::npos : slash - i);
				if (!seg.empty())
				{
					if (!cur.empty() && cur.back() != '/')
						cur += '/';
					cur += seg;

					if (::mkdir(cur.c_str(), 0771) != 0 && errno != EEXIST)
					{
						all_ok = false;
						if (first_errno == 0)
							first_errno = errno;
					}
				}
				if (slash == std::string::npos)
					break;
				i = slash + 1;
			}
			return all_ok;
		}

		/** 目录是否存在且可进入 */
		bool DirUsable(const std::string& path, int& err)
		{
			struct stat st {};
			if (::stat(path.c_str(), &st) != 0)
			{
				err = errno;
				return false;
			}
			if (!S_ISDIR(st.st_mode))
			{
				err = ENOTDIR;
				return false;
			}
			DIR* d = ::opendir(path.c_str());
			if (!d)
			{
				err = errno;
				return false;
			}
			::closedir(d);
			return true;
		}
	}  // namespace

	// -----------------------------------------------------------------------
	// 第 4 项：Native POSIX 读写探测
	//
	// 顺序与 PCSX2 核心实际用文件的方式对齐：
	//   open -> write -> fsync -> lseek(回绕/定位) -> read 回读校验
	//   -> close -> rename -> stat -> unlink
	// 另加一段 stdio（fopen/fwrite/fread）：核心的若干路径走 FILE*，
	// 而 stdio 在 FUSE 上的缓冲/定位语义与裸 fd 可能不同。
	// -----------------------------------------------------------------------
	bool RunNativeProbe(const std::string& root, std::string& out_json)
	{
		std::vector<Step> steps;

		const std::string probe_dir = root + "/Hps2Probe";
		const std::string file_a    = probe_dir + "/probe.bin";
		const std::string file_b    = probe_dir + "/probe-renamed.bin";

		// 测试负载：一段可辨识的魔数 + 4096 字节模式（跨页，能暴露 FUSE 的
		// 部分读写问题）。总长 9 + 4096 = 4105 字节。
		const char kMagic[] = "HPS2PROBE";
		std::vector<unsigned char> payload;
		payload.reserve(4105);
		for (char c : kMagic)
			payload.push_back(static_cast<unsigned char>(c));
		for (int i = 0; i < 4096; ++i)
			payload.push_back(static_cast<unsigned char>(i & 0xFF));

		// --- mkdir ---
		{
			Step s;
			s.name = "mkdir";
			int e = 0;
			const bool made = MkdirP(probe_dir, e);
			int du = 0;
			const bool usable = DirUsable(probe_dir, du);
			s.ok = made && usable;
			s.err = usable ? 0 : (du ? du : e);
			if (!s.ok)
				s.detail = "mkdir/opendir failed";
			steps.push_back(s);
		}

		// --- create ---
		int fd = -1;
		{
			Step s;
			s.name = "create";
			::unlink(file_a.c_str());
			fd = ::open(file_a.c_str(), O_CREAT | O_TRUNC | O_RDWR, 0660);
			s.ok = (fd >= 0);
			s.err = s.ok ? 0 : errno;
			steps.push_back(s);
		}

		// --- write ---
		size_t written = 0;
		if (fd >= 0)
		{
			Step s;
			s.name = "write";
			const ssize_t n = ::write(fd, payload.data(), payload.size());
			s.ok = (n == static_cast<ssize_t>(payload.size()));
			s.err = s.ok ? 0 : errno;
			s.detail = "wrote=" + std::to_string(n);
			written = (n > 0) ? static_cast<size_t>(n) : 0;
			steps.push_back(s);
		}

		// --- fsync ---
		if (fd >= 0)
		{
			Step s;
			s.name = "fsync";
			s.ok = (::fsync(fd) == 0);
			s.err = s.ok ? 0 : errno;
			steps.push_back(s);
		}

		// --- lseek（定位到文件尾取大小，再回绕到中部做部分读） ---
		if (fd >= 0)
		{
			Step s;
			s.name = "seek";
			const off_t end = ::lseek(fd, 0, SEEK_END);
			const off_t mid = ::lseek(fd, 100, SEEK_SET);
			s.ok = (end == static_cast<off_t>(payload.size())) && (mid == 100);
			s.err = s.ok ? 0 : errno;
			s.detail = "end=" + std::to_string(static_cast<long long>(end));
			steps.push_back(s);
		}

		// --- read 回读比对（含一次偏移 100 的部分读） ---
		if (fd >= 0)
		{
			Step s;
			s.name = "readback";
			// 部分读：从偏移 100 读 64 字节
			unsigned char part[64] = {};
			const ssize_t pn = ::pread(fd, part, sizeof(part), 100);
			const bool part_ok = (pn == static_cast<ssize_t>(sizeof(part))) &&
				std::memcmp(part, payload.data() + 100, sizeof(part)) == 0;

			// 全量读
			::lseek(fd, 0, SEEK_SET);
			std::vector<unsigned char> back(payload.size(), 0);
			size_t got = 0;
			while (got < back.size())
			{
				const ssize_t n = ::read(fd, back.data() + got, back.size() - got);
				if (n <= 0)
					break;
				got += static_cast<size_t>(n);
			}
			const bool full_ok = (got == payload.size()) &&
				std::memcmp(back.data(), payload.data(), payload.size()) == 0;

			s.ok = part_ok && full_ok;
			s.err = s.ok ? 0 : errno;
			s.detail = "partial=" + std::to_string(part_ok ? 1 : 0) +
				" full=" + std::to_string(full_ok ? 1 : 0) +
				" bytes=" + std::to_string(got);
			steps.push_back(s);
		}

		// --- stdio（fopen/fwrite/fread） ---
		{
			Step s;
			s.name = "stdio";
			const std::string f = probe_dir + "/stdio.txt";
			bool ok = false;
			std::string detail;
			if (FILE* fp = std::fopen(f.c_str(), "wb"))
			{
				const char msg[] = "hps2-stdio-probe";
				const size_t w = std::fwrite(msg, 1, sizeof(msg) - 1, fp);
				std::fflush(fp);
				std::fclose(fp);
				if (w == sizeof(msg) - 1)
				{
					if (FILE* rp = std::fopen(f.c_str(), "rb"))
					{
						char buf[64] = {};
						const size_t r = std::fread(buf, 1, sizeof(buf) - 1, rp);
						std::fclose(rp);
						ok = (r == sizeof(msg) - 1) && (std::memcmp(buf, msg, sizeof(msg) - 1) == 0);
						detail = "r=" + std::to_string(r);
					}
					else
					{
						detail = "fopen(r) failed";
					}
				}
				else
				{
					detail = "fwrite=" + std::to_string(w);
				}
				::unlink(f.c_str());
			}
			else
			{
				detail = "fopen(w) failed";
			}
			s.ok = ok;
			s.err = ok ? 0 : errno;
			if (!detail.empty())
				s.detail = detail;
			steps.push_back(s);
		}

		// --- close ---
		if (fd >= 0)
		{
			Step s;
			s.name = "close";
			s.ok = (::close(fd) == 0);
			s.err = s.ok ? 0 : errno;
			steps.push_back(s);
			fd = -1;
		}

		// --- rename（同目录内，验证原子改名。迁移流程的关键操作） ---
		{
			Step s;
			s.name = "rename";
			::unlink(file_b.c_str());
			s.ok = (::rename(file_a.c_str(), file_b.c_str()) == 0);
			s.err = s.ok ? 0 : errno;
			steps.push_back(s);
		}

		// --- stat（确认大小正确） ---
		{
			Step s;
			s.name = "stat";
			struct stat st {};
			const bool got = (::stat(file_b.c_str(), &st) == 0);
			s.ok = got && (st.st_size == static_cast<off_t>(payload.size()));
			s.err = got ? 0 : errno;
			s.detail = got ? ("size=" + std::to_string(static_cast<long long>(st.st_size))) : "stat failed";
			steps.push_back(s);
		}

		// --- unlink（清理，避免在用户目录留下垃圾） ---
		{
			Step s;
			s.name = "unlink";
			s.ok = (::unlink(file_b.c_str()) == 0);
			s.err = s.ok ? 0 : errno;
			steps.push_back(s);
		}

		// --- 汇总 ---
		bool all_ok = true;
		std::string steps_json;
		for (size_t i = 0; i < steps.size(); ++i)
		{
			if (!steps[i].ok)
				all_ok = false;
			if (i)
				steps_json += ",";
			steps_json += "\"" + Esc(steps[i].name) + "\":" + StepJson(steps[i]);
		}

		out_json = "{\"root\":\"" + Esc(root) + "\",\"probeDir\":\"" + Esc(probe_dir) +
			"\",\"ok\":" + (all_ok ? "true" : "false") + ",\"steps\":{" + steps_json + "}}";

		// 逐项日志：便于 hilog 直接抓取判读
		for (const Step& s : steps)
		{
			PLOGI("DATA_PROBE native_%{public}s=%{public}s errno=%{public}d",
				s.name.c_str(), s.ok ? "PASS" : "FAIL", s.err);
		}
		PLOGI("DATA_PROBE native_rw_seek=%{public}s", all_ok ? "PASS" : "FAIL");
		return all_ok;
	}

	// -----------------------------------------------------------------------
	// 路径可访问性诊断（只读，不写入任何内容）
	// -----------------------------------------------------------------------
	std::string StatPathJson(const std::string& path)
	{
		std::string j = "{\"path\":\"" + Esc(path) + "\"";

		struct stat st {};
		if (::stat(path.c_str(), &st) == 0)
		{
			j += ",\"exists\":true";
			j += ",\"isDir\":" + std::string(S_ISDIR(st.st_mode) ? "true" : "false");
			j += ",\"mode\":" + std::to_string(static_cast<unsigned>(st.st_mode & 07777));
			j += ",\"uid\":" + std::to_string(static_cast<long long>(st.st_uid));
			j += ",\"gid\":" + std::to_string(static_cast<long long>(st.st_gid));

			if (S_ISDIR(st.st_mode))
			{
				int count = 0;
				if (DIR* d = ::opendir(path.c_str()))
				{
					while (struct dirent* e = ::readdir(d))
					{
						if (std::strcmp(e->d_name, ".") != 0 && std::strcmp(e->d_name, "..") != 0)
							++count;
					}
					::closedir(d);
					j += ",\"listable\":true,\"entries\":" + std::to_string(count);
				}
				else
				{
					j += ",\"listable\":false,\"listErrno\":" + std::to_string(errno);
				}
			}
		}
		else
		{
			j += ",\"exists\":false,\"statErrno\":" + std::to_string(errno);
		}

		j += "}";
		PLOGI("DATA_PROBE stat_path=%{public}s", j.c_str());
		return j;
	}

	// -----------------------------------------------------------------------
	// 逐级祖先诊断：定位访问能力的"断点"在哪一层。
	//
	// 背景：真机实测 /storage/media/100/local/files/Docs/Download 对应用
	// 返回 errno=2(ENOENT)，但同一路径在 hdc shell（uid=2000）下可见。
	// 需判断这是"挂载点对应用不可见"还是"某级祖先被拒绝进入" ——
	// 前者基本无解，后者可能靠授权解决，二者对方案含义完全不同。
	// -----------------------------------------------------------------------
	std::string ProbePathChain(const std::string& path)
	{
		std::string out = "[";
		std::string cur;
		bool first = true;
		size_t i = 0;

		while (i < path.size())
		{
			// 跳过多余的分隔符
			while (i < path.size() && path[i] == '/')
				++i;
			if (i >= path.size())
				break;

			const size_t slash = path.find('/', i);
			const std::string seg =
				path.substr(i, slash == std::string::npos ? std::string::npos : slash - i);

			if (!seg.empty())
			{
				cur += '/';
				cur += seg;

				struct stat st {};
				const int sr = ::stat(cur.c_str(), &st);
				const int se = (sr == 0) ? 0 : errno;
				const bool f_ok = (::access(cur.c_str(), F_OK) == 0);
				const bool x_ok = (::access(cur.c_str(), X_OK) == 0);
				const bool is_dir = (sr == 0) && S_ISDIR(st.st_mode);

				if (!first)
					out += ",";
				first = false;
				out += "{\"p\":\"" + Esc(cur) + "\",\"stat\":";
				out += (sr == 0) ? "true" : "false";
				out += ",\"errno\":" + std::to_string(se);
				out += ",\"dir\":";
				out += is_dir ? "true" : "false";
				out += ",\"f\":";
				out += f_ok ? "true" : "false";
				out += ",\"x\":";
				out += x_ok ? "true" : "false";
				out += "}";
			}

			if (slash == std::string::npos)
				break;
			i = slash;
		}
		out += "]";

		PLOGI("DATA_PROBE path_chain=%{public}s", out.c_str());
		return out;
	}

	// -----------------------------------------------------------------------
	// 枚举目录条目（只读）。
	//
	// 【为什么需要】逐级诊断已定位断点：应用视角下 /storage 可见，
	// 但 /storage/media 直接 ENOENT —— 说明公共存储挂载在应用命名空间里
	// **不位于 /storage/media**。要给出可靠结论，必须枚举应用实际能看到的
	// 顶层目录，看公共存储究竟以什么路径暴露（或根本未暴露）。
	// -----------------------------------------------------------------------
	std::string ListDirJson(const std::string& path)
	{
		std::string j = "{\"path\":\"" + Esc(path) + "\"";
		DIR* d = ::opendir(path.c_str());
		if (!d)
		{
			j += ",\"ok\":false,\"errno\":" + std::to_string(errno) + "}";
			PLOGI("DATA_PROBE list_dir=%{public}s", j.c_str());
			return j;
		}

		j += ",\"ok\":true,\"entries\":[";
		bool first = true;
		int count = 0;
		while (struct dirent* e = ::readdir(d))
		{
			if (std::strcmp(e->d_name, ".") == 0 || std::strcmp(e->d_name, "..") == 0)
				continue;
			if (!first)
				j += ",";
			first = false;
			j += "\"" + Esc(e->d_name) + "\"";
			++count;
		}
		::closedir(d);
		j += "],\"count\":" + std::to_string(count) + "}";

		PLOGI("DATA_PROBE list_dir=%{public}s", j.c_str());
		return j;
	}
}
