#include "../app-hps2/entry/src/main/cpp/hps2_perf_diagnostics.h"

#include <cassert>
#include <cmath>
#include <iostream>

using namespace Hps2PerfDiagnostics;

static std::string Stat(const std::string& user, const std::string& system)
{
	std::string stat = "123 (GS worker ) name) S";
	for (int field = 4; field <= 52; ++field)
		stat += " " + (field == 14 ? user : field == 15 ? system : field == 39 ? "13" : "0");
	return stat;
}

int main()
{
	const auto previous = ParseThreadStat(Stat("100", "200"));
	const auto current = ParseThreadStat(Stat("110", "285"));
	assert(previous.valid && current.valid);
	assert(current.user_ticks == 110 && current.system_ticks == 285 && current.cpu == 13);
	const auto usage = Usage(previous, current, 1.0, 100);
	assert(std::abs(usage.user_percent - 10.0) < 0.001);
	assert(std::abs(usage.system_percent - 85.0) < 0.001);
	// 85% of a CPU is distinct from the system share of consumed CPU time.
	assert(std::abs(usage.system_percent / (usage.user_percent + usage.system_percent) - 85.0 / 95.0) < 0.001);
	assert(!ParseThreadStat("123 (GS) S 0 1").valid);
	assert(!ParseThreadStat(Stat("bad", "285")).valid);
	assert(!ParseThreadStat(Stat("-1", "285")).valid);
	assert(!ParseThreadStat(Stat("18446744073709551616", "285")).valid);
	assert(Usage({}, current, 1, 100).system_percent == -1);
	assert(Usage(current, previous, 1, 100).system_percent == -1);
	assert(Usage(previous, current, 0, 100).system_percent == -1);
	assert(Usage(previous, current, 1, -1).system_percent == -1);
	assert(ReadThread(0).valid == false);
	assert(ReadCpuFrequencyKhz(-1) == -1);
	std::cout << "PASS: thread stat parsing, interval CPU accounting, missing/reset counters\n";
}
