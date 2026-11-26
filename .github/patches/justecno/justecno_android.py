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
     Desde 1.5.3.2 la app descarga el .apk ella misma y abre el instalador de Android. Si no tiene el permiso
     "Instalar apps desconocidas", abre esa pantalla de Ajustes (solo de esta app); al volver con el permiso
     activado, la actualización sigue sola. Si algo falla, abre la descarga en el navegador como antes.
     (AndroidManifest: REQUEST_INSTALL_PACKAGES y un FileProvider; MainActivity: método "jt_instalar_apk".)
  5. Inicio de sesión con la Cuenta JUSTECNO (como en PC), dentro de la app: correo y código de 6 números, o
     crear la cuenta ahí mismo (common/widgets/justecno_cuenta.dart, lo copia justecno_tecnicos.py). Con sesión,
     al abrir la app y antes de aceptar a un técnico pide el PIN, el patrón, la huella o la cara del celular
     (MainActivity: método "jt_verificar_persona", con la pantalla de bloqueo de Android); sin bloqueo
     configurado, un código al correo de la cuenta.

Falla a propósito si una versión nueva de RustDesk cambia las líneas donde se engancha.
"""
import os
import sys

INICIO = "flutter/lib/mobile/pages/home_page.dart"
SERVIDOR = "flutter/lib/mobile/pages/server_page.dart"

IMPORTS = ("import 'dart:async';\n",
           "import 'dart:async';\n"
           "import 'dart:convert' as jtconv; // Soporte JUSTECNO\n"
           "import 'dart:io' as jtio;\n"
           "import 'package:path_provider/path_provider.dart' as jtpath;\n"
           "import 'package:device_info_plus/device_info_plus.dart' as jtdev;\n"
           "import 'package:http/http.dart' as jthttp;\n"
           "import 'package:url_launcher/url_launcher.dart' as jturl;\n"
           "import '../../common/widgets/justecno_cuenta.dart';\n")

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
  static const String _kInstalar = 'android.permission.REQUEST_INSTALL_PACKAGES';
  bool _esperandoPermiso = false;
  bool _descargando = false;
  double? _progreso;
  String _estado = '';

  void _set(VoidCallback f) {
    if (!mounted) return;
    setState(f);
    _cambio.value++;
  }

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
    if (state == AppLifecycleState.resumed) {
      if (_esperandoPermiso) _seguirTrasPermiso();
      _revisar();
    }
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

  Future<void> _abrirNavegador() async {
    final url = _archivo.isNotEmpty ? '$_kJtDescargas$_archivo' : _pagina;
    try {
      await jturl.launchUrl(Uri.parse(url),
          mode: jturl.LaunchMode.externalApplication);
    } catch (_) {}
  }

  // Descarga e instala desde la app. Sin el permiso "Instalar apps desconocidas", primero abre esa
  // pantalla de Ajustes; al volver con el permiso activado sigue sola (didChangeAppLifecycleState).
  Future<void> _actualizar() async {
    if (_descargando) return;
    if (_archivo.isEmpty) return _abrirNavegador();
    var permitido = false;
    try {
      permitido = await AndroidPermissionManager.check(_kInstalar);
    } catch (_) {}
    if (!permitido) {
      _set(() {
        _esperandoPermiso = true;
        _estado = 'Activa «Permitir de esta fuente» (o «Permitir apps de esta fuente») y vuelve '
            'a esta app: la actualización sigue sola. Si la app se reinicia, toca otra vez '
            '«Actualizar ahora».';
      });
      try {
        AndroidPermissionManager.request(_kInstalar).then((ok) {
          if (ok) _seguirTrasPermiso();
        });
      } catch (_) {
        _set(() => _esperandoPermiso = false);
        await _abrirNavegador();
      }
      return;
    }
    await _descargarEInstalar();
  }

  Future<void> _seguirTrasPermiso() async {
    if (!_esperandoPermiso || _descargando) return;
    var permitido = false;
    try {
      permitido = await AndroidPermissionManager.check(_kInstalar);
    } catch (_) {}
    if (!permitido) return;
    _set(() => _esperandoPermiso = false);
    await _descargarEInstalar();
  }

  Future<void> _descargarEInstalar() async {
    if (_descargando) return;
    _set(() {
      _descargando = true;
      _progreso = null;
      _estado = 'Descargando la versión nueva…';
    });
    try {
      final base = await jtpath.getTemporaryDirectory();
      final dir = jtio.Directory('${base.path}/jt-actualizacion');
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
      final f = jtio.File('${dir.path}/${_archivo.split('/').last}');
      final cliente = jthttp.Client();
      try {
        final resp = await cliente
            .send(jthttp.Request('GET', Uri.parse('$_kJtDescargas$_archivo')))
            .timeout(const Duration(seconds: 30));
        if (resp.statusCode != 200) throw Exception('descarga ${resp.statusCode}');
        final total = resp.contentLength ?? 0;
        var bajado = 0;
        final out = f.openWrite();
        try {
          await for (final c in resp.stream.timeout(const Duration(seconds: 60))) {
            out.add(c);
            bajado += c.length;
            if (total > 0) _set(() => _progreso = bajado / total);
          }
        } finally {
          await out.close();
        }
        if (total > 0 && bajado != total) throw Exception('descarga incompleta');
      } finally {
        cliente.close();
      }
      _set(() {
        _progreso = 1;
        _estado = 'Toca «Actualizar» (o «Instalar») en el aviso de Android. Tu ID se conserva.';
      });
      final ok = await gFFI.invokeMethod('jt_instalar_apk', f.path);
      if (ok != true) throw Exception('instalador');
    } catch (_) {
      _set(() => _estado =
          'No se pudo instalar desde la app. Se abre la descarga en el navegador: cuando termine, '
          'toca «Abrir» y luego «Actualizar».');
      await _abrirNavegador();
    }
    _set(() => _descargando = false);
  }

  static const String _pasos =
      'Toca «Actualizar ahora». La primera vez, Android te pide permitir que esta app instale '
      'actualizaciones: activa «Permitir de esta fuente» y vuelve. Al final toca «Actualizar». '
      'Si Android dice que la app no es segura, toca «Más detalles» y «Instalar de todas formas». '
      'Tu ID se conserva.';

  List<Widget> _progresoWidgets() {
    return [
      if (_estado.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(_estado, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      ],
      if (_descargando) ...[
        const SizedBox(height: 8),
        LinearProgressIndicator(value: _progreso),
      ],
    ];
  }

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
                      ..._progresoWidgets(),
                      const SizedBox(height: 14),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12)),
                        onPressed: _descargando ? null : _actualizar,
                        child: Text(_descargando ? 'Descargando…' : 'Actualizar ahora',
                            style: const TextStyle(fontSize: 16)),
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
        ..._progresoWidgets(),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12)),
            onPressed: _descargando ? null : _actualizar,
            child: Text(_descargando ? 'Descargando…' : 'Actualizar ahora',
                style: const TextStyle(fontSize: 16)),
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

SESION = r"""

// ---------------------------------------------------------------------------------------------------
// Soporte JUSTECNO: iniciar sesión con la Cuenta JUSTECNO (obligatorio para recibir soporte) dentro de la app:
// correo y código, o crear la cuenta ahí mismo (JtCuentaDialogo, en common/widgets/justecno_cuenta.dart).
// Con sesión, al abrir la app (y al volver después de 5 minutos) pide el PIN, el patrón, la huella o la cara.
// Sin red o si el servidor no responde, no bloquea.
// ---------------------------------------------------------------------------------------------------
const String _kJtSesionUrl = 'https://rustdesk.justecno.com/app-api/v1/sesion';

class JtSesion extends StatefulWidget {
  const JtSesion({Key? key}) : super(key: key);

  @override
  State<JtSesion> createState() => _JtSesionState();
}

class _JtSesionState extends State<JtSesion> with WidgetsBindingObserver {
  static const Duration _kBloquearTras = Duration(minutes: 5);
  Timer? _retry;
  int _retries = 0;
  bool _cargado = false;
  bool _conectado = false;
  bool _dialogo = false;
  bool _cerrando = false;
  String _nombre = '';
  String _usuario = '';
  String _mensaje = '';
  DateTime? _fuera;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.delayed(const Duration(seconds: 2), _load);
  }

  @override
  void dispose() {
    _retry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool get _tecnicoConectado =>
      gFFI.serverModel.clients.any((c) => c.authorized && !c.disconnected);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _fuera ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final fuera = _fuera;
      _fuera = null;
      if (fuera != null && DateTime.now().difference(fuera) > _kBloquearTras &&
          !jtVerificadoHace(_kBloquearTras) && !_tecnicoConectado) {
        _desbloquear();
      }
    }
  }

  void _set(VoidCallback f) {
    if (mounted) setState(f);
  }

  Future<void> _load() async {
    final s = await jtSesionActual();
    if (s == null) {
      if (_retries < 60 && mounted) {
        _retries++;
        _retry?.cancel();
        _retry = Timer(const Duration(minutes: 1), _load);
      }
      return;
    }
    _set(() {
      _cargado = true;
      _conectado = s.isNotEmpty;
      _nombre = s['nombre'] ?? '';
      _usuario = s['usuario'] ?? '';
    });
    if (_conectado) {
      await _desbloquear();
    } else {
      await _iniciarSesion();
    }
  }

  Future<void> _iniciarSesion() async {
    if (_dialogo || !mounted || _conectado) return;
    _dialogo = true;
    final c = await jtMostrarInicioSesion(context, celular: true);
    _dialogo = false;
    if (c != null) {
      _set(() {
        _conectado = true;
        _nombre = c['nombre'] ?? '';
        _usuario = c['usuario'] ?? '';
        _mensaje = '¡Listo! Desde ahora, al abrir la app y antes de que entre un técnico, '
            'te pediremos ${jtNombreMetodo()}.';
      });
    }
  }

  Future<void> _desbloquear() async {
    if (_dialogo || !mounted || !_conectado) return;
    _dialogo = true;
    await jtVerificarPersona(context,
        titulo: 'Desbloquea Soporte JUSTECNO',
        motivo: 'Confirma que eres tú para usar Soporte JUSTECNO',
        obligatorio: true,
        fondo: Colors.black.withOpacity(0.92));
    _dialogo = false;
  }

  Future<void> _cerrarSesion() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Cerrar la sesión en este celular?'),
        content: const Text('Los técnicos ya no verán este celular hasta que vuelvas a iniciar sesión.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Cerrar sesión')),
        ],
      ),
    );
    if (ok != true) return;
    _set(() => _cerrando = true);
    final ids = await jtIds();
    var listo = false;
    if (ids != null) {
      try {
        final r = await jthttp
            .post(Uri.parse('$_kJtSesionUrl/cerrar'),
                headers: {
                  'User-Agent': 'SoporteJUSTECNO-Android (build $kJtBuild)',
                  'Accept': 'application/json',
                  'Content-Type': 'application/json; charset=utf-8',
                },
                body: jtconv.jsonEncode(ids))
            .timeout(const Duration(seconds: 15));
        listo = r.statusCode == 200;
      } catch (_) {}
    }
    _set(() {
      _cerrando = false;
      _mensaje = '';
      if (listo) {
        _conectado = false;
        _nombre = '';
        _usuario = '';
      }
    });
    if (listo) _iniciarSesion();
  }

  @override
  Widget build(BuildContext context) {
    if (!_cargado) return const SizedBox.shrink();
    if (!_conectado) {
      return PaddingCard(
        title: 'Inicia sesión para recibir soporte',
        titleIcon: const Icon(Icons.account_circle, color: Color(0xff0071ff)),
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
            onPressed: _iniciarSesion,
            child: const Text('Iniciar sesión', style: TextStyle(fontSize: 16)),
          ),
        ),
      );
    }
    return PaddingCard(
      title: 'Sesión iniciada',
      titleIcon: const Icon(Icons.account_circle, color: Colors.green),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_nombre, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              if (jtUsuarioDistinto(_nombre, _usuario))
                Text('Usuario: $_usuario', style: TextStyle(fontSize: 13, color: MyTheme.darkGray)),
            ]),
          ),
          TextButton(
            onPressed: _cerrando ? null : _cerrarSesion,
            child: Text(_cerrando ? 'Cerrando…' : 'Cerrar sesión'),
          ),
        ]),
        if (_mensaje.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_mensaje, style: TextStyle(fontSize: 13, color: Colors.green.shade700)),
          ),
      ]),
    );
  }
}
"""

MANIFEST = "flutter/android/app/src/main/AndroidManifest.xml"
ACTIVIDAD = "flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/MainActivity.kt"
RUTAS_XML = "flutter/android/app/src/main/res/xml/jt_actualizacion_rutas.xml"

# Instalar la actualización desde la app: la descarga queda en la caché (jt-actualizacion/) y se entrega al
# instalador de Android con un FileProvider propio.
# Confirmar que es la persona: la pantalla de bloqueo del celular (PIN, patrón, contraseña, huella o cara).
# Sin bloqueo configurado responde "sin_bloqueo" y la app usa un código al correo de la cuenta.
VERIFICAR_KT = """                "jt_verificar_persona" -> { // Soporte JUSTECNO: PIN, patrón, huella o cara del celular
                    try {
                        val km = getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
                        @Suppress("DEPRECATION")
                        val seguro = if (Build.VERSION.SDK_INT >= 23) km.isDeviceSecure else km.isKeyguardSecure
                        val i = if (seguro)
                            km.createConfirmDeviceCredentialIntent("Soporte JUSTECNO", call.arguments as? String)
                        else null
                        if (i == null) {
                            result.success("sin_bloqueo")
                        } else {
                            jtVerificacion?.success("cancelado")
                            jtVerificacion = result
                            startActivityForResult(i, JT_REQ_VERIFICAR)
                        }
                    } catch (e: Exception) {
                        result.success("sin_bloqueo")
                    }
                }
"""
VERIFICAR_CAMPO_KT = """    private var pendingPicker: PendingPicker? = null
    // Soporte JUSTECNO: respuesta pendiente de "jt_verificar_persona"
    private var jtVerificacion: MethodChannel.Result? = null
    private val JT_REQ_VERIFICAR = 7311
"""
VERIFICAR_RESULTADO_KT = """        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == JT_REQ_VERIFICAR) { // Soporte JUSTECNO
            jtVerificacion?.success(if (resultCode == Activity.RESULT_OK) "ok" else "cancelado")
            jtVerificacion = null
            return
        }
"""

INSTALAR_KT = """                "jt_instalar_apk" -> { // Soporte JUSTECNO: abrir el instalador con el .apk descargado
                    try {
                        val f = java.io.File(call.arguments as String)
                        val uri = androidx.core.content.FileProvider.getUriForFile(
                            context, context.packageName + ".jtactualizacion", f)
                        val i = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        context.startActivity(i)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
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
     "                        const JtSesion(),\n"
     "                        const JtAsistente(),\n"
     "                        gFFI.serverModel.isStart\n"
     "                            ? ServerInfo()\n"
     "                            : const SizedBox.shrink(),\n"),
    # permiso para instalar actualizaciones y el FileProvider del .apk descargado
    (MANIFEST,
     '    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />\n',
     '    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />\n'
     '    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" /> <!-- Soporte JUSTECNO -->\n'),
    (MANIFEST,
     "    </application>\n",
     '        <provider android:name="androidx.core.content.FileProvider"\n'
     '            android:authorities="${applicationId}.jtactualizacion"\n'
     '            android:exported="false" android:grantUriPermissions="true">\n'
     '            <meta-data android:name="android.support.FILE_PROVIDER_PATHS"\n'
     '                android:resource="@xml/jt_actualizacion_rutas" />\n'
     '        </provider>\n'
     "    </application>\n"),
    (ACTIVIDAD,
     '                "check_permission" -> {\n',
     INSTALAR_KT + VERIFICAR_KT + '                "check_permission" -> {\n'),
    (ACTIVIDAD, "    private var pendingPicker: PendingPicker? = null\n", VERIFICAR_CAMPO_KT),
    (ACTIVIDAD, "        super.onActivityResult(requestCode, resultCode, data)\n", VERIFICAR_RESULTADO_KT),
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
    textos[SERVIDOR] = textos[SERVIDOR].replace(viejo, nuevo) + actualizacion + ASISTENTE + SESION
    for ruta, t in textos.items():
        open(ruta, "w", encoding="utf-8").write(t)
    os.makedirs(os.path.dirname(RUTAS_XML), exist_ok=True)
    with open(RUTAS_XML, "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<paths><cache-path name="actualizacion" path="jt-actualizacion/" /></paths>\n')
    print(f"justecno_android: inicio en Compartir pantalla, asistente de permisos y actualización (build {build})")


if __name__ == "__main__":
    main()
