export interface LLMProviderStatus {
  ok: boolean;
  running: boolean;
  port: number;
  baseUrl: string;
  modelId: string;
  engine: string;
  modelLoaded: boolean;
  apiKey: string;
  message: string;
}

/*
 * 以下 *Async 接口在后台线程执行，完成后回调；返回 undefined 表示已投递。
 * 入参非法或投递失败时同步返回 -1，且不会回调。
 */

export const start: (port: number, modelPath: string, modelId: string) => number;
/** 异步启动：GGUF 加载在 NAPI 后台线程执行，完成后回调，不阻塞 Kuikly 线程。 */
export const startAsync: (port: number, modelPath: string, modelId: string,
  callback: (ok: number) => void) => number | undefined;
export const stop: () => void;
/** 异步停止：等待在途连接与生成退出在后台线程完成，回调参数恒为 1。 */
export const stopAsync: (callback: (ok: number) => void) => number | undefined;
export const isRunning: () => number;
export const loadModel: (modelPath: string, modelId: string) => number;
/** 异步热切换模型：加载在后台线程执行，完成后回调。 */
export const loadModelAsync: (modelPath: string, modelId: string,
  callback: (ok: number) => void) => number | undefined;
export const modelLoaded: () => number;
export const lastError: () => string;
export const status: (ok: boolean, message: string) => LLMProviderStatus;
