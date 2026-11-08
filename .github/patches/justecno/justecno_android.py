#!/usr/bin/env python3
"""Soporte JUSTECNO: app de clientes para Android más fácil de usar.

Se corre desde la carpeta de rustdesk ya descargada (paso "justecno android" del workflow de Android del fork),
solo para la app de clientes ("Soporte JUSTECNO").

  1. Abre en "Compartir pantalla" y no en el Chat (que sale en blanco hasta que el técnico escribe): la app
     de clientes solo recibe conexiones, así que RustDesk le quita "Conectar" y el Chat quedaba de primero.
  2. Un asistente de 3 pasos, con botones grandes y en palabras simples, para dejar el celular listo:
     compartir la pantalla, dejar que el técnico lo maneje (accesibilidad) y que no se cierre sola
     (batería). Explica cómo desbloquear el "ajuste restringido" de Android 13 o más nuevo, que bloquea
     la accesibilidad de las apps que no vienen de la Play Store, y abre esa pantalla con un toque.
  3. Quita el aviso de "estafas" de RustDesk (la app solo acepta técnicos de JUSTECNO).
  4. Actualización obligatoria: lee la versión publicada (rustdesk.justecno.com/app-api/v1/version,
     plataformas.android). Si hay una nueva, muestra una tarjeta; si el build de esta app es menor que el
     "minimo", un aviso que no se cierra hasta actualizar. "Actualizar ahora" abre el .apk de este celular
     (arm64 o armv7) y Android lo descarga e instala encima (misma firma: conserva el ID).
     El build sale de JUSTECNO_BUILD (número de ejecución del workflow); sin él no bloquea nunca.

Falla a propósito si una versión nueva de RustDesk cambia las líneas donde se engancha.
"""
import os
import sys

INICIO = "flutter/lib/mobile/pages/home_page.dart"
SERVIDOR = "flutter/lib/mobile/pages/server_page.dart"

IMPORTS = ("import 'dart:async';\n",
           "import 'dart:async';\n"
           "import 'dart:convert' as jtconv; // Soporte JUSTECNO\n"
           "import 'package:device_info_plus/device_info_plus.dart' as jtdev;\n"
           "import 'package:http/http.dart' as jthttp;\n"
           "import 'package:url_launcher/url_launcher.dart' as jturl;\n")

ACTUALIZACION = r"""

// ---------------------------------------------------------------------------------------------------
// Soporte JUSTECNO: aviso de versión nueva; si la versión ya no se permite, bloquea hasta actualizar.
// ---------------------------------------------------------------------------------------------------
const int kJtBuild = 0; // el workflow pone aquí JUSTECNO_BUILD
const String _kJtVersionUrl = 'https://rustdesk.justecno.com/app-api/v1/version';
const String _kJtDescargas = 'https://soporte.justecno.com/descargas/';

class JtActualizacion extends StatefulWidget {
  const JtActualizacion({Key? key}) : super(key: key);

  @override
  State<JtActualizacion> createState() => _JtActualizacionState();
}

class _JtActualizacionState extends State<JtActualizacion>
    with WidgetsBindingObserver {
  // la tarjeta y el aviso de bloqueo usan el mismo estado (no se libera: el aviso puede seguir abierto)
  final ValueNotifier<int> _cambio = ValueNotifier<int>(0);
  Timer? _timer;
  bool _nueva = false;
  bool _obligatoria = false;
  bool _bloqueo = false;
  String _version = '';
  String _archivo = '';
  String _pagina = 'https://soporte.justecno.com/soporte/';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.delayed(const Duration(seconds: 3), _revisar);
    _timer = Timer.periodic(const Duration(hours: 6), (_) => _revisar());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _revisar();
  }

  Future<void> _revisar() async {
    try {
      final r = await jthttp.get(Uri.parse(_kJtVersionUrl), headers: {
        'User-Agent': 'SoporteJUSTECNO-Android (build $kJtBuild)',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return;
      final d = jtconv.jsonDecode(jtconv.utf8.decode(r.bodyBytes));
      if (d is! Map) return;
      final ps = d['plataformas'];
      if (ps is! Map) return;
      final p = ps['android'];
      if (p is! Map) return;
      final build = p['build'];
      if (build is! int) return;
      final minimo = p['minimo'];
      var arm64 = true;
      try {
        final info = await jtdev.DeviceInfoPlugin().androidInfo;
        arm64 = info.supported64BitAbis.contains('arm64-v8a');
      } catch (_) {}
      final sufijo = arm64 ? '-arm64.apk' : '-armv7.apk';
      var archivo = '';
      final lista = p['archivos'];
      if (lista is List) {
        for (final a in lista) {
          final n = a is Map ? a['archivo'] : null;
          if (n is String && n.endsWith(sufijo)) {
            archivo = n;
            break;
          }
        }
      }
      if (!RegExp(r'^android/[A-Za-z0-9._-]+\.apk$').hasMatch(archivo)) {
        archivo = '';
      }
      final pagina = d['pagina'];
      final version = p['version'];
      if (!mounted) return;
      setState(() {
        _nueva = build > kJtBuild;
        _obligatoria =
            _nueva && kJtBuild > 0 && minimo is int && kJtBuild < minimo;
        _archivo = archivo;
        _version = version is String ? version : '';
        if (pagina is String && pagina.startsWith('https://')) _pagina = pagina;
      });
      _cambio.value++;
      if (_obligatoria) _mostrarBloqueo();
    } catch (_) {
      // sin internet: no se muestra nada (nunca bloquea sin respuesta del servidor)
    }
  }

  Future<void> _actualizar() async {
    final url = _archivo.isNotEmpty ? '$_kJtDescargas$_archivo' : _pagina;
    try {
      await jturl.launchUrl(Uri.parse(url),
          mode: jturl.LaunchMode.externalApplication);
    } catch (_) {}
  }

  static const String _pasos =
      'Toca «Actualizar ahora». Se descarga la versión nueva; cuando termine, toca «Abrir» y '
      'luego «Actualizar» (o «Instalar»). Si Android dice que la app no es segura, toca '
      '«Más detalles» y «Instalar de todas formas». Tu ID se conserva.';

  void _mostrarBloqueo() {
    if (_bloqueo || !mounted) return;
    _bloqueo = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Actualiza la app para seguir'),
          content: ValueListenableBuilder<int>(
            valueListenable: _cambio,
            builder: (_, __, ___) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _obligatoria
                  ? [
                      Text(
                          'Esta versión de Soporte JUSTECNO ya no se puede usar. '
                          'Instala la nueva${_version.isNotEmpty ? ' ($_version)' : ''} para seguir.',
                          style: const TextStyle(fontSize: 15)),
                      const SizedBox(height: 10),
                      const Text(_pasos, style: TextStyle(fontSize: 14)),
                      const SizedBox(height: 14),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12)),
                        onPressed: _actualizar,
                        child: const Text('Actualizar ahora',
                            style: TextStyle(fontSize: 16)),
                      ),
                    ]
                  : [
                      const Text('¡Listo! Ya puedes seguir usando la app.',
                          style: TextStyle(fontSize: 15)),
                      const SizedBox(height: 14),
                      ElevatedButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Continuar'),
                      ),
                    ],
            ),
          ),
        ),
      ),
    ).whenComplete(() => _bloqueo = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_nueva) return const SizedBox.shrink();
    return PaddingCard(
      title: _obligatoria
          ? 'Esta versión ya no se puede usar'
          : 'Hay una versión nueva de la app',
      titleIcon: const Icon(Icons.system_update, color: Color(0xff0071ff)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text(_pasos, style: TextStyle(fontSize: 14)),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12)),
            onPressed: _actualizar,
            child:
                const Text('Actualizar ahora', style: TextStyle(fontSize: 16)),
          ),
        ),
      ]),
    );
  }
}
"""

ASISTENTE = r"""

// ---------------------------------------------------------------------------------------------------
// Soporte JUSTECNO: asistente para dejar el celular listo, paso a paso y en palabras simples.
// ---------------------------------------------------------------------------------------------------
class JtAsistente extends StatefulWidget {
  const JtAsistente({Key? key}) : super(key: key);

  @override
  State<JtAsistente> createState() => _JtAsistenteState();
}

class _JtAsistenteState extends State<JtAsistente> with WidgetsBindingObserver {
  bool _bateria = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // la app solo acepta técnicos de JUSTECNO: el aviso de estafas de RustDesk solo confunde
    bind.mainSetLocalOption(key: "show-scam-warning", value: "N");
    _revisar();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _revisar());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      gFFI.serverModel.checkAndroidPermission();
      _revisar();
    }
  }

  Future<void> _revisar() async {
    final b = await AndroidPermissionManager.check(
        kRequestIgnoreBatteryOptimizations);
    if (mounted && b != _bateria) {
      setState(() => _bateria = b);
    }
  }

  void _ayudaRestringido() {
    gFFI.dialogManager.show((setState, close, context) => CustomAlertDialog(
          title: const Text('Desbloquear el permiso'),
          content: const Text(
              'Android bloquea este permiso en las apps que no vienen de la Play Store. '
              'Se desbloquea así:\n\n'
              '1. Primero toca «Abrir ajustes» en el paso 2 e intenta activarlo una vez '
              '(saldrá el aviso de «Configuración restringida»). Vuelve aquí.\n'
              '2. Toca «Abrir información de la app».\n'
              '3. Toca los tres puntos ⋮ de arriba a la derecha.\n'
              '4. Toca «Permitir configuración restringida» y confirma con tu huella o PIN.\n'
              '5. Vuelve aquí y toca otra vez «Abrir ajustes» en el paso 2.'),
          actions: [
            dialogButton('Cerrar', onPressed: () => close(), isOutline: true),
            dialogButton('Abrir información de la app', onPressed: () {
              close();
              AndroidPermissionManager.startAction(
                  kActionApplicationDetailsSettings);
            }),
          ],
        ));
  }

  Widget _paso(int n, String titulo, String texto, bool listo, String boton,
      VoidCallback accion,
      {Widget? extra}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CircleAvatar(
          radius: 15,
          backgroundColor: listo ? Colors.green : const Color(0xff0071ff),
          child: listo
              ? const Icon(Icons.check, size: 18, color: Colors.white)
              : Text('$n',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(titulo,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 3),
            Text(listo ? 'Listo' : texto,
                style: TextStyle(
                    fontSize: 14,
                    color: listo ? Colors.green : MyTheme.darkGray)),
            if (!listo) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12)),
                  onPressed: accion,
                  child: Text(boton, style: const TextStyle(fontSize: 16)),
                ),
              ),
              if (extra != null) extra,
            ],
          ]),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = Provider.of<ServerModel>(context);
    final pantalla = m.isStart && m.mediaOk;
    final control = m.inputOk;
    if (pantalla && control && _bateria) {
      return const PaddingCard(
        title: '¡Tu celular está listo!',
        titleIcon: Icon(Icons.verified, color: Colors.green),
        child: Text(
            'Dale a tu técnico de JUSTECNO el número de ID que ves abajo y acepta la '
            'conexión cuando aparezca el aviso. Puedes salir de la app: queda lista en '
            'segundo plano.',
            style: TextStyle(fontSize: 15)),
      );
    }
    return PaddingCard(
      title: 'Prepara tu celular',
      titleIcon: const Icon(Icons.support_agent, color: Color(0xff0071ff)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text(
                'Son 3 pasos y solo se hacen una vez. El técnico de JUSTECNO solo podrá '
                'ver y manejar tu celular cuando tú aceptes la conexión.',
                style: TextStyle(fontSize: 14))
            .marginOnly(bottom: 16),
        _paso(
            1,
            'Compartir la pantalla',
            'Toca «Activar», luego «Aceptar» y, en el aviso del celular, «Empezar ahora» '
                '(o «Iniciar»). Si pregunta qué compartir, elige «Toda la pantalla».',
            pantalla,
            'Activar',
            () => m.isStart ? m.checkAndroidPermission() : m.toggleService()),
        _paso(
            2,
            'Dejar que el técnico maneje el celular',
            'Se abren los Ajustes del celular: busca «JUSTECNO Input» (a veces está dentro '
                'de «Apps instaladas» o «Servicios descargados»), actívalo y toca «Permitir». '
                'Luego vuelve a esta app.',
            control,
            'Abrir ajustes',
            () => m.toggleInput(),
            extra: TextButton(
                onPressed: _ayudaRestringido,
                child: const Text(
                    '¿Sale gris, dice «Configuración restringida» o no te deja activarlo? Toca aquí'))),
        _paso(
            3,
            'Que la app no se cierre sola',
            'Toca «Permitir» para que el celular no apague la app mientras te ayudamos.',
            _bateria,
            'Permitir', () async {
          await AndroidPermissionManager.request(
              kRequestIgnoreBatteryOptimizations);
          _revisar();
        }),
      ]),
    );
  }
}
"""

CAMBIOS = [
    # la pantalla de compartir va primero (antes estaba el Chat, que sale vacío)
    (INICIO,
     "      _chatPageTabIndex = _pages.length;\n"
     "      _pages.addAll([ChatPage(type: ChatPageType.mobileMain), ServerPage()]);\n",
     "      // Soporte JUSTECNO: primero \"Compartir pantalla\"; el Chat sale vacío hasta que el técnico escribe\n"
     "      _chatPageTabIndex = _pages.length + 1;\n"
     "      _pages.addAll([ServerPage(), ChatPage(type: ChatPageType.mobileMain)]);\n"),
    # el asistente arriba; el aviso "el servicio no está corriendo" sobra (es el paso 1)
    (SERVIDOR,
     "                        buildPresetPasswordWarningMobile(),\n"
     "                        gFFI.serverModel.isStart\n"
     "                            ? ServerInfo()\n"
     "                            : ServiceNotRunningNotification(),\n",
     "                        buildPresetPasswordWarningMobile(),\n"
     "                        const JtActualizacion(), // Soporte JUSTECNO\n"
     "                        const JtAsistente(),\n"
     "                        gFFI.serverModel.isStart\n"
     "                            ? ServerInfo()\n"
     "                            : const SizedBox.shrink(),\n"),
]


def main():
    t = open(SERVIDOR, encoding="utf-8").read()
    if "class JtAsistente" in t:
        print("justecno_android: ya estaba")
        return
    textos = {}
    for ruta, viejo, nuevo in CAMBIOS:
        t = textos.get(ruta) or open(ruta, encoding="utf-8").read()
        if t.count(viejo) != 1:
            sys.exit(f"justecno_android: no encontré exactamente una vez {viejo[:70]!r} en {ruta}")
        textos[ruta] = t.replace(viejo, nuevo)
    viejo, nuevo = IMPORTS
    if textos[SERVIDOR].count(viejo) != 1:
        sys.exit(f"justecno_android: no encontré exactamente una vez {viejo!r} en {SERVIDOR}")
    build = int(os.environ.get("JUSTECNO_BUILD") or 0)
    actualizacion = ACTUALIZACION.replace("const int kJtBuild = 0;", f"const int kJtBuild = {build};")
    textos[SERVIDOR] = textos[SERVIDOR].replace(viejo, nuevo) + actualizacion + ASISTENTE
    for ruta, t in textos.items():
        open(ruta, "w", encoding="utf-8").write(t)
    print(f"justecno_android: inicio en Compartir pantalla, asistente de permisos y actualización (build {build})")


if __name__ == "__main__":
    main()
