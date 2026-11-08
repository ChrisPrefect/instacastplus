#!/usr/bin/env python3
"""Summarize measured app-process CPU/physical footprint by E2E workload phase."""
import argparse
from collections import defaultdict
from datetime import datetime
import json
from pathlib import Path
import statistics

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('runs',nargs='+',type=Path)
p.add_argument('--output',required=True,type=Path)
args=p.parse_args()


def read_lines(path):
    if not path.exists():return []
    result=[]
    for line in path.read_text().splitlines():
        try:result.append(json.loads(line))
        except json.JSONDecodeError:pass
    return result


def percentile(values,fraction):
    if not values:return None
    values=sorted(values);return values[min(len(values)-1,int((len(values)-1)*fraction))]


results=[]
for run in args.runs:
    environment=json.loads((run/'environment.json').read_text())
    start=datetime.fromisoformat(environment['started']).timestamp()
    samples=[s for s in read_lines(run/'telemetry.jsonl') if s['timestamp']>=start]
    phases=defaultdict(lambda:dict(samples=[],intervals=[]))
    for sample in samples:phases[sample['state'].get('phase','unknown')]['samples'].append(sample)
    for before,after in zip(samples,samples[1:]):
        name=before['state'].get('phase','unknown')
        duration=after['timestamp']-before['timestamp'];cpu=after['cpuSeconds']-before['cpuSeconds']
        if duration>0 and cpu>=0 and after['state'].get('phase')==name:
            phases[name]['intervals'].append(dict(seconds=duration,cpuSeconds=cpu,percent=cpu/duration*100))
    summaries={}
    for name,data in phases.items():
        points=data['samples'];intervals=data['intervals']
        elapsed=sum(s['seconds'] for s in intervals);cpu=sum(s['cpuSeconds'] for s in intervals)
        summaries[name]=dict(samples=len(points),observedSeconds=round(elapsed,2),cpuSeconds=round(cpu,3),
            meanCPUPercentOfOneCore=round(cpu/elapsed*100,2) if elapsed else None,
            p95IntervalCPUPercentOfOneCore=round(percentile([s['percent'] for s in intervals],.95),2) if intervals else None,
            peakFootprintMiB=round(max(s['footprintBytes'] for s in points)/1048576,2),
            medianFootprintMiB=round(statistics.median(s['footprintBytes'] for s in points)/1048576,2),
            firstFootprintMiB=round(points[0]['footprintBytes']/1048576,2),lastFootprintMiB=round(points[-1]['footprintBytes']/1048576,2),
            peakResidentMiB=round(max(s['residentBytes'] for s in points)/1048576,2),
            maximumMainHeartbeatGapSeconds=round(max(s['state']['heartbeatMaximumGapSeconds'] for s in points),3)
                if all('heartbeatMaximumGapSeconds' in s['state'] for s in points) else None,
            observedApplicationStates=sorted(set(s['state'].get('applicationState') for s in points)))
    rejects=[]
    for entry in read_lines(run/'Logs/Diagnostics.jsonl'):
        if entry.get('category') not in ['playback-transition','queue-transition']:continue
        try:timestamp=datetime.fromisoformat(entry['timestamp'].replace('Z','+00:00')).timestamp()
        except (ValueError,KeyError):continue
        if timestamp>=start:rejects.append(entry)
    result=dict(run=str(run),device=environment['device'],phases=summaries,
        peakFootprintMiB=round(max(s['footprintBytes'] for s in samples)/1048576,2) if samples else None,
        maximumCachedForegroundStateAgeSeconds=round(max(s['timestamp']-s['state']['timestamp'] for s in samples
            if s['state'].get('applicationState')==0 and 'timestamp' in s['state']),3)
            if any(s['state'].get('applicationState')==0 and 'timestamp' in s['state'] for s in samples) else None,
        unexpectedStateRejections=rejects,runResult=json.loads((run/'result.json').read_text()) if (run/'result.json').exists() else None,
        measurementScope=environment['instrumentation'],limits=environment['limits'])
    results.append(result)
    print(environment['device']['name'])
    for name,summary in summaries.items():
        print(f"  {name}: CPU {summary['meanCPUPercentOfOneCore']}%, footprint peak {summary['peakFootprintMiB']} MiB, main heartbeat gap {summary['maximumMainHeartbeatGapSeconds']} s")
    print('  State rejections:',len(rejects))
args.output.parent.mkdir(parents=True,exist_ok=True)
args.output.write_text(json.dumps(dict(runs=results,units='CPU percent of one core; memory MiB. RSS includes shared/mapped simulator pages; physical footprint is reported separately.'),ensure_ascii=False,indent=2)+'\n')
