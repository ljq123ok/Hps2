#pragma once

#include <charconv>
#include <cstdint>
#include <cstdio>
#include <sstream>
#include <string>

namespace Hps2PerfDiagnostics
{
struct ThreadSample
{
	bool valid = false;
	std::uint64_t user_ticks = 0;
	std::uint64_t system_ticks = 0;
	int cpu = -1;
};

// Linux stat's comm may contain spaces and ')'. Fields start after the LAST ')'.
inline ThreadSample ParseThreadStat(const std::string& stat)
{
	ThreadSample sample;
	const auto close = stat.rfind(')');
	if (close == std::string::npos)
		return sample;
	std::istringstream fields(stat.substr(close + 1));
	std::string token;
	for (int field = 3; field <= 39; ++field)
	{
		if (!(fields >> token))
			return {};
		auto parse = [&](auto& value) {
			const auto result = std::from_chars(token.data(), token.data() + token.size(), value);
			return result.ec == std::errc{} && result.ptr == token.data() + token.size();
		};
		if ((field == 14 && !parse(sample.user_ticks)) ||
			(field == 15 && !parse(sample.system_ticks)) ||
			(field == 39 && !parse(sample.cpu)))
			return {};
	}
	sample.valid = true;
	return sample;
}

inline ThreadSample ReadThread(int tid)
{
	if (tid <= 0)
		return {};
	const std::string path = "/proc/self/task/" + std::to_string(tid) + "/stat";
	std::FILE* fp = std::fopen(path.c_str(), "r");
	if (!fp)
		return {};
	char buffer[4096];
	const bool ok = std::fgets(buffer, sizeof(buffer), fp) != nullptr;
	std::fclose(fp);
	return ok ? ParseThreadStat(buffer) : ThreadSample{};
}

struct ThreadUsage
{
	double user_percent = -1.0;
	double system_percent = -1.0;
};

// Percent of ONE CPU over elapsed wall time; unavailable data stays -1, never zero.
inline ThreadUsage Usage(const ThreadSample& previous, const ThreadSample& current,
	double elapsed_seconds, long ticks_per_second)
{
	if (!previous.valid || !current.valid || elapsed_seconds <= 0 || ticks_per_second <= 0 ||
		current.user_ticks < previous.user_ticks || current.system_ticks < previous.system_ticks)
		return {};
	const double scale = 100.0 / (elapsed_seconds * static_cast<double>(ticks_per_second));
	return {static_cast<double>(current.user_ticks - previous.user_ticks) * scale,
		static_cast<double>(current.system_ticks - previous.system_ticks) * scale};
}

inline long ReadCpuFrequencyKhz(int cpu, const char* attribute = "scaling_cur_freq")
{
	if (cpu < 0)
		return -1;
	const std::string path = "/sys/devices/system/cpu/cpu" + std::to_string(cpu) +
		"/cpufreq/" + attribute;
	std::FILE* fp = std::fopen(path.c_str(), "r");
	if (!fp)
		return -1;
	long value = -1;
	const bool ok = std::fscanf(fp, "%ld", &value) == 1;
	std::fclose(fp);
	return ok && value > 0 ? value : -1;
}
}
