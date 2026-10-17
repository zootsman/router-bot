"""Хранилище SSH-хостов."""
import json
import os
from datetime import datetime

DATA_DIR = '/opt/router_bot/data/ssh_control'
HOSTS_FILE = os.path.join(DATA_DIR, 'hosts.json')


def _ensure_dir():
    os.makedirs(DATA_DIR, exist_ok=True)


def load_hosts() -> dict:
    _ensure_dir()
    if not os.path.exists(HOSTS_FILE):
        return {}
    try:
        with open(HOSTS_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_hosts(hosts: dict):
    _ensure_dir()
    tmp = HOSTS_FILE + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(hosts, f, ensure_ascii=False, indent=2)
    os.replace(tmp, HOSTS_FILE)


def host_id(ip: str, port: int) -> str:
    return f'{ip}:{port}'


def add_host(ip, port, user, password, fingerprint, key_type) -> str:
    hosts = load_hosts()
    hid = host_id(ip, port)
    hosts[hid] = {
        'ip': ip,
        'port': int(port),
        'user': user,
        'password': password,
        'fingerprint': fingerprint,
        'key_type': key_type,
        'added': datetime.now().isoformat(timespec='seconds'),
    }
    save_hosts(hosts)
    return hid


def remove_host(hid: str) -> bool:
    hosts = load_hosts()
    if hid in hosts:
        del hosts[hid]
        save_hosts(hosts)
        return True
    return False


def get_host(hid: str):
    return load_hosts().get(hid)