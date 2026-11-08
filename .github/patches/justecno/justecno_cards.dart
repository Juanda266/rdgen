// Tarjetas propias de "Soporte JUSTECNO" para la pantalla principal (escritorio).
// El workflow generator-windows.yml copia este archivo a
// flutter/lib/desktop/widgets/justecno_cards.dart y fija kJustecnoBuild y kJustecnoVariante.
// La app de técnicos ("JUSTECNO-Tecnico", solo controla) usa únicamente JustecnoUpdateCard y
// lee su propia versión en soporte.justecno.com/descargas/tecnicos/version.json.
//
// - JustecnoUpdateCard: consulta app-api/v1/version al iniciar y cada 6 h; si hay un
//   "build" mayor que el propio, muestra un aviso. Si el build propio es menor que el
//   "minimo" de version.json, la app queda bloqueada con un aviso que no se cierra hasta
//   actualizar. "Actualizar ahora" descarga de soporte.justecno.com/descargas/ el archivo de
//   este equipo, comprueba su SHA-256 con el de version.json y lo instala encima (conserva
//   ID y ajustes): Windows .exe "--update" (UAC), Mac .dmg "--update" (clave del Mac),
//   Linux .deb/.rpm/.pkg.tar.zst con pkexec. Si algo falla, queda el botón de la página.
// - JustecnoAliasCard: el cliente escribe su nombre completo y un usuario único; se guardan
//   en la libreta compartida del servidor (rustdesk.justecno.com/app-api/v1/alias) como
//   "Nombre completo (usuario)". Si otro equipo ya tiene ese usuario: "Nombre de usuario ocupado".
// - JustecnoMantenimiento (va dentro de JustecnoUpdateCard, así sale en las dos apps): lee el
//   mantenimiento programado en soporte.justecno.com/wp-json/justecno/v1/mantenimiento. Desde 2 días
//   antes muestra el aviso; en los últimos 30 minutos, la cuenta regresiva. A los 30, 10, 5 y 1 minuto
//   trae la ventana al frente con un aviso, para que quien está en sesión sepa cuándo se corta.
// Todas fallan en silencio sin red: sin respuesta del servidor nunca bloquean la app.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

// Número de compilación propio. El workflow lo reemplaza (JUSTECNO_BUILD).
const int kJustecnoBuild = 0;

// 'clientes' (Soporte JUSTECNO) o 'tecnicos' (JUSTECNO Técnico). El workflow la reemplaza.
const String kJustecnoVariante = 'clientes';
const bool _kTecnicos = kJustecnoVariante == 'tecnicos';
const String _kNombreApp = _kTecnicos ? 'JUSTECNO Técnico' : 'Soporte JUSTECNO';

const String _kVersionUrl = _kTecnicos
    ? 'https://soporte.justecno.com/descargas/tecnicos/version.json'
    : 'https://rustdesk.justecno.com/app-api/v1/version';
const String _kAliasUrl = 'https://rustdesk.justecno.com/app-api/v1/alias';
const String _kDefaultPage = _kTecnicos
    ? 'https://soporte.justecno.com/descargas/tecnicos/'
    : 'https://soporte.justecno.com/soporte/';
const String _kDownloadBase = 'https://soporte.justecno.com/descargas/';
const Duration _kTimeout = Duration(seconds: 15);
const Color _kBlue = Color(0xFF2F65BA);

String? _userAgent;

Future<Map<String, String>> _headers({bool json = false}) async {
  if (_userAgent == null) {
    var version = '';
    try {
      version = await bind.mainGetVersion();
    } catch (_) {}
    _userAgent = 'SoporteJUSTECNO/$version (build $kJustecnoBuild)';
  }
  return {
    'User-Agent': _userAgent!,
    'Accept': 'application/json',
    if (json) 'Content-Type': 'application/json; charset=utf-8',
  };
}

String _platformKey() {
  if (Platform.isWindows) return 'windows';
  if (Platform.isMacOS) return 'macos';
  return 'linux';
}

Widget _card(BuildContext context, List<Widget> children) {
  return Container(
    margin: const EdgeInsets.only(top: 16, left: 12, right: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: _kBlue.withOpacity(0.6)),
      color: _kBlue.withOpacity(0.08),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}

// ---------------------------------------------------------------------------
// Tarjetas de las dos apps: mantenimiento programado + nueva versión
// ---------------------------------------------------------------------------

class JustecnoUpdateCard extends StatelessWidget {
  const JustecnoUpdateCard({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: const [JustecnoMantenimiento(), _JustecnoActualizacion()],
    );
  }
}

// ---------------------------------------------------------------------------
// Mantenimiento programado del servidor
// ---------------------------------------------------------------------------

const String _kMantUrl =
    'https://soporte.justecno.com/wp-json/justecno/v1/mantenimiento';
const List<int> _kMantAvisos = [30, 10, 5, 1]; // minutos antes: ventana al frente
const Color _kAmbar = Color(0xFFFFB020);
const Color _kRojo = Color(0xFFFF6B81);

String _hora(DateTime t) {
  final l = t.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  final m = l.minute.toString().padLeft(2, '0');
  return '$h:$m ${l.hour < 12 ? 'a. m.' : 'p. m.'}';
}

String _resta(Duration d) {
  final seg = d.inSeconds < 0 ? 0 : d.inSeconds;
  if (seg < 60) return '$seg segundos';
  final m = (seg + 59) ~/ 60;
  return m == 1 ? '1 minuto' : '$m minutos';
}

class JustecnoMantenimiento extends StatefulWidget {
  const JustecnoMantenimiento({Key? key}) : super(key: key);

  @override
  State<JustecnoMantenimiento> createState() => _JustecnoMantenimientoState();
}

class _JustecnoMantenimientoState extends State<JustecnoMantenimiento> {
  Timer? _consulta;
  Timer? _reloj;
  DateTime? _ini;
  DateTime? _fin;
  String _mensaje = '';
  bool _cerrado = false;
  final Set<String> _avisados = {};

  @override
  void initState() {
    super.initState();
    _consulta = Timer(const Duration(seconds: 8), _revisar);
    _reloj = Timer.periodic(const Duration(seconds: 1), (_) => _tic());
  }

  @override
  void dispose() {
    _consulta?.cancel();
    _reloj?.cancel();
    super.dispose();
  }

  // Consulta más seguido cuanto más cerca está el mantenimiento
  void _programar() {
    _consulta?.cancel();
    var espera = const Duration(minutes: 30);
    final ini = _ini;
    if (ini != null) {
      final falta = ini.difference(DateTime.now());
      if (falta < const Duration(hours: 3)) espera = const Duration(minutes: 2);
    }
    _consulta = Timer(espera, _revisar);
  }

  Future<void> _revisar() async {
    try {
      final resp = await http
          .get(Uri.parse(_kMantUrl), headers: await _headers())
          .timeout(_kTimeout);
      if (resp.statusCode == 200) {
        final data = jsonDecode(utf8.decode(resp.bodyBytes));
        if (data is Map && mounted) {
          final ini = data['inicio'], fin = data['fin'], msg = data['mensaje'];
          setState(() {
            _ini = ini is String ? DateTime.tryParse(ini) : null;
            _fin = fin is String ? DateTime.tryParse(fin) : null;
            _mensaje = msg is String ? msg : '';
          });
        }
      }
    } catch (_) {
      // Sin red (o con el servidor ya apagado): se queda con lo último que supo.
    }
    if (mounted) _programar();
  }

  // 'anuncio' (2 días antes), 'pronto' (30 min antes), 'activo' o ''
  String _fase(DateTime ahora) {
    final ini = _ini, fin = _fin;
    if (ini == null || fin == null || !ahora.isBefore(fin)) return '';
    if (!ahora.isBefore(ini)) return 'activo';
    final falta = ini.difference(ahora);
    if (falta <= const Duration(minutes: 30)) return 'pronto';
    return falta <= const Duration(days: 2) ? 'anuncio' : '';
  }

  void _tic() {
    if (!mounted) return;
    final ahora = DateTime.now();
    final fase = _fase(ahora);
    if (fase == 'pronto' || fase == 'activo') setState(() {});
    final ini = _ini;
    if (fase != 'pronto' || ini == null) return;
    final faltaMin = ini.difference(ahora).inSeconds / 60.0;
    final toca = _kMantAvisos.where((m) => faltaMin <= m).toList();
    if (toca.isEmpty) return;
    final clave = '${ini.toIso8601String()}|${toca.reduce((a, b) => a < b ? a : b)}';
    if (_avisados.contains(clave)) return;
    _avisados.add(clave);
    _avisar();
  }

  Future<void> _avisar() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => _DialogoMantenimiento(ini: _ini!),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ahora = DateTime.now();
    final fase = _fase(ahora);
    if (fase.isEmpty || (_cerrado && fase == 'anuncio')) {
      return const SizedBox.shrink();
    }
    final ini = _ini!, fin = _fin!;
    final color = fase == 'anuncio' ? _kAmbar : _kRojo;
    final String titulo;
    final String texto;
    if (fase == 'activo') {
      titulo = 'En mantenimiento hasta las ${_hora(fin)}';
      texto = 'El servicio de soporte vuelve solo a esa hora.';
    } else if (fase == 'pronto') {
      titulo = 'Mantenimiento en ${_resta(ini.difference(ahora))}';
      texto = _kTecnicos
          ? 'A las ${_hora(ini)} se apaga el servidor y las sesiones se cortarán. '
              'No empieces una nueva y avísale al cliente.'
          : 'A las ${_hora(ini)} se apaga el servidor: si un técnico te está '
              'atendiendo, la conexión se cortará a esa hora.';
    } else {
      titulo = 'Mantenimiento programado';
      texto = _mensaje.isNotEmpty
          ? _mensaje
          : 'El servicio de soporte no estará disponible desde las ${_hora(ini)}.';
    }
    return Container(
      margin: const EdgeInsets.only(top: 16, left: 12, right: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.8)),
        color: color.withOpacity(0.12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(titulo,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
              ),
              if (fase == 'anuncio')
                InkWell(
                  onTap: () => setState(() => _cerrado = true),
                  child: const Icon(Icons.close, size: 16),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(texto, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

class _DialogoMantenimiento extends StatefulWidget {
  final DateTime ini;
  const _DialogoMantenimiento({Key? key, required this.ini}) : super(key: key);

  @override
  State<_DialogoMantenimiento> createState() => _DialogoMantenimientoState();
}

class _DialogoMantenimientoState extends State<_DialogoMantenimiento> {
  Timer? _reloj;

  @override
  void initState() {
    super.initState();
    _reloj = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!DateTime.now().isBefore(widget.ini)) {
        Navigator.of(context).maybePop();
        return;
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _reloj?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final falta = widget.ini.difference(DateTime.now());
    return AlertDialog(
      title: Text('Quedan ${_resta(falta)} para el mantenimiento'),
      content: Text(_kTecnicos
          ? 'A las ${_hora(widget.ini)} se apaga el servidor de JUSTECNO y las '
              'sesiones de control remoto, terminal y archivos se cortarán. '
              'Termina o guarda lo que estés haciendo y avísale al cliente.'
          : 'A las ${_hora(widget.ini)} se apaga el servidor de JUSTECNO. Si un '
              'técnico te está atendiendo, la conexión se cortará a esa hora. '
              'Guarda lo que estés haciendo.'),
      actions: [
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: _kBlue, foregroundColor: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Entendido'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Aviso de nueva versión
// ---------------------------------------------------------------------------

class _JustecnoActualizacion extends StatefulWidget {
  const _JustecnoActualizacion({Key? key}) : super(key: key);

  @override
  State<_JustecnoActualizacion> createState() => _JustecnoActualizacionState();
}

// Si en version.json el "minimo" de este sistema es mayor que el build propio, la versión ya no se
// puede usar: sale un aviso que no se cierra hasta actualizar (las conexiones entrantes siguen
// funcionando, así un técnico puede entrar y actualizarla). Se instala desde la misma app:
//   Windows: el .exe con "--update" (Windows pide permiso).
//   Mac: el .dmg con "--update" (RustDesk lo instala en Aplicaciones y pide la clave del Mac).
//   Linux: el paquete con pkexec (apt-get, dnf, zypper, rpm o pacman; pide la clave del equipo).
class _JustecnoActualizacionState extends State<_JustecnoActualizacion> {
  static final _archivoOk = RegExp(
      r'^(windows|macos|linux|tecnicos(/(macos|linux))?)/[A-Za-z0-9._-]+\.(exe|dmg|deb|rpm|zst)$');
  static final _shaOk = RegExp(r'^[0-9a-f]{64}$');

  // La tarjeta y el aviso de bloqueo se dibujan con el mismo estado. No se libera en dispose():
  // el aviso puede seguir abierto un instante después.
  final ValueNotifier<int> _cambio = ValueNotifier<int>(0);
  Timer? _first;
  Timer? _periodic;
  String _version = '';
  String _page = _kDefaultPage;
  String _archivo = '';
  String _sha = '';
  int _size = 0;
  bool _available = false;
  bool _obligatoria = false;
  bool _puedeInstalar = false;
  bool _bloqueoAbierto = false;
  bool _closed = false;
  bool _installing = false;
  double? _progress;
  String _status = '';
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    _first = Timer(const Duration(seconds: 5), _check);
    _periodic = Timer.periodic(const Duration(hours: 6), (_) => _check());
  }

  @override
  void dispose() {
    _first?.cancel();
    _periodic?.cancel();
    super.dispose();
  }

  void _set(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
    _cambio.value++;
  }

  bool _existe(String ruta) {
    try {
      return File(ruta).existsSync();
    } catch (_) {
      return false;
    }
  }

  Future<String> _salida(String cmd, List<String> args) async {
    try {
      final r = await Process.run(cmd, args);
      if (r.exitCode == 0) return r.stdout.toString().trim();
    } catch (_) {}
    return '';
  }

  // Final del nombre del archivo que le sirve a este equipo (ver PLATAFORMAS en
  // justecno-actualizador). null: el archivo principal (Windows). '': no hay para este equipo.
  Future<String?> _sufijo() async {
    if (Platform.isWindows) return null;
    final arm =
        RegExp(r'arm64|aarch64').hasMatch(await _salida('uname', ['-m']));
    if (Platform.isMacOS) return arm ? '-apple.dmg' : '-intel.dmg';
    if (_existe('/usr/bin/dpkg')) return arm ? '-arm64.deb' : '-amd64.deb';
    if (_existe('/usr/bin/pacman')) return arm ? '' : '-arch.pkg.tar.zst';
    if (_existe('/usr/bin/rpm')) {
      var suse = false;
      try {
        suse = File('/etc/os-release')
            .readAsStringSync()
            .toLowerCase()
            .contains('suse');
      } catch (_) {}
      if (suse) return arm ? '' : '-suse-x86_64.rpm';
      return arm ? '-aarch64.rpm' : '-x86_64.rpm';
    }
    return '';
  }

  bool get _instalada {
    if (Platform.isLinux) return _existe('/usr/bin/pkexec');
    try {
      return bind.mainIsInstalled();
    } catch (_) {
      return false;
    }
  }

  Future<void> _check() async {
    if (_installing) return;
    try {
      final resp = await http
          .get(Uri.parse(_kVersionUrl), headers: await _headers())
          .timeout(_kTimeout);
      if (resp.statusCode != 200) return;
      final data = jsonDecode(utf8.decode(resp.bodyBytes));
      if (data is! Map) return;
      final plats = data['plataformas'];
      if (plats is! Map) return;
      final plat = plats[_platformKey()];
      if (plat is! Map) return;
      final build = plat['build'];
      if (build is! int) return;
      final minimo = plat['minimo'];
      final page = data['pagina'];
      final version = plat['version'];
      dynamic archivo = plat['archivo'];
      dynamic sha = plat['sha256'];
      dynamic size = plat['tamano'];
      final suf = await _sufijo();
      if (suf != null) {
        archivo = null;
        sha = null;
        size = null;
        final lista = plat['archivos'];
        if (suf.isNotEmpty && lista is List) {
          for (final a in lista) {
            if (a is! Map) continue;
            final n = a['archivo'];
            if (n is String &&
                n.endsWith(suf) &&
                (suf.contains('suse') || !n.contains('-suse-'))) {
              archivo = n;
              sha = a['sha256'];
              size = a['tamano'];
              break;
            }
          }
        }
      }
      final instalada = _instalada;
      _set(() {
        _available = build > kJustecnoBuild;
        _obligatoria = _available &&
            kJustecnoBuild > 0 &&
            minimo is int &&
            kJustecnoBuild < minimo;
        _version = version is String ? version : '';
        if (page is String && page.startsWith('https://')) _page = page;
        _archivo = archivo is String ? archivo : '';
        _sha = sha is String ? sha.toLowerCase() : '';
        _size = size is int ? size : 0;
        _puedeInstalar = instalada &&
            _archivoOk.hasMatch(_archivo) &&
            _shaOk.hasMatch(_sha);
      });
      if (_obligatoria) _mostrarBloqueo();
    } catch (_) {
      // Sin red o JSON inválido: no se muestra nada.
    }
  }

  void _setStatus(String status, {bool error = false, double? progress}) {
    _set(() {
      _status = status;
      _statusIsError = error;
      _progress = progress;
    });
  }

  void _fallo(String status) {
    _set(() {
      _installing = false;
      _status = status;
      _statusIsError = true;
      _progress = null;
    });
  }

  Future<File> _download() async {
    final dir = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}SoporteJUSTECNO-actualizacion');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final nombre = Platform.isWindows ? 'Soporte-JUSTECNO.exe' : _archivo.split('/').last;
    final file = File('${dir.path}${Platform.pathSeparator}$nombre');
    final headers = await _headers();
    headers['Accept'] = '*/*';
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse('$_kDownloadBase$_archivo'))
        ..headers.addAll(headers);
      final resp = await client.send(req).timeout(_kTimeout);
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength ?? _size;
      final sink = file.openWrite();
      var got = 0;
      var shown = -1;
      try {
        await for (final chunk
            in resp.stream.timeout(const Duration(seconds: 60))) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) {
            final pct = got * 100 ~/ total;
            if (pct != shown) {
              shown = pct;
              _setStatus('Descargando… $pct %', progress: got / total);
            }
          }
        }
      } finally {
        await sink.close();
      }
      if (_size > 0 && got != _size) {
        throw Exception('tamaño inesperado');
      }
      return file;
    } finally {
      client.close();
    }
  }

  // SHA-256 con lo que trae cada sistema (certutil, shasum, sha256sum); los argumentos van sin shell.
  Future<String> _sha256(File file) async {
    try {
      final ProcessResult r;
      if (Platform.isWindows) {
        r = await Process.run('certutil', ['-hashfile', file.path, 'SHA256']);
      } else if (Platform.isMacOS) {
        r = await Process.run('shasum', ['-a', '256', file.path]);
      } else {
        r = await Process.run('sha256sum', [file.path]);
      }
      if (r.exitCode != 0) return '';
      final out = r.stdout.toString();
      if (!Platform.isWindows) {
        final hex = out.trim().split(RegExp(r'\s+')).first.toLowerCase();
        return _shaOk.hasMatch(hex) ? hex : '';
      }
      for (final line in out.split(RegExp(r'\r?\n'))) {
        final hex = line.replaceAll(' ', '').trim().toLowerCase();
        if (_shaOk.hasMatch(hex)) return hex;
      }
    } catch (_) {}
    return '';
  }

  List<String>? _comandoLinux(String ruta) {
    if (ruta.endsWith('.deb')) {
      return _existe('/usr/bin/apt-get')
          ? ['apt-get', 'install', '-y', ruta]
          : ['dpkg', '-i', ruta];
    }
    if (ruta.endsWith('.pkg.tar.zst')) {
      return ['pacman', '-U', '--noconfirm', ruta];
    }
    if (ruta.endsWith('.rpm')) {
      if (_existe('/usr/bin/dnf')) return ['dnf', 'install', '-y', ruta];
      if (_existe('/usr/bin/zypper')) {
        return [
          'zypper',
          '--non-interactive',
          'install',
          '--allow-unsigned-rpm',
          ruta
        ];
      }
      return ['rpm', '-U', '--replacepkgs', ruta];
    }
    return null;
  }

  Future<void> _install() async {
    _set(() {
      _installing = true;
      _status = 'Descargando…';
      _statusIsError = false;
      _progress = null;
    });
    late final File file;
    try {
      file = await _download();
      _setStatus('Comprobando el archivo…');
      if (await _sha256(file) != _sha) {
        try {
          await file.delete();
        } catch (_) {}
        throw Exception('el archivo no coincide');
      }
    } catch (_) {
      _fallo('No se pudo descargar la actualización. Revisa tu conexión '
          'o descárgala desde la página.');
      return;
    }
    try {
      if (Platform.isWindows) {
        _setStatus('Windows te pedirá permiso: pulsa "Sí" para instalar.');
        final ruta = file.path.replaceAll("'", "''");
        final r = await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-Command',
          "Start-Process -FilePath '$ruta' -ArgumentList '--update' -Verb RunAs"
        ]);
        if (r.exitCode != 0) {
          _fallo('No se instaló: Windows no dio el permiso. '
              'Puedes intentarlo de nuevo cuando quieras.');
          return;
        }
        _setStatus('Instalando… la app se cerrará y se abrirá sola en unos '
            'segundos con la versión nueva.');
      } else if (Platform.isMacOS) {
        await Process.start(
            Platform.resolvedExecutable, ['--update', file.path],
            mode: ProcessStartMode.detached);
        _setStatus('Tu Mac te pedirá la contraseña para instalar. Después la '
            'app se cerrará y se abrirá sola con la versión nueva.');
      } else {
        final cmd = _comandoLinux(file.path);
        if (cmd == null) throw Exception('paquete desconocido');
        _setStatus('El equipo te pedirá tu contraseña para instalar.');
        final r = await Process.run('pkexec', cmd);
        if (r.exitCode != 0) {
          _fallo(r.exitCode == 126 || r.exitCode == 127
              ? 'No se instaló: no se dio el permiso. Puedes intentarlo de '
                  'nuevo cuando quieras.'
              : 'No se pudo instalar la actualización. Descárgala desde la '
                  'página.');
          return;
        }
        _setStatus('¡Listo! Abriendo la versión nueva…');
        try {
          await file.delete();
        } catch (_) {}
        await Process.start(Platform.resolvedExecutable, [],
            mode: ProcessStartMode.detached);
        await Future.delayed(const Duration(seconds: 1));
        exit(0);
      }
    } catch (_) {
      _fallo('No se pudo instalar la actualización. Descárgala desde la '
          'página.');
    }
  }

  Future<void> _openPage() async {
    try {
      await launchUrl(Uri.parse(_page), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  // Aviso que no se puede cerrar mientras la versión sea obligatoria.
  void _mostrarBloqueo() {
    if (_bloqueoAbierto || !mounted) return;
    _bloqueoAbierto = true;
    () async {
      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
      if (!mounted) {
        _bloqueoAbierto = false;
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: Text('Actualiza $_kNombreApp para seguir'),
            content: SizedBox(
              width: 440,
              child: ValueListenableBuilder<int>(
                valueListenable: _cambio,
                builder: (_, __, ___) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _contenido(
                      enDialogo: true, cerrar: () => Navigator.of(ctx).pop()),
                ),
              ),
            ),
          ),
        ),
      );
      _bloqueoAbierto = false;
    }();
  }

  String get _permiso {
    if (Platform.isWindows) return 'Windows te pedirá permiso: pulsa «Sí».';
    if (Platform.isMacOS) return 'Tu Mac te pedirá la contraseña del equipo.';
    return 'El equipo te pedirá tu contraseña.';
  }

  List<Widget> _contenido({required bool enDialogo, VoidCallback? cerrar}) {
    final children = <Widget>[];
    final conVersion = _version.isNotEmpty ? ' (versión $_version)' : '';
    if (enDialogo) {
      children.add(Text(
          _obligatoria
              ? 'Esta versión de $_kNombreApp ya no se puede usar. Instala la '
                  'versión nueva$conVersion para seguir usándola.'
              : '¡Listo! Ya puedes seguir usando la app.',
          style: const TextStyle(fontSize: 14)));
    } else {
      final title = _obligatoria
          ? 'Esta versión de $_kNombreApp ya no se puede usar: actualízala$conVersion'
          : 'Nueva versión de $_kNombreApp disponible$conVersion';
      children.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(title,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
          if (!_installing && !_obligatoria)
            InkWell(
              onTap: () => _set(() => _closed = true),
              child: const Icon(Icons.close, size: 16),
            ),
        ],
      ));
    }
    if (_puedeInstalar && !_installing && _status.isEmpty) {
      children.addAll([
        const SizedBox(height: 6),
        Text(
            'Se instala sobre la actual y conservas tu ID y tus ajustes. $_permiso '
            'Si un técnico está conectado, la conexión se cortará unos segundos.',
            style: const TextStyle(fontSize: 12)),
      ]);
    }
    if (_status.isNotEmpty) {
      children.addAll([
        const SizedBox(height: 8),
        Text(_status,
            style: TextStyle(
                fontSize: 12, color: _statusIsError ? Colors.red : null)),
      ]);
    }
    if (_installing) {
      children.addAll([
        const SizedBox(height: 8),
        LinearProgressIndicator(value: _progress),
      ]);
    } else if (enDialogo && !_obligatoria) {
      children.addAll([
        const SizedBox(height: 10),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: _kBlue, foregroundColor: Colors.white),
          onPressed: cerrar,
          child: const Text('Continuar'),
        ),
      ]);
    } else {
      children.addAll([
        const SizedBox(height: 10),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: _kBlue, foregroundColor: Colors.white),
          onPressed: _puedeInstalar ? _install : _openPage,
          child: Text(
              _puedeInstalar ? 'Actualizar ahora' : 'Ir a la página de descarga'),
        ),
      ]);
      if (_puedeInstalar) {
        children.add(Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _openPage,
            child: const Text('Descargar desde la página'),
          ),
        ));
      }
    }
    return children;
  }

  @override
  Widget build(BuildContext context) {
    if (!_available || (_closed && !_obligatoria)) return const SizedBox.shrink();
    return _card(context, _contenido(enDialogo: false));
  }
}

// ---------------------------------------------------------------------------
// Nombre (alias) para el técnico
// ---------------------------------------------------------------------------

class JustecnoAliasCard extends StatefulWidget {
  const JustecnoAliasCard({Key? key}) : super(key: key);

  @override
  State<JustecnoAliasCard> createState() => _JustecnoAliasCardState();
}

class _JustecnoAliasCardState extends State<JustecnoAliasCard> {
  // Mismas reglas que el servidor (app-api/v1/alias)
  static final _usuarioOk = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{2,29}$');

  final _nombre = TextEditingController();
  final _usuario = TextEditingController();
  Timer? _retry;
  int _retries = 0;
  String _nombreGuardado = '';
  String _usuarioGuardado = '';
  bool _loaded = false;
  bool _editing = false;
  bool _saving = false;
  String _message = '';
  bool _messageIsError = false;
  String? _errorNombre;
  String? _errorUsuario;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _retry?.cancel();
    _nombre.dispose();
    _usuario.dispose();
    super.dispose();
  }

  Future<Map<String, String>?> _ids() async {
    try {
      final id = (await bind.mainGetMyId()).trim();
      final uuid = (await bind.mainGetUuid()).trim();
      if (id.isEmpty || uuid.isEmpty) return null;
      return {'id': id, 'uuid': uuid};
    } catch (_) {
      return null;
    }
  }

  void _scheduleRetry() {
    // El equipo puede tardar en reportarse al servidor o no haber red:
    // reintenta cada minuto, como mucho 30 veces, sin molestar al usuario.
    if (_retries >= 30 || !mounted) return;
    _retries++;
    _retry?.cancel();
    _retry = Timer(const Duration(minutes: 1), _load);
  }

  String _texto(dynamic v) => v is String ? v : '';

  Future<void> _load() async {
    final ids = await _ids();
    if (ids == null) {
      _scheduleRetry();
      return;
    }
    try {
      final uri = Uri.parse(_kAliasUrl).replace(queryParameters: ids);
      final resp =
          await http.get(uri, headers: await _headers()).timeout(_kTimeout);
      final data = jsonDecode(utf8.decode(resp.bodyBytes));
      if (resp.statusCode == 200 && data is Map && data['ok'] == true) {
        if (!mounted) return;
        setState(() {
          _nombreGuardado = _texto(data['nombre']);
          _usuarioGuardado = _texto(data['usuario']);
          _loaded = true;
          if (!_editing) {
            _nombre.text = _nombreGuardado;
            _usuario.text = _usuarioGuardado;
          }
        });
        return;
      }
    } catch (_) {}
    _scheduleRetry();
  }

  Future<void> _save() async {
    final nombre = _nombre.text.trim().split(RegExp(r'\s+')).join(' ');
    final usuario = _usuario.text.trim();
    String? errNombre;
    String? errUsuario;
    if (nombre.length < 3 || nombre.length > 60) {
      errNombre = 'Escribe tu nombre completo';
    }
    if (!_usuarioOk.hasMatch(usuario)) {
      errUsuario = 'De 3 a 30 letras o números, sin espacios (puedes usar . _ -)';
    }
    if (errNombre != null || errUsuario != null) {
      setState(() {
        _errorNombre = errNombre;
        _errorUsuario = errUsuario;
        _message = '';
      });
      return;
    }
    setState(() {
      _saving = true;
      _message = '';
      _errorNombre = null;
      _errorUsuario = null;
    });
    final ids = await _ids();
    var message = 'No se pudo guardar. Revisa tu conexión e inténtalo de nuevo.';
    var isError = true;
    if (ids != null) {
      try {
        final resp = await http
            .post(Uri.parse(_kAliasUrl),
                headers: await _headers(json: true),
                body: jsonEncode({...ids, 'usuario': usuario, 'nombre': nombre}))
            .timeout(_kTimeout);
        final data = jsonDecode(utf8.decode(resp.bodyBytes));
        if (resp.statusCode == 200 && data is Map && data['ok'] == true) {
          isError = false;
          _nombreGuardado = _texto(data['nombre']).isNotEmpty ? _texto(data['nombre']) : nombre;
          _usuarioGuardado = _texto(data['usuario']).isNotEmpty ? _texto(data['usuario']) : usuario;
          message = 'Guardado. El técnico te encontrará como "$_nombreGuardado".';
          _loaded = true;
          _editing = false;
          _retry?.cancel();
        } else if (data is Map && data['error'] is String) {
          final error = data['error'] as String;
          if (data['campo'] == 'usuario') {
            _errorUsuario = error;
            message = '';
          } else if (data['campo'] == 'nombre') {
            _errorNombre = error;
            message = '';
          } else {
            message = error;
          }
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _message = message;
      _messageIsError = isError;
    });
  }

  InputDecoration _campo(String hint, String? error, {String? ayuda}) {
    return InputDecoration(
      isDense: true,
      counterText: '',
      hintText: hint,
      helperText: ayuda,
      helperMaxLines: 2,
      errorText: error,
      errorMaxLines: 2,
      border: const OutlineInputBorder(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final yaGuardado = _usuarioGuardado.isNotEmpty && _nombreGuardado.isNotEmpty;
    final showForm = !yaGuardado || _editing;
    final children = <Widget>[
      const Text('Tus datos para el técnico',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
      const SizedBox(height: 6),
    ];
    if (showForm) {
      if (!yaGuardado) {
        children.add(const Text(
            'Así el técnico te encuentra más rápido. Tu usuario es único: nadie más podrá usarlo.',
            style: TextStyle(fontSize: 12)));
      }
      children.addAll([
        const SizedBox(height: 8),
        const Text('Nombre completo', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 4),
        TextField(
          controller: _nombre,
          maxLength: 60,
          enabled: !_saving,
          textCapitalization: TextCapitalization.words,
          style: const TextStyle(fontSize: 13),
          decoration: _campo('Juan Pérez Gómez', _errorNombre),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 8),
        const Text('Usuario', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 4),
        TextField(
          controller: _usuario,
          maxLength: 30,
          enabled: !_saving,
          autocorrect: false,
          style: const TextStyle(fontSize: 13),
          decoration: _campo('juanperez', _errorUsuario,
              ayuda: 'Sin espacios. Puedes usar letras, números y . _ -'),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: _kBlue, foregroundColor: Colors.white),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Guardando…' : 'Guardar'),
            ),
          ),
          if (_editing) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: _saving
                  ? null
                  : () => setState(() {
                        _editing = false;
                        _errorNombre = null;
                        _errorUsuario = null;
                        _message = '';
                        _nombre.text = _nombreGuardado;
                        _usuario.text = _usuarioGuardado;
                      }),
              child: const Text('Cancelar'),
            ),
          ],
        ]),
      ]);
    } else {
      children.addAll([
        Text(_nombreGuardado, style: const TextStyle(fontSize: 13)),
        Text('Usuario: $_usuarioGuardado',
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => setState(() {
              _editing = true;
              _message = '';
              _nombre.text = _nombreGuardado;
              _usuario.text = _usuarioGuardado;
            }),
            child: const Text('Cambiar'),
          ),
        ),
      ]);
    }
    if (_message.isNotEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(_message,
            style: TextStyle(
                fontSize: 12,
                color: _messageIsError ? Colors.red : Colors.green.shade700)),
      ));
    }
    return _card(context, children);
  }
}
