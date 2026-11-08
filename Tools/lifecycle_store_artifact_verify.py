#!/usr/bin/env python3
"""Retain and verify the actual persisted store at the end of a simulator E2E.

Reads a consistent SQLite snapshot, including its WAL, after stopping the app.
This complements native UI/production-API evidence with canonical saved data.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import shlex
import sqlite3
import subprocess
import sys

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--udid',required=True)
p.add_argument('--evidence',required=True,type=Path)
args=p.parse_args();out=args.evidence.resolve();out.mkdir(parents=True,exist_ok=True)
bundle='com.iteconomy.instacastplus'


def sim(*command,check=True):
    result=subprocess.run(['xcrun','simctl',*command],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    with (out/'commands.log').open('a') as log:log.write(shlex.join(['xcrun','simctl',*command])+'\n'+result.stdout)
    if check and result.returncode:raise RuntimeError(result.stdout)
    return result.stdout.strip()


device=next(d for group in json.loads(sim('list','devices','-j'))['devices'].values() for d in group if d['udid']==args.udid)
assert device['name'].startswith('Instacast Stress ') and device['state']=='Booted'
sim('terminate',args.udid,bundle,check=False)
container=Path(sim('get_app_container',args.udid,bundle,'data'))
app=Path(sim('get_app_container',args.udid,bundle,'app'))
source=container/'Documents/Data/DataStore6.sqlite';snapshot=out/'DataStore6.sqlite'
assert source.exists() and not snapshot.exists()
reader=sqlite3.connect(source.as_uri()+'?mode=ro',uri=True)
db=sqlite3.connect(snapshot);reader.backup(db);reader.close();db.row_factory=sqlite3.Row
quick_check=db.execute('PRAGMA quick_check').fetchone()[0]
feeds={row['ZSOURCEURL_']:dict(row) for row in db.execute('SELECT ZSOURCEURL_,ZRANK,ZSUBSCRIBED FROM ZFEED WHERE ZSOURCEURL_ IS NOT NULL')}
outbox=list(db.execute('SELECT * FROM ZICCLOUDSYNCOUTBOXENTRY'))
by_key={(row['ZACCOUNTRECORDNAME'],row['ZRECORDNAME']):row for row in outbox}
mismatches=[];verified=0
for row in outbox:
    if row['ZCATEGORY']!='subscription' or row['ZOPERATION']!='save' or not row['ZRECORDNAME'].startswith('subscription_'):continue
    payload=plistlib.loads(row['ZPAYLOADDATA']);url=payload.get('feedURL');feed=feeds.get(url)
    pair=by_key.get((row['ZACCOUNTRECORDNAME'],'subscriptionTombstone_'+hashlib.sha256(url.encode()).hexdigest())) if url else None
    reasons=[]
    if not feed or not feed['ZSUBSCRIBED']:reasons.append('active intent has no subscribed feed')
    if feed and payload.get('rank')!=feed['ZRANK']:reasons.append('payload rank differs from saved feed rank')
    if not isinstance(payload.get('properties'),list):reasons.append('missing properties array')
    if not pair or pair['ZOPERATION']!='delete' or pair['ZREVISION']!=row['ZREVISION'] or pair['ZCHANGEDAT']!=row['ZCHANGEDAT']:reasons.append('paired intent is incomplete or has another revision/date')
    if reasons:mismatches.append(dict(recordName=row['ZRECORDNAME'],feedURL=url,reasons=reasons))
    else:verified+=1
episode_count=db.execute('SELECT COUNT(*) FROM ZEPISODE').fetchone()[0];db.close()
info=plistlib.loads((app/'Info.plist').read_bytes())
result=dict(passed=quick_check=='ok' and not mismatches,command=shlex.join([sys.executable,*sys.argv]),
    finished=datetime.now(timezone.utc).isoformat(),device=device,appVersion=info['CFBundleShortVersionString'],build=info['CFBundleVersion'],
    binarySHA256=hashlib.sha256((app/'InstacastPlus').read_bytes()).hexdigest(),snapshotSHA256=hashlib.sha256(snapshot.read_bytes()).hexdigest(),
    quickCheck=quick_check,feedCount=len(feeds),episodeCount=episode_count,outboxRows=len(outbox),verifiedPairedSubscriptionIntents=verified,
    accounts=dict(Counter(row['ZACCOUNTRECORDNAME'] for row in outbox)),mismatches=mismatches,
    contract='Actual durable subscription payload rank matches its saved feed; active save and paired tombstone delete share revision and causal date. Empty properties arrays are valid. No authenticated CloudKit service claim.')
(out/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:result[k] for k in ['passed','feedCount','episodeCount','outboxRows','verifiedPairedSubscriptionIntents','mismatches']},ensure_ascii=False))
if not result['passed']:raise SystemExit(1)
