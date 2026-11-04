// Exercises the production WorkSema and MTVU batching policy together, including
// deferred tails, sleep races, explicit drains and queue-full flushes.
#include "common/Threading.h"
#include "pcsx2/MTVUNotificationBatch.h"

#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/sync_policy.h>
#endif

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

[[noreturn]] static void Fail(const char* message)
{
	std::fprintf(stderr, "FAIL: %s\n", message);
	std::abort();
}

void pxOnAssertFail(const char*, int, const char*, const char* message)
{
	Fail(message);
}

extern const u32 SPIN_TIME_NS = 0;
u32 ShortSpinOn(const std::atomic<s32>&, s32)
{
	std::this_thread::yield();
	return 1;
}

#if defined(__APPLE__)
// Semaphore.cpp supplies the production WorkSema. On macOS its kernel backend
// normally lives in DarwinThreads.cpp; bind the same Mach primitives here.
namespace Threading
{
KernelSemaphore::KernelSemaphore()
{
	if (semaphore_create(mach_task_self(), &m_sema, SYNC_POLICY_FIFO, 0) != KERN_SUCCESS)
		Fail("semaphore_create");
}
KernelSemaphore::~KernelSemaphore()
{
	semaphore_destroy(mach_task_self(), m_sema);
}
void KernelSemaphore::Post()
{
	semaphore_signal(m_sema);
}
void KernelSemaphore::Wait()
{
	kern_return_t result;
	do
	{
		result = semaphore_wait(m_sema);
	} while (result == KERN_ABORTED);
	if (result != KERN_SUCCESS)
		Fail("semaphore_wait");
}
bool KernelSemaphore::TryWait()
{
	mach_timespec_t zero{};
	return semaphore_timedwait(m_sema, zero) == KERN_SUCCESS;
}
} // namespace Threading
#endif

static void Run(unsigned boundary, unsigned capacity = 100000)
{
	constexpr unsigned count = 100000;
	Threading::WorkSema sema;
	MTVUNotificationBatch batch;
	std::vector<unsigned> payload(capacity);
	std::atomic<unsigned> tail{0}, done{0};
	std::atomic<bool> stop{false};
	std::thread worker([&] {
		unsigned head = 0;
		for (;;)
		{
			sema.WaitForWorkWithSpin();
			if (stop.load(std::memory_order_acquire))
				break;
			while (head < tail.load(std::memory_order_acquire))
			{
				if (payload[head % capacity] != (head ^ 0xa5a5a5a5u))
					Fail("publication order / payload corruption");
				++head;
				done.store(head, std::memory_order_release);
			}
		}
		sema.Kill();
	});

	unsigned notifications = 0, backpressure = 0;
	auto kick = [&] {
		batch.OnNotify();
		++notifications;
		sema.NotifyOfWork();
	};
	auto drain = [&] {
		if (batch.HasPending())
			kick();
		sema.WaitForEmpty();
		if (done.load(std::memory_order_acquire) != tail.load(std::memory_order_acquire))
			Fail("deferred tail not drained");
	};

	for (unsigned i = 0; i < count; i++)
	{
		while (i - done.load(std::memory_order_acquire) >= capacity)
		{
			++backpressure;
			kick();
			std::this_thread::yield();
		}
		payload[i % capacity] = i ^ 0xa5a5a5a5u;
		tail.store(i + 1, std::memory_order_release);
		if (batch.OnUnpack())
		{
			++notifications;
			sema.NotifyOfWork();
		}
		// Same policy boundaries as ExecuteVU/other commands and WaitVU.
		if ((i + 1) % boundary == 0)
		{
			kick();
			if ((i & 7) == 0)
				drain();
		}
		if ((i % 997) == 0)
			drain();
		if ((i % 4093) == 0)
			std::this_thread::yield();
	}
	drain();
	if (boundary >= 257 && backpressure == 0 && notifications >= count / 2)
		Fail("redundant unpack notifications were not coalesced");
	stop.store(true, std::memory_order_release);
	sema.NotifyOfWork();
	worker.join();
	std::printf("PASS boundary=%u capacity=%u commands=%u notifications=%u backpressure=%u\n",
		boundary, capacity, count, notifications, backpressure);
}

int main()
{
	std::thread watchdog([] {
		std::this_thread::sleep_for(std::chrono::seconds(20));
		Fail("lost wake / drain timeout");
	});
	watchdog.detach();
	for (unsigned n : {1u, 2u, 7u, 8u, 9u, 257u, 100001u})
		Run(n);
	Run(257, 3);
	Run(100001, 7);
	std::puts("PASS production WorkSema batching, deferred tails, publication, drain and shutdown");
	return 0;
}
