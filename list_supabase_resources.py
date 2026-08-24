import re, urllib.request
from pathlib import Path

text = Path('.env').read_text()
url = re.search(r"SUPABASE_URL='([^']+)'", text).group(1)
key = re.search(r"SUPABASE_ANON_KEY='([^']+)'", text).group(1)
headers = {'apikey': key, 'Authorization': f'Bearer {key}', 'Accept': 'application/json'}
root = url.rstrip('/') + '/rest/v1/'
req = urllib.request.Request(root, headers=headers)
with urllib.request.urlopen(req, timeout=20) as resp:
    print('STATUS', resp.status)
    print(resp.read(20000).decode('utf-8'))
