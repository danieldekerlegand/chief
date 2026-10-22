use serde::Deserialize;
use tauri::{
    image::Image,
    menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconBuilder,
    AppHandle, Emitter, Listener, Manager, WindowEvent,
};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt as AutostartManagerExt};
use tauri_plugin_notification::NotificationExt;
use tauri_plugin_shell::ShellExt;
use tauri_plugin_shell::process::CommandChild;
use std::sync::Mutex;

struct SidecarState(Mutex<Option<CommandChild>>);

impl Drop for SidecarState {
    fn drop(&mut self) {
        if let Ok(slot) = self.0.get_mut() {
            if let Some(child) = slot.take() {
                let _ = child.kill();
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ObserverSummary {
    projects: usize,
    active: usize,
}

fn show_dashboard(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

fn tray_image() -> Image<'static> {
    let mut rgba = Vec::with_capacity(16 * 16 * 4);
    for y in 0..16 {
        for x in 0..16 {
            let inside = (2..14).contains(&x) && (2..14).contains(&y);
            let c_cutout = (5..12).contains(&y) && x >= 7 && (x >= 11 || !(7..10).contains(&y));
            rgba.extend_from_slice(if inside && !c_cutout {
                &[255, 123, 62, 255]
            } else {
                &[0, 0, 0, 0]
            });
        }
    }
    Image::new_owned(rgba, 16, 16)
}

#[tauri::command]
fn autostart_enabled(app: AppHandle) -> Result<bool, String> {
    app.autolaunch().is_enabled().map_err(|error| error.to_string())
}

#[tauri::command]
fn set_autostart(app: AppHandle, enabled: bool) -> Result<(), String> {
    let manager = app.autolaunch();
    if enabled {
        manager.enable()
    } else {
        manager.disable()
    }
    .map_err(|error| error.to_string())
}

#[tauri::command]
fn notify_transition(app: AppHandle, title: String, body: String) -> Result<(), String> {
    app.notification()
        .builder()
        .title(title)
        .body(body)
        .show()
        .map_err(|error| error.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            Some(vec!["--hidden"]),
        ))
        .invoke_handler(tauri::generate_handler![
            autostart_enabled,
            set_autostart,
            notify_transition
        ])
        .setup(|app| {
            // chiefd remains a read-only sidecar. The shell plugin owns the child and
            // terminates it with the desktop process.
            let (_events, child) = app.shell()
                .sidecar("binaries/chiefd")?
                .spawn()
                .map_err(|error| error.to_string())?;
            app.manage(SidecarState(Mutex::new(Some(child))));
            let status = MenuItem::with_id(app, "status", "Connecting to chiefd…", false, None::<&str>)?;
            let open = MenuItem::with_id(app, "open", "Open Dashboard", true, None::<&str>)?;
            let refresh = MenuItem::with_id(app, "refresh", "Refresh Sources", true, None::<&str>)?;
            let launch_at_login = CheckMenuItem::with_id(
                app,
                "autostart",
                "Launch at login",
                true,
                app.autolaunch().is_enabled().unwrap_or(false),
                None::<&str>,
            )?;
            let separator = PredefinedMenuItem::separator(app)?;
            let quit = MenuItem::with_id(app, "quit", "Quit Chief", true, None::<&str>)?;
            let menu = Menu::with_items(
                app,
                &[&status, &open, &refresh, &launch_at_login, &separator, &quit],
            )?;

            let status_for_events = status.clone();
            app.listen("observer-summary", move |event| {
                if let Ok(summary) = serde_json::from_str::<ObserverSummary>(event.payload()) {
                    let _ = status_for_events.set_text(format!(
                        "{} active · {} projects",
                        summary.active, summary.projects
                    ));
                }
            });

            let autostart_for_menu = launch_at_login.clone();
            TrayIconBuilder::with_id("chief")
                .icon(tray_image())
                .tooltip("Chief Observatory")
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(move |app, event| match event.id().as_ref() {
                    "open" => show_dashboard(app),
                    "refresh" => {
                        let _ = app.emit("observer-refresh", ());
                        show_dashboard(app);
                    }
                    "autostart" => {
                        let manager = app.autolaunch();
                        let enabled = manager.is_enabled().unwrap_or(false);
                        let result = if enabled { manager.disable() } else { manager.enable() };
                        if result.is_ok() {
                            let _ = autostart_for_menu.set_checked(!enabled);
                        }
                    }
                    "quit" => {
                        if let Some(state) = app.try_state::<SidecarState>() {
                            if let Ok(mut child) = state.0.lock() {
                                if let Some(child) = child.take() {
                                    let _ = child.kill();
                                }
                            }
                        }
                        app.exit(0)
                    },
                    _ => {}
                })
                .build(app)?;

            if std::env::args().any(|argument| argument == "--hidden") {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.hide();
                }
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running Chief Observatory");
}
