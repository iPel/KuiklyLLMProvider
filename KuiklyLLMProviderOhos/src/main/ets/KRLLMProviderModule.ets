import { KuiklyRenderBaseModule, KRAny, KuiklyRenderCallback } from '@kuikly-open/render';
import llmprovider from 'libllm_provider.so';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';

/**
 * HarmonyOS implementation of the KuiklyLLMProvider control plane.
 * resfile ships as real read-only files, so the bundled variant needs no merge;
 * the download variant streams GGUF into filesDir with Range resume.
 */
interface ModelEntry {
  id: string;
  name: string;
  file: string;
  bytes: number;
  sha256: string;
  url_primary: string;
  url_backup: string;
  bundled: boolean;
}

/**
 * 按 modelId 保存在途下载句柄。fd 仅存 number（closeSync 支持 number），关闭后置 -1，
 * 绝不重复 close（fd 号可能已被复用）。
 * cancel 闭包持有 http 请求句柄，避免依赖 SDK 具体类型名。
 * cancelled 区分「主动暂停/取消」与「真实失败」，不把取消记为错误。
 * untrustedFrom：续传时尚未确认服务端按 Range 返回，.part 中该偏移之后的数据不可信；-1 表示全部可信。
 */
interface DownloadHandle {
  fd: number;
  cancel: () => void;
  cancelled: boolean;
  untrustedFrom: number;
}

// ---------------------------------------------------------------------------
// 契约字面量集中为文件内常量，与 LLMProviderContract.kt /
// AndroidProviderContract.kt 保持一致。改动任一值须同步三端契约源。
// ---------------------------------------------------------------------------
const MODULE_NAME: string = 'KRLLMProviderModule';

const METHOD_START: string = 'startServer';
const METHOD_STOP: string = 'stopServer';
const METHOD_STATUS: string = 'serverStatus';
const METHOD_MODELS: string = 'models';
const METHOD_MODEL_ACTION: string = 'modelAction';

const KEY_PORT: string = 'port';
const KEY_MODEL_ID: string = 'modelId';
const KEY_ACTION: string = 'action';
const KEY_DATA: string = 'data';
const KEY_OK: string = 'ok';
const KEY_MODELS: string = 'models';
const KEY_ERROR: string = 'error';
const KEY_ID: string = 'id';
const KEY_NAME: string = 'name';
const KEY_BYTES: string = 'bytes';
const KEY_STATE: string = 'state';
const KEY_DOWNLOADED: string = 'downloaded';
const KEY_TOTAL: string = 'total';
const KEY_ACTIVE: string = 'active';
const KEY_BUNDLED: string = 'bundled';
const KEY_ACTIONS: string = 'actions';

const ACTION_DOWNLOAD: string = 'download';
const ACTION_PAUSE: string = 'pause';
const ACTION_RESUME: string = 'resume';
const ACTION_CANCEL: string = 'cancel';
const ACTION_SELECT: string = 'select';
const ACTION_DELETE: string = 'delete';

const STATE_DOWNLOADING: string = 'downloading';
const STATE_PAUSED: string = 'paused';
const STATE_READY: string = 'ready';
const STATE_ACTIVE: string = 'active';
const STATE_NOT_AVAILABLE: string = 'not_available';

// 0 = 不指定端口，由内核分配；实际地址从 llmprovider.status() 的 baseUrl 取。
const DEFAULT_PORT: number = 0;
// scripts/prepare-variant.sh 写入 resfile 的内置模型文件名。
const BUNDLED_MODEL_FILE: string = 'model.gguf';

const LOG_TAG = 'llm_provider';
let catalog: ModelEntry[] = [];
let activeId: string = '';
let lastError: string = '';
/**
 * 活跃下载句柄表（modelId -> handle）。
 * 保证一个 modelId 同时只有一个 req/fd，避免 resume 双 fd 写同一 .part。
 */
const downloads: Map<string, DownloadHandle> = new Map();
/**
 * 应用目录在首次 call()（Kuikly 线程，UI 上下文可用）时缓存。
 * 下载回调可能在 Module 销毁后才执行，届时 getContext() 不一定可用。
 */
let appFilesDir: string = '';
let appResourceDir: string = '';

function initDirs(): void {
  if (appFilesDir) return;
  const ctx = getContext();
  appFilesDir = ctx.filesDir;
  appResourceDir = ctx.resourceDir;
}

/** 引擎当前实际加载的模型 id（未加载为空串）；activeId 一律以此回填，不由平台层推断。 */
function engineModelId(): string {
  return llmprovider.status(true, '').modelId;
}

function log(msg: string): void {
  hilog.info(0x1, LOG_TAG, '%{public}s', msg);
}

/** TextDecoder 按 UTF-8 解码，fd 在 finally 统一关闭。 */
function readText(path: string): string {
  let fd: number = -1;
  try {
    fd = fs.openSync(path, fs.OpenMode.READ_ONLY).fd;
    const stat = fs.statSync(path);
    const buf = new ArrayBuffer(stat.size);
    fs.readSync(fd, buf);
    return util.TextDecoder.create('utf-8').decode(new Uint8Array(buf));
  } catch (e) {
    return '';
  } finally {
    if (fd >= 0) {
      try { fs.closeSync(fd); } catch (e) { /* ignore */ }
    }
  }
}

function loadCatalog(): void {
  if (catalog.length > 0) return;
  const raw = readText(`${appResourceDir}/catalog.json`);
  if (!raw) { lastError = 'catalog.json missing'; return; }
  try {
    const parsed: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
    catalog = (parsed[KEY_MODELS] as ModelEntry[]) ?? [];
  } catch (e) {
    lastError = 'catalog.json invalid';
  }
}

function modelDir(): string {
  const dir = `${appFilesDir}/models`;
  try { fs.mkdirSync(dir, true); } catch (e) { /* exists */ }
  return dir;
}

/** 可写目录中的模型路径：下载落盘与 .part 均以此为基准。 */
function downloadPathOf(m: ModelEntry): string { return `${modelDir()}/${m.file}`; }

/**
 * 模型实际使用的路径。内置模型直接使用 resfile：安装后即为可 mmap 的只读真实文件，无需拷贝。
 * resfile 缺失时退回可写目录（此时可下载）。
 */
function pathOf(m: ModelEntry): string {
  if (m.bundled) {
    const res = `${appResourceDir}/${BUNDLED_MODEL_FILE}`;
    try { if (fs.accessSync(res)) return res; } catch (e) { /* fall through */ }
  }
  return downloadPathOf(m);
}
function partOf(m: ModelEntry): string { return `${downloadPathOf(m)}.part`; }

/** fd 在 finally 关闭，消除异常路径泄漏。 */
function ggufMagic(path: string): boolean {
  let fd: number = -1;
  try {
    fd = fs.openSync(path, fs.OpenMode.READ_ONLY).fd;
    const buf = new ArrayBuffer(4);
    fs.readSync(fd, buf);
    const u = new Uint8Array(buf);
    return u[0] === 0x47 && u[1] === 0x47 && u[2] === 0x55 && u[3] === 0x46;
  } catch (e) {
    return false;
  } finally {
    if (fd >= 0) {
      try { fs.closeSync(fd); } catch (e) { /* ignore */ }
    }
  }
}

/**
 * start / select / 状态判定用的轻量检查：size + GGUF 魔数。
 * 最终路径要么是签名包内的 resfile，要么只经「size + SHA-256 严格校验后 rename」写入，
 * 且在应用私有目录，无需每次重新计算整文件哈希。
 */
function isPlausible(m: ModelEntry, path: string): boolean {
  try {
    if (fs.statSync(path).size !== m.bytes) return false;
    return ggufMagic(path);
  } catch (e) { return false; }
}

/** 流式 SHA-256，仅在下载完成、rename 到最终路径之前执行一次；读与摘要均走异步接口。 */
async function sha256Matches(path: string, expected: string): Promise<boolean> {
  if (!expected) return false;   // catalog 无摘要一律视为不可信
  let fd: number = -1;
  try {
    fd = fs.openSync(path, fs.OpenMode.READ_ONLY).fd;
    const md = cryptoFramework.createMd('SHA256');
    const buf = new ArrayBuffer(1024 * 1024);
    let n: number = await fs.read(fd, buf);
    while (n > 0) {
      await md.update({ data: new Uint8Array(buf, 0, n) });
      n = await fs.read(fd, buf);
    }
    const digest: Uint8Array = (await md.digest()).data;
    let hex = '';
    for (let i = 0; i < digest.length; i++) hex += digest[i].toString(16).padStart(2, '0');
    return hex === expected.toLowerCase();
  } catch (e) {
    return false;
  } finally {
    if (fd >= 0) {
      try { fs.closeSync(fd); } catch (e) { /* ignore */ }
    }
  }
}

function firstReady(): ModelEntry | undefined {
  loadCatalog();
  for (const m of catalog) if (isPlausible(m, pathOf(m))) return m;
  return undefined;
}

function stateOf(m: ModelEntry): string {
  const dest = pathOf(m);
  if (downloads.has(m.id)) return STATE_DOWNLOADING;
  if (isPlausible(m, dest)) return m.id === activeId ? STATE_ACTIVE : STATE_READY;
  try { if (fs.accessSync(partOf(m))) return STATE_PAUSED; } catch (e) { /* none */ }
  return STATE_NOT_AVAILABLE;
}

function downloadedOf(m: ModelEntry): number {
  const dest = pathOf(m);
  try { if (fs.accessSync(dest)) return fs.statSync(dest).size; } catch (e) { /* none */ }
  try { if (fs.accessSync(partOf(m))) return fs.statSync(partOf(m)).size; } catch (e) { /* none */ }
  return 0;
}

function snapshot(): string {
  loadCatalog();
  const models: Record<string, Object>[] = [];
  for (const m of catalog) {
    const state = stateOf(m);
    let actions: string[];
    if (state === STATE_DOWNLOADING) actions = [ACTION_PAUSE, ACTION_CANCEL];
    else if (state === STATE_PAUSED) actions = [ACTION_RESUME, ACTION_CANCEL];
    else if (state === STATE_READY) actions = m.bundled ? [ACTION_SELECT] : [ACTION_SELECT, ACTION_DELETE];
    else if (state === STATE_ACTIVE) actions = m.bundled ? [] : [ACTION_DELETE];
    else actions = [ACTION_DOWNLOAD];
    const item: Record<string, Object> = {};
    item[KEY_ID] = m.id;
    item[KEY_NAME] = m.name;
    item[KEY_BYTES] = m.bytes;
    item[KEY_STATE] = state;
    item[KEY_DOWNLOADED] = downloadedOf(m);
    item[KEY_TOTAL] = m.bytes;
    item[KEY_ACTIVE] = m.id === activeId;
    item[KEY_BUNDLED] = m.bundled;
    item[KEY_ACTIONS] = actions;
    models.push(item);
  }
  const result: Record<string, Object> = {};
  result[KEY_MODELS] = models;
  result[KEY_ERROR] = lastError;
  return JSON.stringify(result);
}

/** 关闭下载 fd 并置 -1，幂等。 */
function closeDownloadFd(h: DownloadHandle): void {
  if (h.fd < 0) return;
  try { fs.closeSync(h.fd); } catch (e) { /* ignore */ }
  h.fd = -1;
}

/** 统一释放句柄（fd + req），幂等；finalize / catch / pause / cancel / onDestroy 共用。 */
function releaseDownload(id: string, destroyReq: boolean): void {
  const h = downloads.get(id);
  if (!h) return;
  downloads.delete(id);
  if (destroyReq) h.cancel();
  closeDownloadFd(h);
}

/**
 * 下载收尾：全新下载必须 200、续传必须 206，通过 size + SHA-256 严格校验后才 rename 到最终路径。
 * 校验期间句柄仍在表中（状态为 downloading）；期间被暂停/取消则不落盘，交由对应动作处理 .part。
 */
async function finalizeDownload(m: ModelEntry, handle: DownloadHandle, offset: number,
  code: number, useBackup: boolean): Promise<void> {
  if (downloads.get(m.id) !== handle || handle.cancelled) return;
  closeDownloadFd(handle);   // 先停止写入，再截断 / 校验 / rename
  const part = partOf(m);
  const expected = offset > 0 ? 206 : 200;
  let restart = false;
  let switchSource = false;
  try {
    if (offset > 0 && code === 200) {
      // 服务端忽略 Range 返回整文件：已追加进 .part 的数据不可用，丢弃后重新下载完整文件。
      fs.unlinkSync(part);
      restart = true;
    } else if (code !== expected) {
      // 错误页内容可能已追加进 .part：截回续传起点，保留此前进度。
      fs.truncateSync(part, offset);
      lastError = `HTTP ${code}`;
    } else {
      const ok = isPlausible(m, part) && await sha256Matches(part, m.sha256);
      if (!handle.cancelled) {
        if (ok) {
          try { fs.unlinkSync(downloadPathOf(m)); } catch (e) { /* none */ }
          fs.renameSync(part, downloadPathOf(m));
        } else {
          fs.unlinkSync(part);
          lastError = 'model verification failed';
          // 全新下载内容不符（错误页 / 劫持）：换备用源从头重新下载一次。
          switchSource = offset === 0 && canSwitchToBackup(m, useBackup);
        }
      }
    }
  } catch (e) {
    lastError = 'finalize failed';
  } finally {
    if (downloads.get(m.id) === handle) releaseDownload(m.id, true);
  }
  // 忽略 Range 的重新下载沿用本次的源，不消耗换源次数。
  if (restart) downloadModel(m, false, useBackup);
  else if (switchSource) downloadModel(m, false, true);
}

/** 主源不可用时是否还能切备用源：未切过、备用源已配置（catalog 缺字段时为 undefined）且与主源不同。 */
function canSwitchToBackup(m: ModelEntry, useBackup: boolean): boolean {
  return !useBackup && typeof m.url_backup === 'string' && m.url_backup !== '' &&
    m.url_backup !== m.url_primary;
}

/** 响应头中 Content-Range 的起点是否等于 offset（头名大小写不敏感）。 */
function rangeStartsAt(header: Object, offset: number): boolean {
  const h = header as Record<string, Object>;
  for (const k of Object.keys(h)) {
    if (k.toLowerCase() !== 'content-range') continue;
    const r = /^bytes\s+(\d+)-/i.exec(String(h[k]).trim());
    return r !== null && Number(r[1]) === offset;
  }
  return false;
}

/** 丢弃未确认按 Range 返回后追加的数据（服务端可能忽略 Range 回整文件），截回续传起点。 */
function dropUntrusted(m: ModelEntry, h: DownloadHandle): void {
  if (h.untrustedFrom < 0) return;
  try { fs.truncateSync(partOf(m), h.untrustedFrom); } catch (e) { /* 截断失败时由后续 SHA-256 校验拦截 */ }
}

/** useBackup 仅由主源失败后的重试置 true，保证每个模型只切一次源。 */
async function downloadModel(m: ModelEntry, resume: boolean, useBackup: boolean = false): Promise<void> {
  // 一个 modelId 只允许一个在途下载，杜绝 resume 双 fd 写同一 .part。
  if (downloads.has(m.id)) return;
  lastError = '';
  const part = partOf(m);
  let offset = 0;
  if (resume) {
    try { if (fs.accessSync(part)) offset = fs.statSync(part).size; } catch (e) { offset = 0; }
    // .part 已达到或超过完整大小（如在校验期间暂停、或服务端返回错误页被写入），续传无意义，重新下载完整文件。
    if (offset >= m.bytes) offset = 0;
  }
  const req = http.createHttp();
  const header: Record<string, string> = {};
  if (offset > 0) header['Range'] = `bytes=${offset}-`;
  let fd: number;
  try {
    fd = fs.openSync(part,
      offset > 0 ? (fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND)
                 : (fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)).fd;
  } catch (e) {
    lastError = 'open part failed';
    try { req.destroy(); } catch (err) { /* ignore */ }
    return;
  }
  const handle: DownloadHandle = {
    fd: fd,
    cancel: (): void => { try { req.destroy(); } catch (e) { /* ignore */ } },
    cancelled: false,
    untrustedFrom: offset > 0 ? offset : -1,
  };
  downloads.set(m.id, handle);

  // headersReceive 不带状态码，以 Content-Range 判定续传是否成立；重定向会多次回调，以最后一次为准。
  if (offset > 0) {
    req.on('headersReceive', (h: Object): void => {
      handle.untrustedFrom = rangeStartsAt(h, offset) ? -1 : offset;
    });
  }

  let received = false;
  req.on('dataReceive', (data: ArrayBuffer): void => {
    if (downloads.get(m.id) !== handle || handle.fd < 0) return;
    received = true;
    try { fs.writeSync(handle.fd, data); } catch (e) { /* 由 finalize / catch 收尾 */ }
  });
  // 响应码来自 requestInStream 的 Promise（HTTP 错误码也走 resolve），响应体结束由 dataEnd 通知；
  // 两者先后无文档承诺，2xx 时等两者都到齐再收尾。非 2xx 不等 dataEnd：fd 关闭后迟到的数据被丢弃。
  let ended = false;
  let code = -1;
  let settled = false;
  const settle = (): void => {
    if (settled || code < 0) return;
    if (!ended && code >= 200 && code < 300) return;
    settled = true;
    // 非 2xx：切备用源重试一次。错误页可能已写入 .part，先截回本次起点；
    // 两镜像字节一致，备用源从同一偏移续传，不丢已有进度。
    if ((code < 200 || code >= 300) && downloads.get(m.id) === handle &&
      canSwitchToBackup(m, useBackup)) {
      releaseDownload(m.id, true);
      let resumeOnBackup = offset > 0;
      // 截断失败时 .part 尾部可能残留错误页，不能在其后续传，改为从头下载（TRUNC）。
      try { fs.truncateSync(part, offset); } catch (e) { resumeOnBackup = false; }
      downloadModel(m, resumeOnBackup, true);
      return;
    }
    finalizeDownload(m, handle, offset, code, useBackup);
  };
  req.on('dataEnd', (): void => {
    ended = true;
    settle();
  });
  try {
    code = await req.requestInStream(useBackup ? m.url_backup : m.url_primary, {
      method: http.RequestMethod.GET,
      header: header,
      connectTimeout: 15000,
      readTimeout: 60000,
    });
  } catch (e) {
    if (downloads.get(m.id) === handle) {
      releaseDownload(m.id, true);
      if (handle.cancelled) return;   // 主动暂停/取消不记为错误
      // 尚未收到数据的连接失败才切备用源，按续传打开：.part 未被本次写入，保留已有进度。
      // 已收到数据后中途断开：不跨源续传，保留 .part（丢弃未确认按 Range 返回的部分）并记错误，
      // 由用户续传。
      if (!received && canSwitchToBackup(m, useBackup)) {
        downloadModel(m, true, true);
      } else {
        dropUntrusted(m, handle);
        lastError = 'download failed';
      }
    }
    return;
  }
  settle();
}

/**
 * 进程级串行链：所有改变 native 服务状态的操作（start / stop / select / delete）按调用顺序执行。
 * native 调用本身在 NAPI 后台线程，不阻塞 Kuikly 线程；同一时刻只有一个在途。
 */
let serviceChain: Promise<void> = Promise.resolve();

function enqueueService(task: () => Promise<void>): void {
  serviceChain = serviceChain.then(task).catch((): void => { /* 单个任务失败不阻断后续任务 */ });
}

/** 把 NAPI *Async 回调接口包装为 Promise；投递失败（同步返回 -1）时直接以 -1 结束。 */
function napiAsync(invoke: (cb: (ok: number) => void) => number | undefined): Promise<number> {
  return new Promise<number>((resolve: (ok: number) => void): void => {
    if (invoke((ok: number): void => resolve(ok)) === -1) resolve(-1);
  });
}

/** 仅在服务串行链内调用：文件状态在排队期间可能变化，执行时再判定。 */
async function selectModel(m: ModelEntry | undefined): Promise<boolean> {
  if (!m) return false;
  const dest: string = pathOf(m);
  if (!isPlausible(m, dest)) return false;
  const id: string = m.id;
  const code = await napiAsync((cb: (ok: number) => void): number | undefined =>
    llmprovider.loadModelAsync(dest, id, cb));
  // 先卸后载：失败时引擎已无模型，以引擎实际状态为准（为空串）。
  activeId = engineModelId();
  return code === 1;
}

/** 仅在服务串行链内调用：与 select 按序执行，避免卸载与加载交错。 */
async function deleteModel(m: ModelEntry | undefined): Promise<boolean> {
  if (!m || m.bundled) return false;
  if (activeId === m.id) {
    activeId = '';
    // 先卸载引擎再删文件：服务回到「无可用模型」状态。
    await napiAsync((cb: (ok: number) => void): number | undefined =>
      llmprovider.loadModelAsync('', '', cb));
  }
  const h = downloads.get(m.id);
  if (h) h.cancelled = true;
  releaseDownload(m.id, true);
  try { fs.unlinkSync(pathOf(m)); } catch (e) { /* none */ }
  try { fs.unlinkSync(partOf(m)); } catch (e) { /* none */ }
  return true;
}

function action(m: ModelEntry | undefined, name: string): boolean {
  if (!m) return false;
  switch (name) {
    case ACTION_DOWNLOAD:
      downloadModel(m, false);
      return true;
    case ACTION_RESUME:
      downloadModel(m, true);
      return true;
    case ACTION_PAUSE: {
      const h = downloads.get(m.id);
      if (h) h.cancelled = true;
      // 取消时销毁请求并关闭 fd，保留 .part 供续传，不留下后台写者。
      releaseDownload(m.id, true);
      if (h) dropUntrusted(m, h);
      return true;
    }
    case ACTION_CANCEL: {
      const h = downloads.get(m.id);
      if (h) h.cancelled = true;
      releaseDownload(m.id, true);
      try { fs.unlinkSync(partOf(m)); } catch (e) { /* none */ }
      return true;
    }
    default:
      return false;
  }
}

export class KRLLMProviderModule extends KuiklyRenderBaseModule {
  static readonly MODULE_NAME: string = MODULE_NAME;

  syncMode(): boolean { return true; }

  // 不覆写 onDestroy：服务与下载都是进程级资源，与 Android / iOS 一致，
  // 不随某个 Module 实例销毁而取消。

  call(method: string, params: KRAny, callback: KuiklyRenderCallback | null): KRAny {
    initDirs();
    loadCatalog();
    switch (method) {
      case METHOD_START: {
        const args = this.parse(params);
        const port = (args[KEY_PORT] as number) ?? DEFAULT_PORT;
        enqueueService(async (): Promise<void> => {
          // 内置模型直接读 resfile，选模只做 size + 魔数；GGUF 加载在 NAPI 后台线程。
          const first = firstReady();
          const path = first ? pathOf(first) : '';
          const mid = first ? first.id : '';
          const ok = await napiAsync((cb: (ok: number) => void): number | undefined =>
            llmprovider.startAsync(port, path, mid, cb));
          const detail = llmprovider.lastError();
          const st = llmprovider.status(ok === 1, ok === 1 ? '服务已启动' : (detail || '启动失败'));
          // 服务已在运行时 start 幂等返回、不会加载 first，以引擎实际加载的模型为准。
          if (ok === 1) activeId = st.modelId;
          callback?.(st);
        });
        return null;
      }
      case METHOD_STOP: {
        enqueueService(async (): Promise<void> => {
          await napiAsync((cb: (ok: number) => void): number | undefined => llmprovider.stopAsync(cb));
          activeId = engineModelId();   // 停止后引擎无模型（空串）
          callback?.(llmprovider.status(true, '服务已停止'));
        });
        return null;
      }
      case METHOD_STATUS: {
        callback?.(llmprovider.status(llmprovider.isRunning() === 1, ''));
        return null;
      }
      case METHOD_MODELS: {
        const payload: Record<string, Object> = {};
        payload[KEY_DATA] = snapshot();
        callback?.(payload);
        return null;
      }
      case METHOD_MODEL_ACTION: {
        const args = this.parse(params);
        const act = (args[KEY_ACTION] as string) ?? '';
        const mid = (args[KEY_MODEL_ID] as string) ?? '';
        const target = catalog.find((x: ModelEntry): boolean => x.id === mid);
        if (act === ACTION_SELECT || act === ACTION_DELETE) {
          // select 加载模型、delete 可能卸载模型，进服务串行链保证与 start / stop 按序生效；
          // 加载 / 卸载走 NAPI 后台线程，不阻塞 Kuikly 线程。
          // 下载类动作不碰 native 服务，不应排在可能长时间等待的 stop 之后。
          enqueueService(async (): Promise<void> => {
            const ok = act === ACTION_SELECT ? await selectModel(target) : await deleteModel(target);
            if (!ok && act === ACTION_SELECT) lastError = 'engine failed to load model';
            const payload: Record<string, Object> = {};
            payload[KEY_OK] = ok;
            payload[KEY_DATA] = snapshot();
            callback?.(payload);
          });
          return null;
        }
        const ok = action(target, act);
        const payload: Record<string, Object> = {};
        payload[KEY_OK] = ok;
        payload[KEY_DATA] = snapshot();
        callback?.(payload);
        return null;
      }
      default:
        callback?.(llmprovider.status(false, `unknown method: ${method}`));
        return null;
    }
  }

  private parse(params: KRAny): Record<string, Object> {
    if (typeof params === 'string') {
      try { return JSON.parse(params as string) as Record<string, Object>; } catch (e) { return {}; }
    }
    if (params !== null && typeof params === 'object') return params as Record<string, Object>;
    return {};
  }
}
