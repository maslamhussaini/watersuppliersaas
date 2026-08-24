import re, urllib.request, urllib.parse, urllib.error
from pathlib import Path

text = Path('.env').read_text()
url = re.search(r"SUPABASE_URL='([^']+)'", text).group(1)
key = re.search(r"SUPABASE_ANON_KEY='([^']+)'", text).group(1)
headers = {'apikey': key, 'Authorization': f'Bearer {key}', 'Accept': 'application/json'}
base = url.rstrip('/') + '/rest/v1/information_schema.columns'
tables = ['ws_tblorganization','ws_tblinternalusers','ws_tblareas','ws_tblcustomers','ws_tbldeliveries','ws_tblpayments','ws_tblbottleinventory','vw_ws_customerbalance']

for t in tables:
    params = {
        'select': 'table_name,column_name,ordinal_position',
        'table_schema': 'eq.public',
        'table_name': f'eq.{t}'
    }
    path = base + '?' + urllib.parse.urlencode(params, safe='(),=')
    req = urllib.request.Request(path, headers=headers)
    print('\nTABLE', t)
    print('URL', path)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = resp.read().decode('utf-8')
            print('STATUS', resp.status)
            print(body)
    except urllib.error.HTTPError as e:
        print('ERROR', e.code)
        print(e.read(2000).decode('utf-8', 'ignore'))
    except Exception as e:
        print('EXC', repr(e))
