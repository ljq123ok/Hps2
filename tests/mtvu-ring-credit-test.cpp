// Exercises the production credit policy with variable packets, wrap padding,
// delayed consumer publication, and the real WorkSema/notification policy.
#define main NotificationPolicyOriginalMain
#include "mtvu-notification-batch-test.cpp"
#undef main
#include "pcsx2/MTVURingCredit.h"

template<unsigned Capacity, unsigned Guard, unsigned PublishBatch>
static void RunCredit()
{
	using Credit = MTVURingCredit<Capacity, Guard>;
	constexpr unsigned count = 100000;
	constexpr unsigned sentinel = ~0u;
	Credit credit;
	std::vector<unsigned> ring(Capacity);
	std::atomic<unsigned> committed{0};
	std::atomic<std::uint64_t> consumed{0};
	std::atomic<bool> stop{false};
	Threading::WorkSema sema;
	MTVUNotificationBatch notifications;
	std::thread consumer([&] {
		unsigned pos = 0, expected = 0;
		std::uint64_t sequence = 0, published = 0;
		for (;;)
		{
			sema.WaitForWorkWithSpin();
			if (stop.load(std::memory_order_acquire)) break;
			unsigned end = committed.load(std::memory_order_acquire);
			while (pos != end)
			{
				unsigned words = ring[pos];
				if (words == sentinel) pos = 0;
				else
				{
					if (words < 2 || pos + words >= Capacity) Fail("invalid packet");
					for (unsigned i = 1; i < words; ++i)
						if (ring[pos + i] != (expected ^ (i * 0x9e3779b9u))) Fail("overwritten or reordered packet");
					pos += words;
					++expected;
				}
				sequence = Credit::Advance(sequence, pos);
				if (sequence - published >= PublishBatch)
				{
					consumed.store(sequence, std::memory_order_release);
					published = sequence;
				}
				if (pos == end) end = committed.load(std::memory_order_acquire);
			}
			consumed.store(sequence, std::memory_order_release);
			published = sequence;
		}
		if (expected != count) Fail("lost tail packets");
		sema.Kill();
	});
	auto kick = [&] { notifications.OnNotify(); sema.NotifyOfWork(); };
	auto wait = [&](unsigned words) {
		if (!credit.HasSpace(words))
		{
			credit.Refresh(consumed.load(std::memory_order_acquire));
			while (!credit.HasSpace(words))
			{
				kick(); std::this_thread::yield();
				credit.Refresh(consumed.load(std::memory_order_acquire));
			}
		}
	};
	unsigned pos = 0;
	for (unsigned n = 0; n < count; ++n)
	{
		unsigned words = 2 + ((n * 13u) % 19);
		if (pos + words > Capacity - 1)
		{
			wait(Capacity - pos); // Padding is occupied until NULL is consumed.
			ring[pos] = sentinel;
			pos = 0;
			credit.PublishTo(pos);
			committed.store(pos, std::memory_order_release);
		}
		wait(words);
		ring[pos] = words;
		for (unsigned i = 1; i < words; ++i) ring[pos + i] = n ^ (i * 0x9e3779b9u);
		pos += words;
		credit.PublishTo(pos);
		committed.store(pos, std::memory_order_release);
		if (notifications.OnUnpack()) kick();
		if ((n % 337) == 0) { if (notifications.HasPending()) kick(); sema.WaitForEmpty(); }
	}
	if (notifications.HasPending()) kick();
	sema.WaitForEmpty();
	if (consumed.load(std::memory_order_acquire) != credit.Written()) Fail("drain progress not published");
	stop.store(true, std::memory_order_release); kick(); consumer.join();
}

int main()
{
	using C = MTVURingCredit<64, 8>;
	C credit;
	if (!credit.HasSpace(55) || credit.HasSpace(56)) Fail("one-word gap and guard");
	credit.PublishTo(55);
	if (credit.HasSpace(1)) Fail("full queue");
	credit.Refresh(40);
	if (!credit.HasSpace(40) || credit.HasSpace(41)) Fail("conservative credit");
	credit.PublishTo(0); // Wrap consumes the unused tail too.
	if (credit.Written() != 64 || credit.HasSpace(32)) Fail("wrap padding accounting");
	if (C::Advance(~std::uint64_t{0} - 3, 4) != 4) Fail("sequence overflow");
	RunCredit<64, 8, 7>();
	RunCredit<128, 8, 31>();
	RunCredit<4096, 64, 1024>();
	std::puts("PASS: ring credit, 300000 variable packets, wrap/drain/backpressure");
}
