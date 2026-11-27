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

// ------------------------------------------------------------------ Corte nocturno de servidores (2026-11-26)
// El servidor de JUSTECNO publica en CORTE_URL el "tiempo límite" (inicio_ts: a esa hora se cierran las sesiones) y la
// hora en que vuelve (fin_ts). Este equipo lo consulta cada 5 minutos (cada minuto en la última hora) y lo recuerda en
// un archivo, por si el servidor ya está apagado. Cada sesión entrante (src/server/connection.rs, reloj de 1 s):
//   - a los 15, 10, 5 y 1 minuto avisa por el chat al técnico y al cliente;
//   - al llegar el tiempo límite se cierra sola, para que la grabación alcance a guardarse antes del apagado.
// Funciona igual si la sesión va directa entre los dos equipos o por el relay. Sin corte publicado, no hace nada.
const CORTE_URL: &str = "https://soporte.justecno.com/wp-json/justecno/v1/mantenimiento";
const CORTE_AVISOS_MIN: [i64; 4] = [1, 5, 10, 15];

static CORTE_HILO: std::sync::Once = std::sync::Once::new();
lazy_static::lazy_static! {
    static ref CORTE: Mutex<Option<(i64, i64)>> = Mutex::new(corte_leer_guardado());
    static ref CORTE_AVISADOS: Mutex<std::collections::HashMap<i32, i64>> = Default::default();
}

fn ahora_s() -> i64 {
    (ahora_ms() / 1000) as i64
}

fn corte_archivo() -> PathBuf {
    std::env::temp_dir().join("justecno-corte.txt")
}

fn corte_leer_guardado() -> Option<(i64, i64)> {
    let t = std::fs::read_to_string(corte_archivo()).ok()?;
    let mut p = t.trim().split(',').map(|x| x.parse::<i64>().ok());
    match (p.next().flatten(), p.next().flatten()) {
        (Some(i), Some(f)) if f > i && f > ahora_s() => Some((i, f)),
        _ => None,
    }
}

fn corte_consultar() -> u64 {
    let r = super::create_http_client_with_url(CORTE_URL)
        .get(CORTE_URL)
        .timeout(Duration::from_secs(20))
        .send()
        .and_then(|r| r.json::<Value>());
    match r {
        // Solo se cree una respuesta del servicio (trae "fase"); si no hay internet o el servidor está apagado,
        // se sigue con lo último que se supo.
        Ok(v) if v.get("fase").is_some() => {
            let nuevo = match (v["inicio_ts"].as_i64(), v["fin_ts"].as_i64()) {
                (Some(i), Some(f)) if f > i => Some((i, f)),
                _ => None,
            };
            if *CORTE.lock().unwrap() != nuevo {
                log::info!("Soporte JUSTECNO: corte de servidores {:?}", nuevo);
            }
            *CORTE.lock().unwrap() = nuevo;
            let _ = std::fs::write(
                corte_archivo(),
                nuevo.map(|(i, f)| format!("{},{}", i, f)).unwrap_or_default(),
            );
        }
        Ok(_) => {}
        Err(e) => log::debug!("Soporte JUSTECNO: no se pudo consultar el corte: {}", e),
    }
    let ahora = ahora_s();
    match *CORTE.lock().unwrap() {
        Some((i, _)) if i > ahora && i - ahora <= 3600 => 60,
        _ => 300,
    }
}

fn corte_iniciar() {
    CORTE_HILO.call_once(|| {
        std::thread::spawn(|| loop {
            let espera = corte_consultar();
            std::thread::sleep(Duration::from_secs(espera));
        });
    });
}

// Hora de Colombia (UTC-5, sin horario de verano), p. ej. "9:45 p. m."
fn corte_hora(t: i64) -> String {
    let s = (t - 5 * 3600).rem_euclid(86400);
    let (h, m) = (s / 3600, s / 60 % 60);
    let h12 = if h % 12 == 0 { 12 } else { h % 12 };
    format!("{}:{:02} {}", h12, m, if h < 12 { "a. m." } else { "p. m." })
}

/// ¿Ya llegó el tiempo límite? (la sesión se cierra)
pub fn corte_ya() -> bool {
    corte_iniciar();
    let ahora = ahora_s();
    matches!(*CORTE.lock().unwrap(), Some((i, f)) if ahora >= i && ahora < f)
}

/// Texto de "tiempo límite" para el chat de la sesión `conn`, una vez por cada aviso (15, 10, 5 y 1 minuto).
pub fn corte_aviso(conn: i32) -> Option<String> {
    corte_iniciar();
    let (ini, fin) = (*CORTE.lock().unwrap())?;
    let faltan = ini - ahora_s();
    let mut avisados = CORTE_AVISADOS.lock().unwrap();
    if faltan <= 0 || faltan > 15 * 60 {
        if faltan <= 0 || avisados.len() > 500 {
            avisados.clear();
        }
        return None;
    }
    let tramo = *CORTE_AVISOS_MIN.iter().find(|m| faltan <= *m * 60)?;
    if avisados.get(&conn).map_or(false, |t| *t <= tramo) {
        return None;
    }
    avisados.insert(conn, tramo);
    let min = (faltan + 59) / 60;
    Some(format!(
        "⏰ Aviso automático de JUSTECNO: tiempo límite a las {}. Queda{} {} minuto{}: a esa hora esta sesión se cierra sola \
         por el corte nocturno de servidores (vuelven a las {}). Terminen y guarden lo que estén haciendo.",
        corte_hora(ini),
        if min == 1 { "" } else { "n" },
        min,
        if min == 1 { "" } else { "s" },
        corte_hora(fin)
    ))
}

/// Motivo de cierre que ve el técnico
pub fn corte_motivo() -> String {
    let fin = (*CORTE.lock().unwrap()).map(|(_, f)| f).unwrap_or(0);
    format!(
        "Sesión cerrada por JUSTECNO: llegó el tiempo límite del corte nocturno de servidores. La grabación quedó guardada. \
         Los servidores vuelven a las {}.",
        corte_hora(fin)
    )
}
