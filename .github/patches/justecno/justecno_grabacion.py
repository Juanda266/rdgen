#!/usr/bin/env python3
"""Soporte JUSTECNO: graba cada sesión en el equipo del cliente y la sube EN VIVO al servidor de JUSTECNO.

Se corre desde la carpeta de rustdesk ya descargada (paso "justecno grabacion" de los workflows del fork),
solo para la app de clientes ("Soporte JUSTECNO"). La opción allow-auto-record-incoming=Y la fija la
configuración (override), así que el cliente no la puede apagar.

RustDesk ya trae el código para subir las grabaciones mientras se hacen (src/hbbs_http/record_upload.rs),
pero en la versión gratuita nunca se activa. Aquí:
  1. se activa siempre y se manda a https://justecno.com/jt-grabaciones (servicio justecno-grabaciones);
  2. si se cae el internet, ya no se rinde: reintenta cada segundo y el servidor completa lo que falte;
  3. sube en pedazos de 32 MB como mucho (Cloudflare no deja pasar más de 100 MB por petición);
  4. al terminar, cuando el servidor ya tiene todo, borra la grabación del equipo del cliente;
  5. la ventana de conexión del cliente avisa "Esta sesión se graba por seguridad";
  6. también sube lo que pasa por la terminal (lo que escribe el técnico y lo que responde el equipo) y una
     copia de cada archivo que se transfiere (src/hbbs_http/justecno_registro.rs, que se baja del fork).

Falla a propósito si una versión nueva de RustDesk cambia las líneas donde se engancha.
"""
import os
import sys
import urllib.request

SUBIDA = "src/hbbs_http/record_upload.rs"
CM_PC = "flutter/lib/desktop/pages/server_page.dart"
CM_MOVIL = "flutter/lib/mobile/pages/server_page.dart"
URL = "https://justecno.com/jt-grabaciones"
HBBS = "src/hbbs_http.rs"
CONEXION = "src/server/connection.rs"
TERMINAL = "src/server/terminal_service.rs"
REGISTRO = "src/hbbs_http/justecno_registro.rs"
AVISO = "Esta sesión se graba por seguridad"

CAMBIOS = [
    (SUBIDA,
     "pub fn is_enable() -> bool {\n    ENABLE.lock().unwrap().clone()\n}",
     "pub fn is_enable() -> bool {\n"
     "    // Soporte JUSTECNO: siempre se suben las grabaciones al servidor de JUSTECNO.\n"
     "    let _ = ENABLE.lock().unwrap().clone();\n"
     "    true\n"
     "}"),
    (SUBIDA,
     "        let api_server = crate::get_api_server(\n"
     "            Config::get_option(\"api-server\"),\n"
     "            Config::get_option(\"custom-rendezvous-server\"),\n"
     "        );\n",
     f"        let _ = Config::get_option(\"api-server\");\n"
     f"        let api_server = \"{URL}\".to_owned(); // Soporte JUSTECNO\n"),
    # si una petición falla, no se detiene la subida: se reintenta a los 15 s con todo lo pendiente
    (SUBIDA,
     "                uploader.running = false;\n                log::error!(\"upload stop: {}\", e);\n",
     "                uploader.last_send = Instant::now() + Duration::from_secs(15);\n"
     "                log::error!(\"upload error, se reintenta: {}\", e);\n"),
    # una respuesta que no es del servicio (p. ej. página de error de Cloudflare) cuenta como falla
    (SUBIDA,
     "            Ok(resp) => {\n                if let Ok(m) = resp.json::<Map<String, serde_json::Value>>() {\n",
     "            Ok(resp) => {\n"
     "                if resp.status().is_server_error() || resp.status().is_redirection() {\n"
     "                    bail!(\"HTTP {}\", resp.status());\n"
     "                }\n"
     "                if let Ok(m) = resp.json::<Map<String, serde_json::Value>>() {\n"),
    # pedazos de 32 MB como mucho, y contar exactamente lo que se mandó
    (SUBIDA,
     "                        Ok(_) => match file.read_to_end(&mut buf) {\n",
     "                        Ok(_) => match (&mut file).take(MAX_PART).read_to_end(&mut buf) {\n"),
    (SUBIDA,
     "                                self.upload_size = len;\n",
     "                                self.upload_size += length as u64;\n"),
    (SUBIDA,
     "const SHOULD_SEND_SIZE: u64 = 1024 * 1024;\n",
     "const SHOULD_SEND_SIZE: u64 = 1024 * 1024;\n"
     "const MAX_PART: u64 = 32 * 1024 * 1024; // Soporte JUSTECNO\n"),
    # al cerrar: mandar todo lo que falte (con reintentos), la cabecera final y borrar la copia local
    (SUBIDA,
     "    fn handle_tail(&mut self) -> ResultType<()> {\n        self.handle_frame(true)?;\n",
     "    fn handle_tail(&mut self) -> ResultType<()> {\n"
     "        // Soporte JUSTECNO: se sube todo lo que falte antes de la cabecera, con reintentos.\n"
     "        let mut fallos = 0u32;\n"
     "        loop {\n"
     "            let total = std::fs::metadata(&self.filepath).map(|m| m.len()).unwrap_or(0);\n"
     "            if self.upload_size >= total {\n"
     "                break;\n"
     "            }\n"
     "            let antes = self.upload_size;\n"
     "            if let Err(e) = self.handle_frame(true) {\n"
     "                fallos += 1;\n"
     "                if fallos > 8 {\n"
     "                    return Err(e);\n"
     "                }\n"
     "                std::thread::sleep(Duration::from_secs(2u64 << fallos.min(4)));\n"
     "            } else if self.upload_size == antes {\n"
     "                break;\n"
     "            }\n"
     "        }\n"),
    (SUBIDA,
     "                        self.send(\n"
     "                            &[\n"
     "                                (\"type\", \"tail\"),\n"
     "                                (\"file\", &self.filename),\n"
     "                                (\"offset\", \"0\"),\n"
     "                                (\"length\", &length.to_string()),\n"
     "                            ],\n"
     "                            buf,\n"
     "                        )?;\n"
     "                        log::info!(\"upload success, file: {}\", self.filename);\n",
     "                        let mut intento = 0u32;\n"
     "                        loop {\n"
     "                            match self.send(\n"
     "                                &[\n"
     "                                    (\"type\", \"tail\"),\n"
     "                                    (\"file\", &self.filename),\n"
     "                                    (\"offset\", \"0\"),\n"
     "                                    (\"length\", &length.to_string()),\n"
     "                                ],\n"
     "                                buf.clone(),\n"
     "                            ) {\n"
     "                                Ok(()) => break,\n"
     "                                Err(e) if intento < 6 => {\n"
     "                                    intento += 1;\n"
     "                                    log::error!(\"upload tail error, se reintenta: {}\", e);\n"
     "                                    std::thread::sleep(Duration::from_secs(2u64 << intento.min(4)));\n"
     "                                }\n"
     "                                Err(e) => return Err(e),\n"
     "                            }\n"
     "                        }\n"
     "                        log::info!(\"upload success, file: {}\", self.filename);\n"
     "                        // Soporte JUSTECNO: el servidor ya la tiene completa; se borra del equipo.\n"
     "                        drop(file);\n"
     "                        for _ in 0..5 {\n"
     "                            if std::fs::remove_file(&self.filepath).is_ok() {\n"
     "                                break;\n"
     "                            }\n"
     "                            std::thread::sleep(Duration::from_secs(3));\n"
     "                        }\n"),
    # registro de terminal y archivos
    (HBBS, "pub mod record_upload;\n", "pub mod record_upload;\npub mod justecno_registro; // Soporte JUSTECNO\n"),
    (CONEXION,
     "        if self.server_audit_file.is_empty() {\n",
     "        // Soporte JUSTECNO: lista y copia de los archivos transferidos\n"
     "        crate::hbbs_http::justecno_registro::archivos(\n"
     "            matches!(r#type, FileAuditType::RemoteSend),\n"
     "            path,\n"
     "            &files,\n"
     "        );\n"
     "        if self.server_audit_file.is_empty() {\n"),
    (TERMINAL,
     "        data: &TerminalData,\n    ) -> Result<Option<TerminalResponse>> {\n",
     "        data: &TerminalData,\n    ) -> Result<Option<TerminalResponse>> {\n"
     "        // Soporte JUSTECNO: lo que escribe el técnico\n"
     "        if data.compressed {\n"
     "            crate::hbbs_http::justecno_registro::terminal(\n"
     "                true,\n"
     "                data.terminal_id,\n"
     "                &hbb_common::compress::decompress(&data.data),\n"
     "            );\n"
     "        } else {\n"
     "            crate::hbbs_http::justecno_registro::terminal(true, data.terminal_id, &data.data);\n"
     "        }\n"),
    (TERMINAL,
     "    fn create_terminal_data_response(terminal_id: i32, data: Vec<u8>) -> TerminalResponse {\n",
     "    fn create_terminal_data_response(terminal_id: i32, data: Vec<u8>) -> TerminalResponse {\n"
     "        // Soporte JUSTECNO: lo que responde el equipo\n"
     "        crate::hbbs_http::justecno_registro::terminal(false, terminal_id, &data);\n"),
    # aviso al cliente en la ventana de conexión (PC)
    (CM_PC,
     "                SizedBox(height: 10.0),\n                FittedBox(\n                    child: Row(\n",
     "                if (client.type_() == ClientType.remote ||\n"
     "                    client.type_() == ClientType.camera)\n"
     "                  FittedBox(\n"
     "                    child: Text(\n"
     f"                      '{AVISO}',\n"
     "                      style: TextStyle(color: Colors.white, fontSize: 12),\n"
     "                    ),\n"
     "                  ),\n"
     "                SizedBox(height: 10.0),\n                FittedBox(\n                    child: Row(\n"),
    # aviso al cliente (Android)
    (CM_MOVIL,
     "                  client.authorized\n                      ? _buildDisconnectButton(client)\n",
     "                  if (!client.isFileTransfer)\n"
     "                    Text(\n"
     f"                      '{AVISO}',\n"
     "                      style: Theme.of(context).textTheme.bodySmall,\n"
     "                    ).marginOnly(bottom: 5),\n"
     "                  client.authorized\n                      ? _buildDisconnectButton(client)\n"),
]


def main():
    if "Soporte JUSTECNO" in open(SUBIDA, encoding="utf-8").read():
        print("justecno_grabacion: ya estaba")
        return
    textos = {}
    for ruta, viejo, nuevo in CAMBIOS:
        t = textos.get(ruta) or open(ruta, encoding="utf-8").read()
        if t.count(viejo) != 1:
            sys.exit(f"justecno_grabacion: no encontré exactamente una vez {viejo[:70]!r} en {ruta}")
        textos[ruta] = t.replace(viejo, nuevo)
    # el módulo nuevo: junto a este script (pruebas) o del mismo commit del fork (GitHub Actions)
    local = os.path.join(os.path.dirname(os.path.abspath(__file__)), "justecno_registro.rs")
    if os.path.exists(local):
        rust = open(local, "rb").read()
    else:
        url = (f"https://raw.githubusercontent.com/{os.environ['GITHUB_REPOSITORY']}/{os.environ['GITHUB_SHA']}"
               "/.github/patches/justecno/justecno_registro.rs")
        rust = urllib.request.urlopen(url, timeout=60).read()
    if b"pub fn terminal(" not in rust:
        sys.exit("justecno_grabacion: justecno_registro.rs no es el esperado")
    for ruta, t in textos.items():
        open(ruta, "w", encoding="utf-8").write(t)
    open(REGISTRO, "wb").write(rust)
    print("justecno_grabacion: grabación con subida en vivo y aviso al cliente agregados")


if __name__ == "__main__":
    main()
