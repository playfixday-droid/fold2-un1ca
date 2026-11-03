#!/usr/bin/env python3
"""Сверяет TARGET_* SEC-флаги в config.sh с floating_feature.xml стока.
Использование: sec_features_from_stock.py floating_feature.xml config.sh [--write]"""
import re, sys
ff, cfg = sys.argv[1], sys.argv[2]
xml = open(ff, encoding='utf-8', errors='replace').read()
stock = dict(re.findall(r'<SEC_FLOATING_FEATURE_([A-Z0-9_]+)>(.*?)</SEC_FLOATING_FEATURE_\1>', xml, re.S))
lines = open(cfg).read().split('\n')
# нарочно не как в стоке: 120 Гц у Fold2 только у внутреннего (мёртвого) экрана, внешний - 60 Гц (см. config.sh)
KEEP = {'LCD_CONFIG_HFR_MODE', 'LCD_CONFIG_HFR_DEFAULT_REFRESH_RATE',
        'LCD_CONFIG_HFR_SUPPORTED_REFRESH_RATE', 'LCD_CONFIG_HFR_SUPPORTED_REFRESH_RATE_NS'}
out, changed = [], 0
for ln in lines:
    m = re.match(r'^TARGET_((?:AUDIO|BLUETOOTH|CAMERA|COMMON|DVFSAPP|FINGERPRINT|LCD|RIL|SECURITY|WLAN)_[A-Z0-9_]+)=(".*?"|\S+)(.*)$', ln)
    if m:
        key, val, rest = m.groups()
        quoted = val.startswith('"')
        if key not in stock:
            out.append(ln); continue  # нет во floating_feature -> SEC Product Feature, оставить
        if key in KEEP:
            print(f'{key}: {val} (в стоке "{stock[key].strip()}") - оставляю: внешний экран 60 Гц')
            out.append(ln); continue
        if '_SUPPORT_' in key and not quoted:
            new = 'true' if stock[key].strip().upper() == 'TRUE' else 'false'
        else:
            new = '"%s"' % stock[key].strip()
        if new != val:
            print(f'{key}: {val} -> {new}')
            changed += 1
        ln = f'TARGET_{key}={new}{rest}'  # комментарий в конце строки сохраняется
    out.append(ln)
print(f'изменений: {changed}, ключей в стоке: {len(stock)}')
if '--write' in sys.argv:
    open(cfg, 'w').write('\n'.join(out))
