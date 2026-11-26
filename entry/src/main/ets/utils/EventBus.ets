/** 极简事件总线：跨页面通知（例如来源变更后首页刷新） */
type Listener = () => void;

export class EventBus {
  private static listeners: Map<string, Listener[]> = new Map<string, Listener[]>();

  static on(key: string, listener: Listener): void {
    const list: Listener[] | undefined = EventBus.listeners.get(key);
    if (list === undefined) {
      EventBus.listeners.set(key, [listener]);
      return;
    }
    list.push(listener);
  }

  static off(key: string, listener: Listener): void {
    const list: Listener[] | undefined = EventBus.listeners.get(key);
    if (list === undefined) {
      return;
    }
    const next: Listener[] = [];
    for (const item of list) {
      if (item !== listener) {
        next.push(item);
      }
    }
    EventBus.listeners.set(key, next);
  }

  static emit(key: string): void {
    const list: Listener[] | undefined = EventBus.listeners.get(key);
    if (list === undefined) {
      return;
    }
    for (const listener of list) {
      listener();
    }
  }
}

export class BusKeys {
  static readonly SOURCES_CHANGED: string = 'sources_changed';
  static readonly SETTINGS_CHANGED: string = 'settings_changed';
  static readonly CACHE_CHANGED: string = 'cache_changed';
}
