#!/usr/bin/env python3
"""Build once, run isolated release benchmarks repeatedly, retain raw results and provenance."""
import argparse, datetime, hashlib, json, os, pathlib, platform, statistics, subprocess, tarfile

ROOT = pathlib.Path(__file__).resolve().parent.parent

def command(args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, text=True, capture_output=True, **kwargs).stdout.strip()

def source_files():
    return [p for p in sorted([ROOT / 'Package.swift', *ROOT.glob('Sources/**/*'),
                              *ROOT.glob('Tests/**/*'), *ROOT.glob('scripts/*')])
            if p.is_file() and '__pycache__' not in p.parts]

def fingerprint():
    digest = hashlib.sha256()
    for path in source_files():
        digest.update(str(path.relative_to(ROOT)).encode()); digest.update(path.read_bytes())
    return digest.hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label', required=True)
    parser.add_argument('--output', required=True, type=pathlib.Path)
    parser.add_argument('--repeats', type=int, default=5)
    parser.add_argument('--compare', type=pathlib.Path)
    parser.add_argument('--suite', choices=['components', 'git', 'scheduling'], default='components')
    args = parser.parse_args()
    if args.repeats < 3: parser.error('Use at least three repetitions')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    suite = {'components': 'PerformanceBenchmarkTests', 'git': 'ProbePerformanceTests', 'scheduling': 'SchedulingPerformanceTests'}[args.suite]
    flag = {'components': 'REPOBOT_BENCHMARK', 'git': 'REPOBOT_PROBE_BENCHMARK', 'scheduling': 'REPOBOT_SCHEDULING_BENCHMARK'}[args.suite]
    metadata = {'label': args.label, 'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'git_head': command(['git', 'rev-parse', 'HEAD']), 'source_sha256': fingerprint(),
                'platform': platform.platform(), 'cpu': command(['sysctl', '-n', 'machdep.cpu.brand_string']),
                'workload_version': {'components': 1, 'git': 100, 'scheduling': 101}[args.suite], 'copies': 12 if args.suite == 'git' else 720, 'repeats': args.repeats,
                'measurement': 'getrusage user+system CPU; Git suite includes RUSAGE_CHILDREN; wall clock; setup excluded'}
    previous = json.loads(args.compare.read_text()) if args.compare else None
    if previous:
        for key in ['workload_version', 'copies', 'cpu', 'platform']:
            if previous['metadata'][key] != metadata[key]:
                parser.error(f'Comparison differs in {key}; use matching workloads and host')
    archive = args.output.with_suffix('.sources.tar.gz')
    with tarfile.open(archive, 'w:gz') as saved:
        for path in source_files(): saved.add(path, arcname=path.relative_to(ROOT))
    metadata['source_archive'] = archive.name
    print('Building release benchmark…', flush=True)
    build = subprocess.run(['./scripts/swift.sh', 'test', '-c', 'release', '--filter', suite], cwd=ROOT,
                           env={**os.environ, flag: '0'},
                           text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    args.output.with_suffix('.build.log').write_text(build.stdout)
    build.check_returncode()
    binary_dir = command(['./scripts/swift.sh', 'build', '-c', 'release', '--show-bin-path'])
    versions = list(pathlib.Path(binary_dir).glob('swift-version*.txt'))
    metadata['compiler_version'] = versions[0].read_text().strip() if versions else 'not recorded'
    binaries = list(pathlib.Path(binary_dir).glob('*.xctest/Contents/MacOS/*'))
    metadata['binaries_sha256'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in binaries if p.is_file()}
    metadata['command'] = ['./scripts/swift.sh', 'test', '-c', 'release', '--skip-build', '--filter', suite]
    results = []
    for iteration in range(args.repeats):
        run = subprocess.run(metadata['command'], cwd=ROOT, env={**os.environ, flag: '1'},
                             text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        args.output.with_suffix(f'.run-{iteration + 1}.log').write_text(run.stdout)
        run.check_returncode()
        values = [json.loads(line.split('REPOBOT_BENCHMARK ', 1)[1]) for line in run.stdout.splitlines()
                  if 'REPOBOT_BENCHMARK ' in line]
        expected = {'components': 5, 'git': 2, 'scheduling': 4}[args.suite]
        if len(values) != expected: raise RuntimeError(f'Expected {expected} workloads; saw {len(values)}')
        results.append(values)
        print(f'Completed repetition {iteration + 1}/{args.repeats}', flush=True)
    summary = {}
    for workload in results[0]:
        name = workload['workload']
        samples = [next(r for r in run if r['workload'] == name) for run in results]
        summary[name] = {}
        for metric in ['cpu_ms_per_op', 'wall_ms_per_op']:
            values = [r[metric] for r in samples]; median = statistics.median(values)
            summary[name][metric] = {'median': median, 'min': min(values), 'max': max(values),
                'mad': statistics.median(abs(v - median) for v in values)}
        summary[name]['counters'] = [s['counters'] for s in samples]
    if fingerprint() != metadata['source_sha256']:
        raise RuntimeError('Sources changed during the benchmark; discard this run and repeat')
    document = {'metadata': metadata, 'runs': results, 'summary': summary}
    args.output.write_text(json.dumps(document, indent=2) + '\n')
    print('\nWorkload                         median CPU ms/op    range         change')
    for name, result in summary.items():
        cpu = result['cpu_ms_per_op']; change = ''
        if previous:
            before = previous['summary'][name]['cpu_ms_per_op']['median']
            change = f'{(cpu["median"] / before - 1) * 100:+.1f}%'
        print(f'{name:32} {cpu["median"]:9.4f}       {cpu["min"]:.4f}–{cpu["max"]:.4f}   {change}')
    print(f'Raw results: {args.output}')

if __name__ == '__main__':
    main()
