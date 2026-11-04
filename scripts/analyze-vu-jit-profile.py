#!/usr/bin/env python3
"""Join timestamped Hps2 OHOS JIT maps with raw Hiperf samples (standard library only)."""
import argparse
import collections
import json
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--maps', type=Path, required=True)
    parser.add_argument('--dump', type=Path, required=True)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--tid', type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--group', choices=('EE', 'IOP', 'VU0', 'VU1', 'VIF'), default='VU1',
                        help='JIT map group to attribute; defaults to VU1 for existing captures')
    parser.add_argument('--bank-base', type=lambda value: int(value, 0),
                        help='Known cache base, if its dispatcher registration was not captured')
    parser.add_argument('--bank-size', type=lambda value: int(value, 0),
                        help='Override cache size: defaults to 16 MiB for VIF, 32 MiB for IOP, otherwise 64 MiB')
    args = parser.parse_args()
    if args.bank_size is None:
        args.bank_size = 0x1000000 if args.group == 'VIF' else (0x2000000 if args.group == 'IOP' else 0x4000000)
    if args.bank_size <= 0:
        parser.error('--bank-size must be positive')
    maps = []
    for line in args.maps.read_text(errors='replace').splitlines():
        fields = line.split()
        if len(fields) < 4 or not fields[2].isdigit() or int(fields[2]) != args.pid:
            continue
        match = re.search(r'MAP ns=(\d+) addr=([0-9a-f]+) size=(\d+) name=(.+)', line)
        prefix = 'VIF_' if args.group == 'VIF' else args.group
        if not match or not match[4].startswith(prefix):
            continue
        ns, address, size = int(match[1]), int(match[2], 16), int(match[3])
        if not 0 < size <= args.bank_size:
            raise ValueError('Invalid JIT range size')
        maps.append(dict(ns=ns, address=address, end=address + size, size=size, name=match[4]))
    if not maps:
        raise ValueError(f'No {args.group} maps for selected process')
    base = args.bank_base if args.bank_base is not None else min(row['address'] for row in maps)
    pages = collections.defaultdict(list)
    for row in sorted(maps, key=lambda row: row['ns']):
        for page in range(row['address'] >> 12, ((row['end'] - 1) >> 12) + 1):
            pages[page].append(row)

    # Retain raw guest-block labels. A block may have several disjoint segments.
    # The newest covering registration wins if a code-cache address was reused.
    blocks = collections.Counter()
    pcs = collections.Counter()
    unknown = collections.Counter()
    total = bank_total = matched = samples = 0
    for record in args.dump.read_text(errors='replace').split('record sample:')[1:]:
        ids = re.search(r'pid (\d+), tid (\d+)', record)
        if not ids or (int(ids[1]), int(ids[2])) != (args.pid, args.tid):
            continue
        period = re.search(r'\bperiod (\d+)', record)
        timestamp = re.search(r'\btime (\d+)', record)
        chain = re.search(r'callchain nr=\d+\n((?:\s+0x[^\n]+\n)+)', record)
        if not period or not timestamp or not chain:
            raise ValueError('Incomplete Hiperf sample')
        addresses = [int(v, 16) for v in re.findall(r'0x([a-fA-F0-9]+)', chain[1])]
        addresses = [value for value in addresses if value < 0xffff000000000000]
        if not addresses:
            raise ValueError('No user leaf PC')
        ip, weight, ns = addresses[0], int(period[1]), int(timestamp[1])
        total += weight
        samples += 1
        if not base <= ip < base + args.bank_size:
            continue
        bank_total += weight
        candidates = [row for row in pages[ip >> 12]
                      if row['ns'] <= ns and row['address'] <= ip < row['end']]
        if not candidates:
            unknown[ip] += weight
            continue
        row = max(candidates, key=lambda row: row['ns'])
        name = re.sub(r'_s\d+$', '', row['name'])
        matched += weight
        blocks[name] += weight
        pcs[(name, ip)] += weight
    if not total or not bank_total:
        raise ValueError(f'No {args.group} code-cache samples in selected thread')

    # For this short run, detect address reuse and overlapping emitted segments
    # explicitly instead of hiding ambiguous program-entry envelopes.
    ranges = sorted({(r['address'], r['end'], r['name']) for r in maps})
    furthest_end = 0
    overlaps = 0
    for start, end, name in ranges:
        overlaps += start < furthest_end
        furthest_end = max(furthest_end, end)
    result = dict(pid=args.pid, tid=args.tid, group=args.group, sample_count=samples, map_records=len(maps),
                  code_bank_base=hex(base), thread_cycles=total, code_bank_cycles=bank_total,
                  mapped_cycles=matched, coverage_percent=100 * matched / bank_total,
                  historical_overlapping_ranges=overlaps,
                  blocks=[dict(name=name, cycles=count, thread_percent=100 * count / total,
                               mapped_percent=100 * count / matched)
                          for name, count in blocks.most_common()],
                  hot_pcs=[dict(name=name, ip=hex(ip), cycles=count)
                           for (name, ip), count in pcs.most_common(30)],
                  unknown_pcs=[dict(ip=hex(ip), cycles=count)
                               for ip, count in unknown.most_common(20)])
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(f"{args.group} mapping coverage: {result['coverage_percent']:.2f}% of bank cycles; "
          f"{len(maps)} map records; historical overlaps={overlaps}")
    for row in result['blocks'][:8]:
        print(f"{row['thread_percent']:.2f}% thread cycles {row['name']}")


if __name__ == '__main__':
    main()
