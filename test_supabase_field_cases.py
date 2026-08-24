import re, urllib.request, urllib.parse, urllib.error
from pathlib import Path

text = Path('.env').read_text()
url = re.search(r"SUPABASE_URL='([^']+)'", text).group(1)
key = re.search(r"SUPABASE_ANON_KEY='([^']+)'", text).group(1)
headers = {'apikey': key, 'Authorization': f'Bearer {key}', 'Accept': 'application/json'}
base = url.rstrip('/') + '/rest/v1'

tables = [
    ('ws_tblOrganization', 'OrgID'),
    ('ws_tblInternalUsers', 'AuthUserID'),
    ('ws_tblAreas', 'AreaName'),
    ('ws_tblCustomers', 'CustomerID'),
    ('ws_tblDeliveries', 'DeliveryDate'),
    ('ws_tblPayments', 'PaymentDate'),
    ('ws_tblBottleInventory', 'SnapshotDate'),
    ('vw_ws_CustomerBalance', 'CustomerName'),
]

for table, col in tables:
    for name in [col, col.lower()]:
        path = base + '/' + table + '?select=' + urllib.parse.quote(name) + '&limit=1'
        req = urllib.request.Request(path, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                body = resp.read(2000).decode('utf-8')
                print(f'{table} select={name} STATUS={resp.status} BODY={body}')
        except urllib.error.HTTPError as e:
            print(f'{table} select={name} ERROR={e.code} {e.read(2000).decode("utf-8", "ignore")}')
        except Exception as e:
            print(f'{table} select={name} EXC={repr(e)}')
