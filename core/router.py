"""Реестр модулей и роутинг callback'ов по префиксу."""
import logging

log = logging.getLogger(__name__)

class ModuleRouter:
    def __init__(self):
        self._modules = {}
        self._order = []

    def register(self, module):
        if module.name in self._modules:
            log.warning('Module %s already registered, skip', module.name)
            return
        self._modules[module.name] = module
        self._order.append(module.name)
        log.info('Module registered: %s (%s)', module.name, module.title)

    def get(self, name):
        return self._modules.get(name)

    def all(self):
        return [self._modules[n] for n in self._order]

    def first(self):
        if not self._order:
            return None
        return self._modules[self._order[0]]

    async def dispatch_callback(self, update, ctx):
        """Callback с префиксом '<module>:...' идёт в модуль.
        Без префикса — в первый зарегистрированный (совместимость)."""
        q = update.callback_query
        data = q.data or ''

        if ':' in data:
            prefix, rest = data.split(':', 1)
            mod = self._modules.get(prefix)
            if mod:
                return await mod.handle_callback(rest, q, ctx)
            # неизвестный префикс — в первый
            mod = self.first()
            if mod:
                return await mod.handle_callback(data, q, ctx)
        else:
            mod = self.first()
            if mod:
                return await mod.handle_callback(data, q, ctx)