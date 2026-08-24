import re, urllib.request, urllib.parse, urllib.error
from pathlib import Path

text = Path('.env').read_text()
url = re.search(r"SUPABASE_URL='([^']+)'", text).group(1)
key = re.search(r"SUPABASE_ANON_KEY='([^']+)'", text).group(1)
headers = {'apikey': key, 'Authorization': f'Bearer {key}', 'Accept': 'application/json'}
base = url.rstrip('/') + '/rest/v1/information_schema.columns'

names = ['ws_tblorganization','ws_tblinternalusers','ws_tblareas','ws_tblcustomers','ws_tbldeliveries','ws_tblpayments','ws_tblbottleinventory','vw_ws_customerbalance']
params = {
    'select': 'table_name,column_name,ordinal_position',
    'table_schema': 'public',
    'table_name': 'in.({})'.format(','.join(names))
}
path = base + '?' + urllib.parse.urlencode(params)
req = urllib.request.Request(path, headers=headers)
print('URL', path)
with urllib.request.urlopen(req, timeout=20) as resp:
    body = resp.read().decode('utf-8')
    print('STATUS', resp.status)
    print(body)
