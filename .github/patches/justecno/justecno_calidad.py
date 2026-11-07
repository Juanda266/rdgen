#!/usr/bin/env python3
"""Soporte JUSTECNO: menú "Calidad de transmisión" (como el de YouTube) en la barra de la sesión remota.

Se corre desde la carpeta de rustdesk ya descargada (paso "justecno calidad" de los workflows del fork).
Solo cambia la app que controla (la del técnico); el equipo del cliente no necesita nada nuevo: cada opción
le pide al equipo remoto cuántos Mb/s y cuántos cuadros por segundo mandar. La imagen sigue con la
resolución de la pantalla del usuario; lo que baja es la nitidez, como en YouTube.

Falla a propósito si una versión nueva de RustDesk cambia las líneas donde se engancha.
"""
import sys

TOOLBAR = "flutter/lib/common/widgets/toolbar.dart"
BARRA = "flutter/lib/desktop/widgets/remote_toolbar.dart"

DART_MENU = r"""

// ---------------------------------------------------------------------------------------------------
// Soporte JUSTECNO: calidad de transmisión tipo YouTube. Solo cambia los Mb/s y los cuadros por segundo
// que manda el equipo remoto (la imagen sigue del tamaño de su pantalla). "Automática" es la calidad
// "Buena" de RustDesk, que baja sola si el internet (o el servidor de JUSTECNO) se congestiona.
// ---------------------------------------------------------------------------------------------------
const String kJtOpcionCalidad = 'jt-calidad';
const String kJtCalidadAuto = 'auto';
// [valor, texto, kbit/s aproximados, cuadros por segundo]
const List<List<Object>> kJtCalidades = [
  ['1080', '1080p (alta)', 8000, 30],
  ['720', '720p', 3000, 30],
  ['480', '480p', 1200, 30],
  ['360', '360p', 700, 24],
  ['144', '144p (internet muy lento)', 250, 15],
];

// Los kbit/s que RustDesk usa como base para esa pantalla (aprox. de scrap::codec::base_bitrate).
int _jtBase(FFI ffi) {
  final r = ffi.ffiModel.rect;
  final pixeles = r == null ? 1920 * 1080 : (r.width * r.height).toInt();
  return (pixeles / 1000).round().clamp(400, 12000).toInt();
}

Future<void> jtAplicarCalidad(FFI ffi, String valor) async {
  final sessionId = ffi.sessionId;
  await bind.sessionPeerOption(
      sessionId: sessionId, name: kJtOpcionCalidad, value: valor);
  if (valor == kJtCalidadAuto) {
    await bind.sessionSetCustomFps(sessionId: sessionId, fps: 30);
    await bind.sessionSetImageQuality(
        sessionId: sessionId, value: kRemoteImageQualityBest);
    return;
  }
  for (final c in kJtCalidades) {
    if (c[0] != valor) continue;
    // RustDesk: porcentaje personalizado q -> bitrate = base * q * 2 / 100
    final q = ((c[2] as int) * 50 / _jtBase(ffi)).round().clamp(10, 2000).toInt();
    await bind.sessionSetImageQuality(
        sessionId: sessionId, value: kRemoteImageQualityCustom);
    await bind.sessionSetCustomImageQuality(sessionId: sessionId, value: q);
    await bind.sessionSetCustomFps(sessionId: sessionId, fps: c[3] as int);
  }
}

Future<List<TRadioMenu<String>>> toolbarJtCalidad(
    BuildContext context, String id, FFI ffi) async {
  final sessionId = ffi.sessionId;
  final calidad = await bind.sessionGetImageQuality(sessionId: sessionId) ?? '';
  final elegida =
      await bind.sessionGetPeerOption(sessionId: sessionId, name: kJtOpcionCalidad);
  // Si el técnico cambió la calidad desde el menú de RustDesk, no se marca ninguna de estas.
  String grupo = '';
  if (calidad == kRemoteImageQualityBest &&
      (elegida.isEmpty || elegida == kJtCalidadAuto)) {
    grupo = kJtCalidadAuto;
  } else if (calidad == kRemoteImageQualityCustom &&
      kJtCalidades.any((c) => c[0] == elegida)) {
    grupo = elegida;
  }
  onChanged(String? v) async {
    if (v != null) await jtAplicarCalidad(ffi, v);
  }

  return [
    TRadioMenu<String>(
        child: Text('Automática (recomendada)'),
        value: kJtCalidadAuto,
        groupValue: grupo,
        onChanged: onChanged),
    for (final c in kJtCalidades)
      TRadioMenu<String>(
          child: Text(c[1] as String),
          value: c[0] as String,
          groupValue: grupo,
          onChanged: onChanged),
  ];
}
"""

DART_SUBMENU = r"""  // Soporte JUSTECNO: calidad de transmisión tipo YouTube (ver toolbarJtCalidad).
  jtCalidad() {
    return futureBuilder(
        future: toolbarJtCalidad(context, widget.id, widget.ffi),
        hasData: (data) {
          final v = data as List<TRadioMenu<String>>;
          return _SubmenuButton(
            ffi: widget.ffi,
            child: Text('Calidad de transmisión'),
            menuChildren: v
                .map((e) => RdoMenuButton<String>(
                    value: e.value,
                    groupValue: e.groupValue,
                    onChanged: e.onChanged,
                    child: e.child,
                    ffi: ffi))
                .toList(),
          );
        });
  }

"""


def cambiar(ruta, viejo, nuevo):
    t = open(ruta, encoding="utf-8").read()
    if t.count(viejo) != 1:
        sys.exit(f"justecno_calidad: no encontré exactamente una vez {viejo!r} en {ruta}")
    open(ruta, "w", encoding="utf-8").write(t.replace(viejo, nuevo))


def main():
    t = open(TOOLBAR, encoding="utf-8").read()
    if "kJtOpcionCalidad" in t:
        print("justecno_calidad: ya estaba")
        return
    open(TOOLBAR, "a", encoding="utf-8").write(DART_MENU)
    cambiar(BARRA, "        imageQuality(),\n        codec(),\n",
            "        jtCalidad(),\n        imageQuality(),\n        codec(),\n")
    cambiar(BARRA, "  imageQuality() {\n    return futureBuilder(\n        future: toolbarImageQuality(",
            DART_SUBMENU + "  imageQuality() {\n    return futureBuilder(\n        future: toolbarImageQuality(")
    print("justecno_calidad: menú Calidad de transmisión agregado")


if __name__ == "__main__":
    main()
