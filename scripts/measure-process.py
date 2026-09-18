#!/usr/bin/env python3
"""Measure an existing process without controlling its UI or restarting it.

CPU percentages use one core as 100%, like Activity Monitor. Use long, matching
open/closed-map phases after startup; this includes all app threads, not children.
"""
import argparse, datetime, json, pathlib, platform, subprocess, time


def snapshot(pid):
    output = subprocess.check_output(['ps', '-p', str(pid), '-o', 'pid=', '-o', 'time=', '-o', 'lstart='], text=True)
    fields = output.split()
    if len(fields) < 3 or int(fields[0]) != pid:
        raise RuntimeError('Target process disappeared')
    value = fields[1]
    days = 0
    if '-' in value:
        day, value = value.split('-', 1); days = int(day)
    seconds = 0.0
    for part in value.split(':'): seconds = seconds * 60 + float(part)
    return seconds + days * 86400, ' '.join(fields[2:]), time.monotonic()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--phase', required=True, help='For example: map-open or map-closed')
    parser.add_argument('--seconds', type=float, default=900)
    parser.add_argument('--interval', type=float, default=5)
    parser.add_argument('--output', required=True, type=pathlib.Path)
    args = parser.parse_args()
    if args.seconds <= 0 or args.interval <= 0: parser.error('Durations must be positive')
    try:
        initial, launched, start = snapshot(args.pid)
    except (RuntimeError, subprocess.CalledProcessError):
        parser.error('Target process is not running; supply its current PID')
    data = {'pid': args.pid, 'phase': args.phase, 'process_started': launched,
            'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'platform': platform.platform(),
            'requested_seconds': args.seconds, 'cpu_scope': 'target process only; one core = 100%; ps time has 0.01s resolution',
            'samples': [], 'complete': False}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    def save():
        temporary = args.output.with_suffix(args.output.suffix + '.tmp')
        temporary.write_text(json.dumps(data, indent=2) + '\n'); temporary.replace(args.output)
    previous_cpu, previous_time = initial, start
    save()
    try:
        while time.monotonic() - start < args.seconds:
            time.sleep(min(args.interval, max(0, args.seconds - (time.monotonic() - start))))
            cpu, identity, wall = snapshot(args.pid)
            if identity != launched or cpu < previous_cpu: raise RuntimeError('Process restarted; start a separate measurement')
            data['samples'].append({'elapsed_seconds': wall - start, 'cpu_seconds': cpu - initial,
                                    'interval_cpu_percent': 100 * (cpu - previous_cpu) / (wall - previous_time)})
            data['average_cpu_percent'] = 100 * (cpu - initial) / (wall - start)
            previous_cpu, previous_time = cpu, wall
            save()
        data['complete'] = True
    except KeyboardInterrupt:
        data['error'] = 'Interrupted; partial measurement retained'
    except (RuntimeError, subprocess.CalledProcessError) as error:
        data['error'] = str(error)
        raise
    finally:
        save()
    print(f"{args.phase}: {data.get('average_cpu_percent', 0):.3f}% average CPU across {previous_time - start:.1f}s; {args.output}")


if __name__ == '__main__':
    main()
