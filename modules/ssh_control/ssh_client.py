"""SSH-клиент через OpenSSH (ssh, ssh-keygen). Без paramiko."""
import asyncio
import logging
import os
import re
import subprocess
import tempfile

log = logging.getLogger(__name__)

SSH = '/opt/bin/ssh'
SSH_KEYGEN = '/opt/bin/ssh-keygen'


def _run_sync(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return p.stdout, p.stderr, p.returncode
    except Exception:
        return '', '', -1
async def _run(cmd, env=None, timeout=30):
    log.info('ssh_run: %s', ' '.join(cmd[:8]))
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=env,
        start_new_session=True,
    )
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        log.warning('ssh_run TIMEOUT %sс, kill...', timeout)
        try:
            proc.kill()
        except Exception as e:
            log.warning('kill failed: %s', e)
        try:
            await asyncio.wait_for(proc.wait(), timeout=2)
        except asyncio.TimeoutError:
            log.warning('kill did not work, SIGKILL')
            import signal as _sig
            try:
                os.killpg(os.getpgid(proc.pid), _sig.SIGKILL)
            except Exception as e:
                log.warning('killpg failed: %s', e)
            try:
                await asyncio.wait_for(proc.wait(), timeout=2)
            except Exception:
                pass
        except Exception:
            pass
        raise TimeoutError(f'Таймаут {timeout}с')
    out_s = out.decode('utf-8', errors='replace')
    err_s = err.decode('utf-8', errors='replace')
    log.info('ssh_run: rc=%s out=%dB err=%dB', proc.returncode,
             len(out_s), len(err_s))
    if err_s.strip():
        log.info('ssh_run stderr: %s', err_s.strip()[:300])
    return out_s, err_s, proc.returncode




def _parse_known_hosts(path):
    """Возвращает (fingerprint_sha256, key_type)."""
    if not os.path.exists(path):
        return None, None
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split()
            if len(parts) < 3:
                continue
            key_type, b64 = parts[1], parts[2]
            with tempfile.NamedTemporaryFile('w', suffix='.pub', delete=False) as kf:
                kf.write(f'{key_type} {b64}\n')
                key_file = kf.name
            try:
                out, err, rc = _run_sync([SSH_KEYGEN, '-lf', key_file, '-E', 'sha256'])
                if out:
                    m = re.search(r'(SHA256:[A-Za-z0-9+/=]+)', out)
                    if m:
                        return m.group(1), key_type
            finally:
                try:
                    os.unlink(key_file)
                except Exception:
                    pass
    return None, None


_last_probe_error = ''

def get_last_probe_error() -> str:
    return _last_probe_error
async def probe_fingerprint(host, port=22, timeout=10):
    """Подключается, заставляет ssh записать host key, парсит fingerprint."""
    global _last_probe_error
    _last_probe_error = ''

    with tempfile.TemporaryDirectory() as tmp:
        kh = os.path.join(tmp, 'known_hosts')
        open(kh, 'w').close()

        env = os.environ.copy()
        env['SSH_ASKPASS'] = '/bin/true'
        env['SSH_ASKPASS_REQUIRE'] = 'force'
        env['DISPLAY'] = ':0'

        try:
            out, err, rc = await _run(
                [
                    SSH,
                    '-o', 'StrictHostKeyChecking=accept-new',
                    '-o', f'UserKnownHostsFile={kh}',
                    '-o', 'ConnectTimeout=5',
                    '-o', 'NumberOfPasswordPrompts=0',
                    '-o', 'BatchMode=yes',
                    '-o', 'PreferredAuthentications=none',
                    '-p', str(port),
                    f'probe@{host}',
                    'true',
                ],
                env=env,
                timeout=timeout,
            )
        except TimeoutError:
            _last_probe_error = f'Таймаут {timeout}с — хост не отвечает'
            log.warning('probe timeout %s:%s', host, port)
            return None
        except Exception as e:
            _last_probe_error = f'{type(e).__name__}: {e}'
            log.warning('probe error: %s', e)
            return None

        fp, kt = _parse_known_hosts(kh)
        if not fp:
            err_clean = (err or '').strip()
            low = err_clean.lower()
            if 'connection refused' in low:
                _last_probe_error = f'Соединение отклонено (порт {port} закрыт?)'
            elif 'no route to host' in low:
                _last_probe_error = 'Нет маршрута до хоста'
            elif 'timed out' in low or 'timeout' in low:
                _last_probe_error = 'Хост недоступен (timeout)'
            elif 'connection reset' in low:
                _last_probe_error = 'Соединение сброшено'
            elif 'permission denied' in low:
                _last_probe_error = 'Permission denied'
            elif err_clean:
                _last_probe_error = err_clean[:400]
            else:
                _last_probe_error = f'ssh rc={rc} без stderr (порт {port})'
            log.warning('probe FAIL %s:%s rc=%s err=%s',
                        host, port, rc, err_clean[:200])
            return None
        return {'fingerprint': fp, 'key_type': kt}




async def run_command(host, port, user, password, command,
                      expected_fp, timeout=60):
    """Выполняет команду. Возвращает (stdout, stderr, exit_code)."""
    with tempfile.TemporaryDirectory() as tmp:
        kh = os.path.join(tmp, 'known_hosts')
        askpass = os.path.join(tmp, 'askpass.sh')
        with open(askpass, 'w') as f:
            f.write('#!/bin/sh\nprintf \'%s\\n\' "$SSH_PASS"\n')
        os.chmod(askpass, 0o700)

        probe = await probe_fingerprint(host, port, timeout=10)
        if not probe:
            raise ConnectionError(f'Не удалось получить SSH host key от {host}:{port}')
        if expected_fp and probe['fingerprint'] != expected_fp:
            raise ConnectionError(
                f'⚠️ Fingerprint изменился!\n'
                f'Ожидали: {expected_fp}\n'
                f'Получили: {probe["fingerprint"]}'
            )

        env = os.environ.copy()
        env['SSH_PASS'] = password
        env['SSH_ASKPASS'] = askpass
        env['SSH_ASKPASS_REQUIRE'] = 'force'
        env['DISPLAY'] = ':0'

        out, err, rc = await _run(
            [
                SSH,
                '-o', 'StrictHostKeyChecking=accept-new',
                '-o', f'UserKnownHostsFile={kh}',
                '-o', 'NumberOfPasswordPrompts=1',
                '-o', 'ConnectTimeout=10',
                '-o', 'BatchMode=no',
                '-o', 'ServerAliveInterval=5',
                '-o', 'ServerAliveCountMax=2',
                '-p', str(port),
                f'{user}@{host}',
                command,
            ],
            env=env,
            timeout=timeout,
        )

        if rc != 0 and not out:
            low = (err or '').lower()
            if 'permission denied' in low or 'authentication failed' in low:
                raise PermissionError('Неверный логин или пароль')
            if 'connection refused' in low:
                raise ConnectionError('Соединение отклонено (порт закрыт?)')
            if 'no route to host' in low or 'timed out' in low or 'timeout' in low:
                raise ConnectionError('Хост недоступен')
            if 'host key verification failed' in low:
                raise ConnectionError('Не удалось проверить host key')

        return out, err, rc


# ==================== Interactive ====================

QUESTION_PATTERNS = [
    b'(y/n)', b'[y/n]', b'[Y/n]', b'[y/N]',
    b'(yes/no)', b'[yes/no]',
    b'Password:', b'password:',
    b'Are you sure', b'are you sure',
    b'Continue', b'continue?',
    b'Proceed', b'proceed?',
    b'Do you want',
]


def detect_question(buf: bytes):
    """Возвращает True если в буфере похоже на вопрос."""
    low = buf.lower()
    for p in QUESTION_PATTERNS:
        if p.lower() in low:
            return True
    return False


class InteractiveSSH:
    """Долгоживущая SSH-сессия с управлением stdin."""

    def __init__(self, host, port, user, password, command,
                 expected_fp, timeout=300):
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.command = command
        self.expected_fp = expected_fp
        self.timeout = timeout
        self.proc = None
        self.buffer = b''
        self._read_task = None
        self._on_data = None      # async callable(bytes)
        self._closed = False

    async def start(self, on_data):
        """Запускает ssh -tt. on_data(chunk) вызывается на каждый чанк."""
        import shutil
        self._on_data = on_data

        probe = await probe_fingerprint(self.host, self.port, timeout=10)
        if not probe:
            raise ConnectionError(
                f'Не удалось получить SSH host key от {self.host}:{self.port}')
        if self.expected_fp and probe['fingerprint'] != self.expected_fp:
            raise ConnectionError(
                f'⚠️ Fingerprint изменился! '
                f'Ожидали {self.expected_fp}, получили {probe["fingerprint"]}'
            )

        # ВАЖНО: директория живёт до конца сессии
        self._tmpdir = tempfile.mkdtemp(prefix='ssh_ctrl_')
        kh = os.path.join(self._tmpdir, 'known_hosts')
        askpass = os.path.join(self._tmpdir, 'askpass.sh')
        open(kh, 'w').close()
        with open(askpass, 'w') as f:
            f.write('#!/bin/sh\nprintf \'%s\\n\' "$SSH_PASS"\n')
        os.chmod(askpass, 0o700)

        env = os.environ.copy()
        env['SSH_PASS'] = self.password
        env['SSH_ASKPASS'] = askpass
        env['SSH_ASKPASS_REQUIRE'] = 'force'
        env['DISPLAY'] = ':0'

        self.proc = await asyncio.create_subprocess_exec(
            SSH,
            '-tt',
            '-o', 'StrictHostKeyChecking=accept-new',
            '-o', f'UserKnownHostsFile={kh}',
            '-o', 'NumberOfPasswordPrompts=1',
            '-o', 'ConnectTimeout=10',
            '-o', 'BatchMode=no',
            '-o', 'ServerAliveInterval=10',
            '-o', 'ServerAliveCountMax=3',
            '-p', str(self.port),
            f'{self.user}@{self.host}',
            self.command,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )

        self._read_task = asyncio.create_task(self._read_loop())


    async def _read_loop(self):
        try:
            while True:
                chunk = await asyncio.wait_for(
                    self.proc.stdout.read(256), timeout=self.timeout,
                )
                if not chunk:
                    break
                self.buffer += chunk
                if self._on_data:
                    try:
                        await self._on_data(chunk)
                    except Exception as e:
                        log.warning('on_data error: %s', e)
        except asyncio.TimeoutError:
            log.warning('interactive session timeout')
        except Exception as e:
            log.warning('read_loop error: %s', e)
        finally:
            self._closed = True

    async def send(self, data: bytes):
        """Пишет в stdin сессии."""
        if self.proc and self.proc.stdin and not self.proc.stdin.is_closing():
            self.proc.stdin.write(data)
            try:
                await self.proc.stdin.drain()
            except Exception as e:
                log.warning('send drain error: %s', e)

    async def wait(self, timeout=300):
        try:
            rc = await asyncio.wait_for(self.proc.wait(), timeout=timeout)
        except asyncio.TimeoutError:
            self.kill()
            return -1
        if self._read_task:
            try:
                await self._read_task
            except Exception:
                pass
        self._cleanup_tmp()
        return rc

    def _cleanup_tmp(self):
        import shutil
        if getattr(self, '_tmpdir', None):
            try:
                shutil.rmtree(self._tmpdir, ignore_errors=True)
            except Exception:
                pass
            self._tmpdir = None

    def kill(self):
        if self.proc:
            try:
                self.proc.kill()
            except Exception:
                pass
        self._cleanup_tmp()

    def is_running(self):
        return self.proc and self.proc.returncode is None


async def run_script(host, port, user, password, script,
                     expected_fp, timeout=90, shell='sh -s', on_proc=None):
    """Выполняет многострочный скрипт через ssh, передавая его в stdin.

    Использует `sh -s` (или `bash -s`) на удалённой стороне —
    скрипт читается из stdin. Так можно отправлять блоки команд.
    """
    with tempfile.TemporaryDirectory() as tmp:
        kh = os.path.join(tmp, 'known_hosts')
        askpass = os.path.join(tmp, 'askpass.sh')
        with open(askpass, 'w') as f:
            f.write('#!/bin/sh\nprintf \'%s\\n\' "$SSH_PASS"\n')
        os.chmod(askpass, 0o700)

        probe = await probe_fingerprint(host, port, timeout=10)
        if not probe:
            raise ConnectionError(f'Не удалось получить SSH host key от {host}:{port}')
        if expected_fp and probe['fingerprint'] != expected_fp:
            raise ConnectionError(
                f'⚠️ Fingerprint изменился!\n'
                f'Ожидали: {expected_fp}\n'
                f'Получили: {probe["fingerprint"]}'
            )

        env = os.environ.copy()
        env['SSH_PASS'] = password
        env['SSH_ASKPASS'] = askpass
        env['SSH_ASKPASS_REQUIRE'] = 'force'
        env['DISPLAY'] = ':0'

        proc = await asyncio.create_subprocess_exec(
            SSH,
            '-o', 'StrictHostKeyChecking=accept-new',
            '-o', f'UserKnownHostsFile={kh}',
            '-o', 'NumberOfPasswordPrompts=1',
            '-o', 'ConnectTimeout=10',
            '-o', 'BatchMode=no',
            '-o', 'ServerAliveInterval=10',
            '-o', 'ServerAliveCountMax=3',
            '-p', str(port),
            f'{user}@{host}',
            shell,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
            start_new_session=True,
        )

        # отдаём ссылку на процесс наружу — для возможности отмены
        if on_proc:
            try:
                on_proc(proc)
            except Exception:
                pass

        # Передаём скрипт через communicate — оно само пишет в stdin
        # и корректно закрывает поток.
        try:
            out, err = await asyncio.wait_for(
                proc.communicate(input=script.encode('utf-8')),
                timeout=timeout,
            )
        except asyncio.TimeoutError:
            proc.kill()
            try:
                await proc.wait()
            except Exception:
                pass
            raise TimeoutError(f'Таймаут {timeout}с')

        out_s = out.decode('utf-8', errors='replace')
        err_s = err.decode('utf-8', errors='replace')
        rc = proc.returncode

        if rc != 0 and not out_s:
            low = err_s.lower()
            if 'permission denied' in low or 'authentication failed' in low:
                raise PermissionError('Неверный логин или пароль')
            if 'connection refused' in low:
                raise ConnectionError('Соединение отклонено')
            if 'no route to host' in low or 'timed out' in low:
                raise ConnectionError('Хост недоступен')

        return out_s, err_s, rc