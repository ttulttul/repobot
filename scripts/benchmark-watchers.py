#!/usr/bin/env python3
"""Measure production remote-watcher preparation and routing without installing watches."""
import argparse, hashlib, importlib.util, json, os, pathlib, platform, resource, statistics, subprocess, tempfile, time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--label', required=True)
args = parser.parse_args()
source = pathlib.Path(__file__).resolve().parent.parent / 'Sources/RepobotCore/Resources/watcher.py'
spec = importlib.util.spec_from_file_location('watcher', source)
watcher = importlib.util.module_from_spec(spec); spec.loader.exec_module(watcher)
def cpu():
    own = resource.getrusage(resource.RUSAGE_SELF); child = resource.getrusage(resource.RUSAGE_CHILDREN)
    return own.ru_utime + own.ru_stime + child.ru_utime + child.ru_stime
real_run = subprocess.run
calls = 0
def counted(*a, **kw):
    global calls
    calls += 1
    return real_run(*a, **kw)
git = '/Library/Developer/CommandLineTools/usr/bin/git'
if not os.path.exists(git): git = '/usr/bin/git'
# The production helper locates git through PATH; exclude setup from measurements.
os.environ['PATH'] = str(pathlib.Path(git).parent) + ':' + os.environ.get('PATH', '')
runs = []
with tempfile.TemporaryDirectory(prefix='repobot-watcher-benchmark-') as temporary:
    root = pathlib.Path(temporary).resolve(); repos = []
    for i in range(12):
        repo = root / f'repo-{i}'; repo.mkdir()
        real_run([git, '-C', str(repo), 'init', '-q'], check=True)
        repos.append(str(repo))
    watcher.known_git_directories = {r: [str(pathlib.Path(r) / '.git')] for r in repos}
    owners = {f'/repos/{i}': {f'/repos/{i}'} for i in range(720)}
    owners.update({f'/repos/{i}/.git': {f'/repos/{i}'} for i in range(720)})
    for r in repos: watcher.git_directories(r)
    for repetition in range(5):
        watcher.subprocess.run = counted
        before = calls; start = cpu(); wall = time.monotonic()
        for _ in range(5):
            for r in repos: assert watcher.git_directories(r) == [str(pathlib.Path(r) / '.git')]
        runs.append({'workload': 'watcher_git_directories', 'repetition': repetition,
                     'cpu_ms_per_op': (cpu() - start) * 1000 / 5,
                     'wall_ms_per_op': (time.monotonic() - wall) * 1000 / 5, 'git_invocations': calls - before})
        start = cpu(); wall = time.monotonic()
        for i in range(10000):
            path = f'/repos/{i % 720}/src/changed.swift'
            assert watcher.matching_repositories(owners, path) == {f'/repos/{i % 720}'}
        runs.append({'workload': 'remote_event_routing', 'repetition': repetition,
                     'cpu_ms_per_op': (cpu() - start) * 1000 / 10000,
                     'wall_ms_per_op': (time.monotonic() - wall) * 1000 / 10000})
watcher.subprocess.run = real_run
summary = {name: statistics.median(r['cpu_ms_per_op'] for r in runs if r['workload'] == name)
           for name in {r['workload'] for r in runs}}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps({'label': args.label, 'platform': platform.platform(), 'workload_version': 1,
    'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'runs': runs, 'median_cpu_ms': summary}, indent=2) + '\n')
print(json.dumps(summary, indent=2)); print(args.output)
