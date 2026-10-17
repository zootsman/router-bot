"""Чтение config.env в окружение."""
import os

CONFIG_PATH = '/opt/router_bot/config.env'

def load_config():
    if not os.path.exists(CONFIG_PATH):
        return
    with open(CONFIG_PATH) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            v = v.strip().strip('"').strip("'")
            os.environ.setdefault(k.strip(), v)

def get(key: str, default: str = '') -> str:
    return os.environ.get(key, default)