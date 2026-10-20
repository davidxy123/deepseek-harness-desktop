// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    // AppImage 的 AppRun 把 GST 扫描器指到不存在的目录、并把 PYTHONHOME 泄漏给所有子进程，
    // 前者让 WebKitGTK 枚举不到任何音频源（getUserMedia 直接 NotAllowedError），后者让
    // gst-plugin-scanner 内嵌的 Python 插件初始化失败、并污染 bash 工具里的 python3。
    if let Ok(appdir) = std::env::var("APPDIR") {
        let scanner = format!("{appdir}/usr/lib/gstreamer-1.0/gst-plugin-scanner");
        if std::path::Path::new(&scanner).exists() {
            std::env::set_var("GST_PLUGIN_SCANNER", &scanner);
            std::env::set_var("GST_PLUGIN_SCANNER_1_0", &scanner);
        }
        for name in ["PYTHONHOME", "PYTHONPATH"] {
            if std::env::var_os(name).is_some_and(|value| value.to_string_lossy().contains(&appdir)) {
                std::env::remove_var(name);
            }
        }
    }

    // 无 GUI 的补丁入口：E2E 的插件 L2 直接起 `dsh web`，需要把 npm 装来的核心
    // 打成与桌面端装配核心同样的形态。复用 lib 里的补丁集，而不是另抄一份实现。
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--patch-core") {
        let Some(dir) = args.get(2) else {
            eprintln!("usage: deepseek-harness-desktop --patch-core <core-dir>");
            std::process::exit(2);
        };
        if let Err(e) = main::patch_core_dir(std::path::Path::new(dir)) {
            eprintln!("patch-core failed: {e}");
            std::process::exit(1);
        }
        return;
    }
    if let Err(error) = main::run() {
        main::desktop::startup::report(&error);
        std::process::exit(1);
    }
}
