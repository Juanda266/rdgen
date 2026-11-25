#!/usr/bin/env python3
"""Soporte JUSTECNO: la misma versión en la web, en la app y en las propiedades del .exe de Windows.

Regla (la misma que usa justecno-actualizador al publicar):
  - primera compilación con una versión de RustDesk: 1.5.3
  - cada compilación siguiente con la misma versión (cambios de configuración): 1.5.3.1, 1.5.3.2…
  - cuando sale una versión nueva de RustDesk: 1.5.4 (vuelve a empezar)
Lee la versión publicada de esta app (version.json de soporte.justecno.com) para saber cuál sigue.

Cambia solo lo que se ve: el número de RustDesk que usa el protocolo (Cargo.toml "version") no se toca.
  - Cargo.toml y libs/portable/Cargo.toml: ProductVersion y FileVersion (texto) del .exe.
  - build.rs y libs/portable/build.rs: FILEVERSION y PRODUCTVERSION (número) del .exe.
  - Ajustes › Acerca de: la versión que muestra la app (PC y Android).
Falla a propósito si no puede leer version.json o si una versión nueva de RustDesk cambia estas líneas.
"""
import json
import os
import re
import sys
import urllib.request

PLATAFORMA = sys.argv[1] if len(sys.argv) > 1 else "windows"
APP = os.environ.get("appname", "")
TECNICO = os.environ.get("JUSTECNO_APPNAME_TECNICO", "JUSTECNO-Tecnico")
URL = ("https://soporte.justecno.com/descargas/tecnicos/version.json" if APP == TECNICO
       else "https://soporte.justecno.com/descargas/version.json")


def leer(ruta):
    with open(ruta, encoding="utf-8") as f:
        return f.read()


def escribir(ruta, texto):
    with open(ruta, "w", encoding="utf-8", newline="") as f:
        f.write(texto)


def version_rustdesk():
    m = re.search(r'^version = "(\d+)\.(\d+)\.(\d+)"', leer("Cargo.toml"), re.M)
    if not m:
        sys.exit("justecno_version: no encontré la versión en Cargo.toml")
    return tuple(int(x) for x in m.groups())


def revision(base):
    req = urllib.request.Request(URL, headers={"User-Agent": "SoporteJUSTECNO-compilacion"})
    pub = json.load(urllib.request.urlopen(req, timeout=30))
    plat = (pub.get("plataformas") or {}).get(PLATAFORMA) or {}
    if plat.get("rustdesk") == ".".join(map(str, base)):
        return int(plat.get("revision", 0)) + 1
    return 0


def main():
    base = version_rustdesk()
    rev = revision(base)
    visible = ".".join(map(str, base)) + (".%d" % rev if rev else "")
    numero = (base[0] << 48) | (base[1] << 32) | (base[2] << 16) | rev
    print("justecno_version:", APP, PLATAFORMA, "->", visible)

    # Texto de las propiedades del .exe
    for toml in ("Cargo.toml", "libs/portable/Cargo.toml"):
        if not os.path.exists(toml):
            continue
        t = leer(toml)
        if "[package.metadata.winres]" not in t:
            sys.exit("justecno_version: %s sin [package.metadata.winres]" % toml)
        t = re.sub(r'^(ProductVersion|FileVersion)\s*=.*\n', "", t, flags=re.M)
        t = t.replace("[package.metadata.winres]\n",
                      '[package.metadata.winres]\nProductVersion = "%s"\nFileVersion = "%s"\n' % (visible, visible), 1)
        escribir(toml, t)

    # Número de las propiedades del .exe
    ancla = "let mut res = winres::WindowsResource::new();\n"
    for rs in ("build.rs", "libs/portable/build.rs"):
        if not os.path.exists(rs):
            continue
        t = leer(rs)
        if t.count(ancla) != 1:
            sys.exit("justecno_version: %s cambió (no encontré WindowsResource::new)" % rs)
        sangria = re.search(r"^( *)" + re.escape(ancla), t, re.M).group(1)
        extra = ("%sres.set_version_info(winres::VersionInfo::FILEVERSION, %d); // Soporte JUSTECNO\n"
                 "%sres.set_version_info(winres::VersionInfo::PRODUCTVERSION, %d);\n") % (sangria, numero, sangria, numero)
        escribir(rs, t.replace(ancla, ancla + extra, 1))

    # Ajustes › Acerca de
    ajustes = "flutter/lib/desktop/pages/desktop_setting_page.dart"
    if os.path.exists(ajustes):
        t = leer(ajustes)
        viejo = "final version = await bind.mainGetVersion();"
        if t.count(viejo) != 1:
            sys.exit("justecno_version: %s cambió" % ajustes)
        escribir(ajustes, t.replace(viejo, "final version = '%s'; // Soporte JUSTECNO" % visible))

    # Android: Ajustes › Acerca de (si una versión nueva cambia estas líneas, se deja como venía)
    movil = "flutter/lib/mobile/pages/settings_page.dart"
    if os.path.exists(movil):
        t = leer(movil)
        for viejo, nuevo in (('Text(translate("Version: ") + version)', "Text(translate(\"Version: \") + '%s')" % visible),
                             ("Text('Version: $version')", "Text('Version: %s')" % visible)):
            if t.count(viejo) == 1:
                t = t.replace(viejo, nuevo)
            else:
                print("justecno_version: aviso, no encontré %r en %s" % (viejo, movil))
        escribir(movil, t)

    env = os.environ.get("GITHUB_ENV")
    if env:
        with open(env, "a", encoding="utf-8") as f:
            f.write("JUSTECNO_VERSION=%s\n" % visible)


if __name__ == "__main__":
    main()
