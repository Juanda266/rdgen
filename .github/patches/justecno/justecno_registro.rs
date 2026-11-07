// Soporte JUSTECNO: registro de cada sesión (terminal y archivos) que se sube al servidor de JUSTECNO.
//
// - Terminal: lo que escribe el técnico y lo que responde el equipo, tal cual (bytes en base64).
// - Archivos: cada archivo que el técnico manda al equipo o se lleva de él, con una copia completa.
//
// Todo va a https://justecno.com/jt-grabaciones (servicio justecno-grabaciones), que lo guarda en la carpeta
// de la sesión abierta de este equipo. Si se cae el internet se reintenta; nada de esto frena la sesión.
use hbb_common::{config::Config, lazy_static, log};
use serde_json::{json, Value};
use std::{
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::PathBuf,
    sync::{mpsc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const URL: &str = "https://justecno.com/jt-grabaciones";
const MAX_PENDIENTE: usize = 8 * 1024 * 1024; // eventos guardados mientras no hay internet
const PEDAZO: u64 = 8 * 1024 * 1024;
const MAX_ARCHIVO: u64 = 4 * 1024 * 1024 * 1024;
const ESPERA_RECIBIDO: Duration = Duration::from_secs(2 * 3600);

lazy_static::lazy_static! {
    static ref EVENTOS: Mutex<Option<mpsc::Sender<String>>> = Mutex::new(None);
}

fn ahora_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn cliente() -> reqwest::blocking::Client {
    super::create_http_client_with_url(&format!("{}/estado", URL))
}

fn evento(v: Value) {
    let mut g = match EVENTOS.lock() {
        Ok(g) => g,
        Err(_) => return,
    };
    if g.is_none() {
        let (tx, rx) = mpsc::channel::<String>();
        std::thread::spawn(move || subir_eventos(rx));
        *g = Some(tx);
    }
    if let Some(tx) = g.as_ref() {
        let _ = tx.send(v.to_string());
    }
}

fn subir_eventos(rx: mpsc::Receiver<String>) {
    let client = cliente();
    let mut pendiente = String::new();
    let mut ultimo = Instant::now();
    let mut espera = Duration::from_secs(2);
    loop {
        match rx.recv_timeout(Duration::from_millis(500)) {
            Ok(l) => {
                if pendiente.len() + l.len() < MAX_PENDIENTE {
                    pendiente.push_str(&l);
                    pendiente.push('\n');
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(_) => break,
        }
        if pendiente.is_empty() || ultimo.elapsed() < espera {
            continue;
        }
        ultimo = Instant::now();
        match client
            .post(format!("{}/api/evento", URL))
            .query(&[("equipo", Config::get_id())])
            .body(pendiente.clone())
            .send()
        {
            Ok(r) if r.status().is_success() => {
                pendiente.clear();
                espera = Duration::from_secs(2);
            }
            Ok(r) if r.status().is_client_error() => {
                // el servidor no los quiere (por ejemplo, no hay sesión abierta): no se insiste
                log::warn!("justecno registro rechazado: {}", r.status());
                pendiente.clear();
            }
            Ok(r) => {
                log::warn!("justecno registro, se reintenta: {}", r.status());
                espera = (espera * 2).min(Duration::from_secs(30));
            }
            Err(e) => {
                log::warn!("justecno registro, se reintenta: {}", e);
                espera = (espera * 2).min(Duration::from_secs(30));
            }
        }
    }
}

/// Lo que pasa por la terminal remota. `entrada` = lo que escribe el técnico.
pub fn terminal(entrada: bool, terminal_id: i32, datos: &[u8]) {
    if datos.is_empty() {
        return;
    }
    evento(json!({
        "t": ahora_ms(), "tipo": "terminal", "dir": if entrada { "entrada" } else { "salida" },
        "terminal": terminal_id, "b": crate::encode64(datos),
    }));
}

/// Archivos que salen del equipo hacia el técnico (`enviados`) o que llegan del técnico.
/// `ruta` es la carpeta (o el archivo, si `archivos` trae un solo nombre vacío).
pub fn archivos(enviados: bool, ruta: &str, archivos: &[(String, i64)]) {
    let dir = if enviados { "enviado" } else { "recibido" };
    for (nombre, tam) in archivos {
        evento(json!({"t": ahora_ms(), "tipo": "archivo", "dir": dir, "ruta": ruta,
                      "nombre": nombre, "bytes": tam}));
    }
    if ruta.is_empty() || ruta == "Remote print" {
        return; // copiar y pegar desde el portapapeles: solo queda la lista
    }
    let base = PathBuf::from(ruta);
    let lista: Vec<(PathBuf, String, u64)> = archivos
        .iter()
        .filter(|(_, t)| *t >= 0 && (*t as u64) <= MAX_ARCHIVO)
        .map(|(n, t)| {
            let p = if n.is_empty() { base.clone() } else { base.join(n) };
            let nombre = if n.is_empty() {
                base.file_name().map(|f| f.to_string_lossy().to_string()).unwrap_or_default()
            } else {
                n.clone()
            };
            (p, nombre, *t as u64)
        })
        .collect();
    if lista.is_empty() {
        return;
    }
    let equipo = Config::get_id();
    std::thread::spawn(move || {
        let client = cliente();
        for (p, nombre, tam) in lista {
            if let Err(e) = copiar(&client, &equipo, dir, &p, &nombre, tam) {
                log::warn!("justecno: no se pudo copiar {:?}: {}", p, e);
                evento(json!({"t": ahora_ms(), "tipo": "archivo_falla", "dir": dir,
                              "nombre": nombre, "error": e}));
            }
        }
    });
}

fn copiar(
    client: &reqwest::blocking::Client,
    equipo: &str,
    dir: &str,
    p: &PathBuf,
    nombre: &str,
    tam: u64,
) -> Result<(), String> {
    // lo que llega del técnico se escribe mientras dura la transferencia: se espera a que esté completo
    let inicio = Instant::now();
    let mut quieto = 0;
    let mut anterior = u64::MAX;
    loop {
        let actual = std::fs::metadata(p).map(|m| m.len()).unwrap_or(u64::MAX);
        if actual == tam && actual == anterior {
            quieto += 1;
            if quieto >= 2 {
                break;
            }
        } else {
            quieto = 0;
        }
        anterior = actual;
        if inicio.elapsed() > ESPERA_RECIBIDO {
            return Err("el archivo nunca quedó completo".to_owned());
        }
        std::thread::sleep(Duration::from_secs(3));
    }
    let id = uuid::Uuid::new_v4().to_string();
    let mut f = File::open(p).map_err(|e| e.to_string())?;
    let mut offset = 0u64;
    loop {
        let mut buf = Vec::new();
        f.seek(SeekFrom::Start(offset)).map_err(|e| e.to_string())?;
        (&mut f).take(PEDAZO).read_to_end(&mut buf).map_err(|e| e.to_string())?;
        let mut intento = 0u32;
        loop {
            let r = client
                .post(format!("{}/api/archivo", URL))
                .query(&[
                    ("equipo", equipo.to_owned()),
                    ("id", id.clone()),
                    ("dir", dir.to_owned()),
                    ("nombre", nombre.to_owned()),
                    ("ruta", p.to_string_lossy().to_string()),
                    ("offset", offset.to_string()),
                    ("total", tam.to_string()),
                ])
                .body(buf.clone())
                .send();
            match r {
                Ok(r) if r.status().is_success() => break,
                Ok(r) if r.status().is_client_error() => {
                    return Err(format!("el servidor no lo aceptó ({})", r.status()))
                }
                Ok(r) if intento >= 8 => return Err(format!("HTTP {}", r.status())),
                Err(e) if intento >= 8 => return Err(e.to_string()),
                _ => {
                    intento += 1;
                    std::thread::sleep(Duration::from_secs(2u64 << intento.min(4)));
                }
            }
        }
        offset += buf.len() as u64;
        if buf.is_empty() || offset >= tam {
            return Ok(());
        }
    }
}
