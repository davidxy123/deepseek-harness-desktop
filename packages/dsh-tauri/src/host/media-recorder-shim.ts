/**
 * WebKitGTK 在不指定 `mimeType` 时构造 `MediaRecorder` 会启动但产不出任何 chunk，
 * 上游语音插件因此把整段录音判为空（桌面端表现为「未识别到语音」）。本脚本在解析期
 * 包装构造器：只在 Linux WebKitGTK 页面里，为缺省 `mimeType` 的调用补一个引擎支持的
 * 编码类型；显式传参与其他录音选项保持原样，非 WebKitGTK 页面完全不介入。
 *
 * 走 `webserver/index-inject` 的 head 经典脚本通道，先于任何客户端模块执行，因此不依赖
 * 上游包路径、文件内容或加载顺序。
 */
export const MEDIA_RECORDER_SHIM_SCRIPT = `(() => {
  const Native = globalThis.MediaRecorder;
  if (typeof Native !== "function" || Native.__dshDesktopMimeDefault) return;
  if (typeof Native.isTypeSupported !== "function") return;
  const ua = navigator.userAgent || "";
  if (ua.indexOf("Linux") < 0 || ua.indexOf("AppleWebKit") < 0 || /Chrome|Chromium/.test(ua)) return;
  const candidates = ["audio/webm;codecs=opus", "audio/ogg;codecs=opus", "audio/webm", "audio/ogg", "audio/mp4"];
  const pick = () => candidates.find((type) => Native.isTypeSupported(type));
  const WrappedMediaRecorder = new Proxy(Native, {
    construct(target, args, newTarget) {
      const options = args[1];
      const explicit = options !== undefined && options !== null && typeof options.mimeType === "string" && options.mimeType !== "";
      const mimeType = explicit ? undefined : pick();
      if (mimeType === undefined) return Reflect.construct(target, args, newTarget);
      const next = args.slice();
      next[1] = Object.assign({}, options, { mimeType });
      return Reflect.construct(target, next, newTarget);
    }
  });
  Object.defineProperty(WrappedMediaRecorder, "__dshDesktopMimeDefault", { value: true });
  globalThis.MediaRecorder = WrappedMediaRecorder;
})();`
