// Soporte JUSTECNO: a los equipos de los clientes solo se pueden conectar los técnicos de JUSTECNO, desde la app
// JUSTECNO Técnico instalada en un PC aprobado (y con Gestión conectado, para que su PC quede vigilado).
//
// Cómo, sin cambiar el protocolo de RustDesk: el número de sesión (session_id) que el técnico manda al conectarse
// lo da el servidor de JUSTECNO (un "pase"). El servidor solo da pases a PCs de técnicos aprobados. El equipo del
// cliente le pregunta al servidor si ese técnico tiene ese pase para él; si no, rechaza la conexión. RustDesk
// normal, el cliente web o la versión portable no consiguen pase.
use hbb_common::{config::Config, log};
use serde_json::{json, Value};
use std::time::Duration;

const URL: &str = "https://justecno.com/jt-grabaciones/api/tecnico";
const APP_TECNICO: &str = "JUSTECNO-Tecnico";
const APP_CLIENTE: &str = "JUSTECNO";
const OPCION_CLAVE: &str = "jt-tecnico-clave";

fn cliente() -> reqwest::blocking::Client {
    super::create_http_client_with_url(&format!("{}/estado", URL))
}

fn clave() -> String {
    let k = Config::get_option(OPCION_CLAVE);
    if k.len() >= 32 {
        return k;
    }
    let k = format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    );
    Config::set_option(OPCION_CLAVE.to_owned(), k.clone());
    k
}

fn usuario() -> String {
    std::env::var("USERNAME")
        .or_else(|_| std::env::var("USER"))
        .unwrap_or_default()
}

/// App del técnico: pide al servidor de JUSTECNO el pase para conectarse a `destino`.
/// Devuelve None en la app de clientes o si el servidor no lo da (el equipo del cliente dirá por qué).
pub fn pase(destino: &str) -> Option<u64> {
    if crate::get_app_name() != APP_TECNICO {
        return None;
    }
    let destino = destino.to_owned();
    // en su propio hilo: aquí puede no estar permitido bloquear
    std::thread::spawn(move || {
        let datos = json!({
            "id": Config::get_id(), "clave": clave(), "destino": destino,
            "instalado": crate::ui_interface::is_installed(),
            "equipo": crate::common::hostname(), "usuario": usuario(),
            "so": std::env::consts::OS, "version": crate::VERSION,
        });
        match cliente()
            .post(format!("{}/pase", URL))
            .json(&datos)
            .timeout(Duration::from_secs(10))
            .send()
        {
            Ok(r) => {
                let v: Value = r.json().unwrap_or_default();
                if let Some(e) = v.get("error") {
                    log::warn!("justecno: sin pase: {}", e);
                }
                v.get("sesion")
                    .and_then(|s| s.as_str())
                    .and_then(|s| s.parse::<u64>().ok())
                    .filter(|s| *s != 0)
            }
            Err(e) => {
                log::warn!("justecno: no se pudo pedir el pase: {}", e);
                None
            }
        }
    })
    .join()
    .ok()
    .flatten()
}

/// App de clientes: comprueba con el servidor de JUSTECNO que `tecnico` tiene un pase para este equipo.
pub async fn verificar(tecnico: &str, sesion: u64) -> Result<(), String> {
    if crate::get_app_name() != APP_CLIENTE {
        return Ok(());
    }
    let equipo = Config::get_id();
    let tecnico = tecnico.to_owned();
    // Err(None): no se pudo hablar con el servidor; Err(Some(motivo)): el servidor dijo que no
    let r = hbb_common::tokio::task::spawn_blocking(move || -> Result<(), Option<String>> {
        let r = cliente()
            .get(format!("{}/verificar", URL))
            .query(&[
                ("equipo", equipo),
                ("tecnico", tecnico),
                ("sesion", sesion.to_string()),
            ])
            .timeout(Duration::from_secs(10))
            .send()
            .map_err(|e| {
                log::warn!("justecno: no se pudo verificar al técnico: {}", e);
                None
            })?;
        let estado = r.status();
        let v: Value = r.json().unwrap_or_default();
        if estado.is_success() {
            return Ok(());
        }
        if estado.is_server_error() {
            return Err(None);
        }
        Err(Some(
            v.get("error")
                .and_then(|e| e.as_str())
                .unwrap_or("Solo los técnicos de JUSTECNO pueden conectarse a este equipo.")
                .to_owned(),
        ))
    })
    .await;
    match r {
        Ok(Ok(())) => Ok(()),
        Ok(Err(Some(motivo))) => Err(motivo),
        _ => Err("No se pudo comprobar con JUSTECNO que quien se conecta es un técnico autorizado. \
                  Revisa el internet de este equipo e intenta de nuevo."
            .to_owned()),
    }
}
