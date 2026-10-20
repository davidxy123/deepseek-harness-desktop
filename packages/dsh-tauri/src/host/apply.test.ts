import type { HostContext, IndexInjectRow } from './types'
import { createContext, runInContext } from 'node:vm'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { apply } from './apply'
import { MEDIA_RECORDER_SHIM_SCRIPT } from './media-recorder-shim'

afterEach(() => {
  vi.unstubAllEnvs()
})

function activate() {
  const listeners: ((table: IndexInjectRow[]) => void)[] = []
  const on = vi.fn((event: string, listener: (table: IndexInjectRow[]) => void) => {
    expect(event).toBe('webserver/index-inject')
    listeners.push(listener)
    return () => {
      const index = listeners.indexOf(listener)
      if (index >= 0) listeners.splice(index, 1)
    }
  })
  const ctx = {
    connection: { authorizeIndex: () => false },
    webServer: { register: () => () => {} },
    effect: (callback: () => unknown) => { callback() },
    on,
  } as unknown as HostContext
  apply(ctx)
  return { on, collect: (): IndexInjectRow[] => {
    const table: IndexInjectRow[] = []
    for (const listener of listeners) listener(table)
    return table
  } }
}

/** 在最小页面语境里执行注入脚本，取回 `globalThis.dshDesktop` 的落地值。 */
interface Marker {
  protocolVersion?: number
  deviceInfo?: () => Promise<string>
  updates?: unknown
  browser?: unknown
}

function runMarker(script: string, search: string): Marker | undefined {
  const sandbox: Record<string, unknown> = { location: { search }, URLSearchParams, navigator: { userAgent: 'tauri-test-agent' } }
  runInContext(script, createContext(sandbox))
  return sandbox.dshDesktop as Marker | undefined
}

describe('desktop account marker', () => {
  /** 官方账号 UI 的准入就是 `'dshDesktop' in globalThis`，因此这里验的是真实脚本行为。 */
  it('marks the embedded index only when the shell claimed it', async () => {
    vi.stubEnv('DSH_TAURI_EMBEDDED', '1')
    const { collect, on } = activate()

    expect(on).toHaveBeenCalledTimes(2)
    const rows = collect()
    expect(rows).toHaveLength(2)
    const row = rows.find((item) => item.kind === 'script' && item.text !== MEDIA_RECORDER_SHIM_SCRIPT)
    expect(row?.kind).toBe('script')
    expect(row?.kind === 'script' ? row.placement : undefined).toBe('head')

    const script = row?.kind === 'script' ? row.text : ''
    // 与官方 preload 的非 app 来源分支同值：只声明协议版本，产品 API 一律缺席。
    const carrier = runMarker(script, '?t=1&dshDesktop=1')
    expect(carrier?.protocolVersion).toBe(1)
    expect(carrier?.updates).toBeUndefined()
    expect(carrier?.browser).toBeUndefined()
    // 官方 0.2.0 反馈表单读 `dshDesktop.deviceInfo?.()`；Tauri 侧以 userAgent 兜底。
    await expect(carrier?.deviceInfo?.()).resolves.toBe('tauri-test-agent')
    expect(runMarker(script, '?t=1')).toBeUndefined()
  })

  it('injects the media recorder shim into the head', () => {
    vi.stubEnv('DSH_TAURI_EMBEDDED', '1')
    const rows = activate().collect()

    const shim = rows.find((item) => item.kind === 'script' && item.text === MEDIA_RECORDER_SHIM_SCRIPT)
    expect(shim?.kind === 'script' ? shim.placement : undefined).toBe('head')
  })

  it('does not advertise a desktop carrier to standalone web', () => {
    vi.stubEnv('DSH_TAURI_EMBEDDED', '0')
    const { collect, on } = activate()

    expect(on).not.toHaveBeenCalled()
    expect(collect()).toEqual([])
  })
})

const WEBKITGTK_UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15'
const CHROME_UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36'

interface RecorderCall {
  stream: unknown
  options?: Record<string, unknown>
}

function installRecorder(userAgent: string) {
  const calls: RecorderCall[] = []
  class FakeMediaRecorder {
    static isTypeSupported(type: string): boolean {
      return type === 'audio/webm;codecs=opus' || type === 'audio/ogg;codecs=opus'
    }

    constructor(stream: unknown, options?: Record<string, unknown>) {
      calls.push({ stream, options })
    }
  }
  const sandbox: Record<string, unknown> = { navigator: { userAgent }, MediaRecorder: FakeMediaRecorder }
  runInContext(MEDIA_RECORDER_SHIM_SCRIPT, createContext(sandbox))
  return { sandbox, calls, original: FakeMediaRecorder }
}

function recorderOf(sandbox: Record<string, unknown>) {
  return sandbox.MediaRecorder as unknown as new (stream: unknown, options?: Record<string, unknown>) => unknown
}

describe('media recorder mime default', () => {
  /** WebKitGTK 不指定 mimeType 时录不到数据；补默认类型是该脚本唯一目的。 */
  it('fills a supported mimeType for default calls in WebKitGTK', () => {
    const { sandbox, calls } = installRecorder(WEBKITGTK_UA)

    new (recorderOf(sandbox))('stream')

    expect(calls).toHaveLength(1)
    expect(calls[0]?.options).toEqual({ mimeType: 'audio/webm;codecs=opus' })
  })

  it('keeps explicit options untouched', () => {
    const { sandbox, calls } = installRecorder(WEBKITGTK_UA)

    new (recorderOf(sandbox))('stream', { mimeType: 'audio/ogg;codecs=opus', audioBitsPerSecond: 128000 })

    expect(calls[0]?.options).toEqual({ mimeType: 'audio/ogg;codecs=opus', audioBitsPerSecond: 128000 })
  })

  it('does not touch non-WebKitGTK pages', () => {
    const { sandbox, original } = installRecorder(CHROME_UA)

    expect(recorderOf(sandbox)).toBe(original)
  })

  it('wraps only once', () => {
    const { sandbox, calls } = installRecorder(WEBKITGTK_UA)
    runInContext(MEDIA_RECORDER_SHIM_SCRIPT, createContext(sandbox))

    new (recorderOf(sandbox))('stream')

    expect(calls).toHaveLength(1)
    expect(calls[0]?.options).toEqual({ mimeType: 'audio/webm;codecs=opus' })
  })
})
