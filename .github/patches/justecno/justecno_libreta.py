#!/usr/bin/env python3
"""Soporte JUSTECNO: una sola libreta de direcciones en la app.

Cuando la cuenta ve una libreta compartida («Clientes JUSTECNO», con todos los equipos), la app ya no muestra
«Mi libreta de direcciones» (la personal, vacía) en la lista y abre directo la compartida. Si la cuenta no tiene
ninguna compartida, todo queda como siempre.

Se corre desde la carpeta de rustdesk ya descargada. Falla a propósito si una versión nueva de RustDesk cambia
las líneas donde se engancha.
"""
import sys

AB = "flutter/lib/models/ab_model.dart"

CAMBIOS = [
    # la lista de libretas (menú de la pestaña y "Agregar a la libreta") sin la personal si hay compartidas
    ("  List<String> addressBookNames() {\n    return addressbooks.keys.toList();\n  }\n",
     "  List<String> addressBookNames() {\n"
     "    // Soporte JUSTECNO: una sola libreta (la compartida) cuando la cuenta tiene una\n"
     "    final nombres = addressbooks.keys.toList();\n"
     "    if (nombres.length > 1) nombres.remove(_personalAddressBookName);\n"
     "    return nombres;\n"
     "  }\n"),
    # al cargar, abrir la compartida en vez de la personal
    ("        // pull current address book\n        await current.pullAb(quiet: quiet);\n",
     "        // Soporte JUSTECNO: abrir la libreta compartida, no la personal\n"
     "        if (_currentName.value == _personalAddressBookName && addressbooks.length > 1) {\n"
     "          _currentName.value = addressbooks.keys\n"
     "              .firstWhere((k) => k != _personalAddressBookName);\n"
     "        }\n"
     "        // pull current address book\n        await current.pullAb(quiet: quiet);\n"),
]


def main():
    with open(AB, encoding="utf-8") as f:
        t = f.read()
    for viejo, nuevo in CAMBIOS:
        if t.count(viejo) != 1:
            sys.exit("justecno_libreta: %s cambió (no encontré: %r)" % (AB, viejo[:60]))
        t = t.replace(viejo, nuevo, 1)
    with open(AB, "w", encoding="utf-8", newline="") as f:
        f.write(t)
    print("justecno_libreta: una sola libreta")


if __name__ == "__main__":
    main()
