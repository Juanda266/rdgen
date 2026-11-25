#!/usr/bin/env python3
"""Soporte JUSTECNO: a los clientes solo se conectan técnicos de JUSTECNO, desde JUSTECNO Técnico instalado.

Se corre desde la carpeta de rustdesk ya descargada (paso "justecno tecnicos" de los workflows del fork), en las
dos apps. El código decide en cada app qué hacer (src/hbbs_http/justecno_tecnicos.rs, que se baja del fork):
  - JUSTECNO Técnico: al conectarse pide un "pase" al servidor de JUSTECNO y lo usa como número de sesión.
  - Soporte JUSTECNO (clientes): antes de aceptar una conexión, pregunta al servidor si ese técnico tiene un pase
    para este equipo; si no, la rechaza y le dice al técnico por qué.

Falla a propósito si una versión nueva de RustDesk cambia las líneas donde se engancha.
"""
import os
import sys
import urllib.request

HBBS = "src/hbbs_http.rs"
CLIENTE = "src/client.rs"
CONEXION = "src/server/connection.rs"
MODULO = "src/hbbs_http/justecno_tecnicos.rs"

CAMBIOS = [
    (HBBS, "pub mod record_upload;\n",
     "pub mod record_upload;\npub mod justecno_tecnicos; // Soporte JUSTECNO\n"),
    # el técnico usa como número de sesión el pase que le da el servidor de JUSTECNO
    (CLIENTE,
     "        if sid == 0 {\n            sid = rand::random();\n",
     "        if sid == 0 {\n"
     "            // Soporte JUSTECNO: el pase del servidor (solo en JUSTECNO Técnico)\n"
     "            sid = crate::hbbs_http::justecno_tecnicos::pase(&self.id).unwrap_or_else(rand::random);\n"),
    # el equipo del cliente solo acepta técnicos con pase
    (CONEXION,
     "            if !self.check_id_whitelist().await {\n"
     "                return false;\n"
     "            }\n"
     "            match lr.union {\n",
     "            if !self.check_id_whitelist().await {\n"
     "                return false;\n"
     "            }\n"
     "            // Soporte JUSTECNO: solo técnicos de JUSTECNO aprobados (app JUSTECNO Técnico instalada)\n"
     "            if let Err(motivo) =\n"
     "                crate::hbbs_http::justecno_tecnicos::verificar(&lr.my_id, lr.session_id).await\n"
     "            {\n"
     "                self.send_login_error(motivo).await;\n"
     "                sleep(1.).await;\n"
     "                return false;\n"
     "            }\n"
     "            match lr.union {\n"),
]


def main():
    if os.path.exists(MODULO):
        print("justecno_tecnicos: ya estaba")
        return
    textos = {}
    for ruta, viejo, nuevo in CAMBIOS:
        t = textos.get(ruta) or open(ruta, encoding="utf-8").read()
        if t.count(viejo) != 1:
            sys.exit(f"justecno_tecnicos: no encontré exactamente una vez {viejo[:70]!r} en {ruta}")
        textos[ruta] = t.replace(viejo, nuevo)
    local = os.path.join(os.path.dirname(os.path.abspath(__file__)), "justecno_tecnicos.rs")
    if os.path.exists(local):
        rust = open(local, "rb").read()
    else:
        url = (f"https://raw.githubusercontent.com/{os.environ['GITHUB_REPOSITORY']}/{os.environ['GITHUB_SHA']}"
               "/.github/patches/justecno/justecno_tecnicos.rs")
        rust = urllib.request.urlopen(url, timeout=60).read()
    if b"pub fn pase(" not in rust:
        sys.exit("justecno_tecnicos: justecno_tecnicos.rs no es el esperado")
    for ruta, t in textos.items():
        open(ruta, "w", encoding="utf-8").write(t)
    open(MODULO, "wb").write(rust)
    print("justecno_tecnicos: pase del técnico y verificación en el cliente agregados")


if __name__ == "__main__":
    main()
