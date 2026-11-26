#!/usr/bin/env python3
"""Soporte JUSTECNO: a los clientes solo se conectan técnicos de JUSTECNO, desde JUSTECNO Técnico instalado.

Se corre desde la carpeta de rustdesk ya descargada (paso "justecno tecnicos" de los workflows del fork), en las
dos apps. El código decide en cada app qué hacer (src/hbbs_http/justecno_tecnicos.rs, que se baja del fork):
  - JUSTECNO Técnico: al conectarse pide un "pase" al servidor de JUSTECNO y lo usa como número de sesión.
  - Soporte JUSTECNO (clientes): antes de aceptar una conexión, pregunta al servidor si ese técnico tiene un pase
    para este equipo; si no, la rechaza y le dice al técnico por qué.

También (en las cuatro plataformas y las dos apps) pone la Cuenta JUSTECNO dentro de la app
(flutter/lib/common/widgets/justecno_cuenta.dart, que usan las tarjetas de PC y la pantalla de Android) y, en el
cliente, antes de aceptar a un técnico pide el PIN, la huella o la cara (ServerModel.sendLoginResponse). Para eso
agrega a pubspec.yaml local_auth_windows y local_auth_darwin (versiones fijas, compatibles con Flutter 3.24).

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


PUBSPEC = "flutter/pubspec.yaml"
SERVER_MODEL = "flutter/lib/models/server_model.dart"
CUENTA = "flutter/lib/common/widgets/justecno_cuenta.dart"
DEPENDENCIAS = ("  http: ^1.1.0\n",
                "  http: ^1.1.0\n"
                "  # Soporte JUSTECNO: PIN, huella o cara (Windows Hello, Touch ID); fijas para Flutter 3.24\n"
                "  local_auth_platform_interface: 1.0.10\n"
                "  local_auth_windows: 1.0.11\n"
                "  local_auth_darwin: 1.4.3\n")
CAMBIOS_CUENTA = [
    (SERVER_MODEL, "import '../common.dart';\n",
     "import '../common.dart';\nimport '../common/widgets/justecno_cuenta.dart'; // Soporte JUSTECNO\n"),
    # antes de dejar entrar al técnico, el cliente confirma que es él (PIN, huella, cara o código al correo)
    (SERVER_MODEL,
     "  void sendLoginResponse(Client client, bool res) async {\n    if (res) {\n",
     "  void sendLoginResponse(Client client, bool res) async {\n"
     "    // Soporte JUSTECNO: el cliente confirma que es él con el PIN, la huella o la cara\n"
     "    if (res && !await jtAutorizarConexion()) return;\n"
     "    if (res) {\n"),
    # «Permitir que un técnico entre sin que estés»: mientras dure, se acepta solo (solo PC)
    (SERVER_MODEL,
     "      if (isAndroid && !client.authorized) showLoginDialog(client);\n",
     "      // Soporte JUSTECNO: acceso sin estar presente, por unas horas\n"
     "      if (isDesktop && !client.authorized) {\n"
     "        jtAccesoVigente().then((si) {\n"
     "          if (si && !client.authorized) sendLoginResponse(client, true);\n"
     "        });\n"
     "      }\n"
     "      if (isAndroid && !client.authorized) showLoginDialog(client);\n"),
]


def bajar(nombre):
    local = os.path.join(os.path.dirname(os.path.abspath(__file__)), nombre)
    if os.path.exists(local):
        return open(local, "rb").read()
    url = (f"https://raw.githubusercontent.com/{os.environ['GITHUB_REPOSITORY']}/{os.environ['GITHUB_SHA']}"
           f"/.github/patches/justecno/{nombre}")
    return urllib.request.urlopen(url, timeout=60).read()


def cuenta():
    if os.path.exists(CUENTA):
        print("justecno_cuenta: ya estaba")
        return
    dart = bajar("justecno_cuenta.dart").decode("utf-8")
    viejo = "const String kJtVariante = 'clientes';"
    if dart.count(viejo) != 1 or "Future<bool> jtAutorizarConexion()" not in dart:
        sys.exit("justecno_cuenta: justecno_cuenta.dart no es el esperado")
    variante = "tecnicos" if os.environ.get("appname") == "JUSTECNO-Tecnico" else "clientes"
    dart = dart.replace(viejo, f"const String kJtVariante = '{variante}';")
    textos = {}
    for ruta, viejo, nuevo in CAMBIOS_CUENTA + [(PUBSPEC,) + DEPENDENCIAS]:
        t = textos.get(ruta) or open(ruta, encoding="utf-8").read()
        if t.count(viejo) != 1:
            sys.exit(f"justecno_cuenta: no encontré exactamente una vez {viejo[:70]!r} en {ruta}")
        textos[ruta] = t.replace(viejo, nuevo)
    for ruta, t in textos.items():
        open(ruta, "w", encoding="utf-8").write(t)
    os.makedirs(os.path.dirname(CUENTA), exist_ok=True)
    open(CUENTA, "w", encoding="utf-8").write(dart)
    print(f"justecno_cuenta: Cuenta JUSTECNO en la app y confirmación con PIN, huella o cara ({variante})")


def main():
    cuenta()
    if os.path.exists(MODULO):
        print("justecno_tecnicos: ya estaba")
        return
    textos = {}
    for ruta, viejo, nuevo in CAMBIOS:
        t = textos.get(ruta) or open(ruta, encoding="utf-8").read()
        if t.count(viejo) != 1:
            sys.exit(f"justecno_tecnicos: no encontré exactamente una vez {viejo[:70]!r} en {ruta}")
        textos[ruta] = t.replace(viejo, nuevo)
    rust = bajar("justecno_tecnicos.rs")
    if b"pub fn pase(" not in rust:
        sys.exit("justecno_tecnicos: justecno_tecnicos.rs no es el esperado")
    for ruta, t in textos.items():
        open(ruta, "w", encoding="utf-8").write(t)
    open(MODULO, "wb").write(rust)
    print("justecno_tecnicos: pase del técnico y verificación en el cliente agregados")


if __name__ == "__main__":
    main()
