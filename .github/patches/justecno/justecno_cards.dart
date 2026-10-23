// Tarjetas propias de "Soporte JUSTECNO" para la pantalla principal (escritorio).
// El workflow generator-windows.yml copia este archivo a
// flutter/lib/desktop/widgets/justecno_cards.dart y fija kJustecnoBuild y kJustecnoVariante.
// La app de técnicos ("JUSTECNO-Tecnico", solo controla) usa únicamente JustecnoUpdateCard y
// lee su propia versión en soporte.justecno.com/descargas/tecnicos/version.json.
//
// - JustecnoUpdateCard: consulta app-api/v1/version al iniciar y cada 24 h; si hay un
//   "build" mayor que el propio, muestra un aviso. En Windows, con la app instalada,
//   el botón "Instalar" descarga el .exe de soporte.justecno.com/descargas/, comprueba
//   su SHA-256 con el de version.json y lo ejecuta con "--update" pidiendo permiso a
//   Windows (UAC): es el mismo instalador interno de RustDesk, que conserva ID y ajustes.
//   Si algo falla, queda el botón para abrir la página de descarga.
// - JustecnoAliasCard: el cliente escribe su nombre completo y un usuario único; se guardan
//   en la libreta compartida del servidor (rustdesk.justecno.com/app-api/v1/alias) como
//   "Nombre completo (usuario)". Si otro equipo ya tiene ese usuario: "Nombre de usuario ocupado".
// Ambas fallan en silencio sin red: nunca bloquean la app.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

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
// Aviso de nueva versión
// ---------------------------------------------------------------------------

class JustecnoUpdateCard extends StatefulWidget {
  const JustecnoUpdateCard({Key? key}) : super(key: key);

  @override
  State<JustecnoUpdateCard> createState() => _JustecnoUpdateCardState();
}

class _JustecnoUpdateCardState extends State<JustecnoUpdateCard> {
  static final _archivoOk = RegExp(r'^(windows|tecnicos)/[A-Za-z0-9._-]+\.exe$');
  static final _shaOk = RegExp(r'^[0-9a-f]{64}$');

  Timer? _first;
  Timer? _daily;
  String _version = '';
  String _page = _kDefaultPage;
  String _archivo = '';
  String _sha = '';
  int _size = 0;
  bool _available = false;
  bool _closed = false;
  bool _installing = false;
  double? _progress;
  String _status = '';
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    _first = Timer(const Duration(seconds: 5), _check);
    _daily = Timer.periodic(const Duration(hours: 24), (_) => _check());
  }

  @override
  void dispose() {
    _first?.cancel();
    _daily?.cancel();
    super.dispose();
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
      final page = data['pagina'];
      final version = plat['version'];
      final archivo = plat['archivo'];
      final sha = plat['sha256'];
      final size = plat['tamano'];
      if (!mounted) return;
      setState(() {
        _available = build > kJustecnoBuild;
        _version = version is String ? version : '';
        if (page is String && page.startsWith('https://')) _page = page;
        _archivo = archivo is String ? archivo : '';
        _sha = sha is String ? sha.toLowerCase() : '';
        _size = size is int ? size : 0;
      });
    } catch (_) {
      // Sin red o JSON inválido: no se muestra nada.
    }
  }

  bool get _canInstall {
    if (!Platform.isWindows) return false;
    if (!_archivoOk.hasMatch(_archivo) || !_shaOk.hasMatch(_sha)) return false;
    try {
      return bind.mainIsInstalled();
    } catch (_) {
      return false;
    }
  }

  void _setStatus(String status, {bool error = false, double? progress}) {
    if (!mounted) return;
    setState(() {
      _status = status;
      _statusIsError = error;
      _progress = progress;
    });
  }

  Future<File> _download() async {
    final dir = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}SoporteJUSTECNO-actualizacion');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final file =
        File('${dir.path}${Platform.pathSeparator}Soporte-JUSTECNO.exe');
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

  // SHA-256 con certutil (viene en Windows); los argumentos van sin shell.
  Future<String> _sha256(File file) async {
    final r = await Process.run('certutil', ['-hashfile', file.path, 'SHA256']);
    if (r.exitCode != 0) return '';
    for (final line in r.stdout.toString().split(RegExp(r'\r?\n'))) {
      final hex = line.replaceAll(' ', '').trim().toLowerCase();
      if (_shaOk.hasMatch(hex)) return hex;
    }
    return '';
  }

  Future<void> _install() async {
    setState(() {
      _installing = true;
      _status = 'Descargando…';
      _statusIsError = false;
      _progress = null;
    });
    try {
      final file = await _download();
      _setStatus('Comprobando el archivo…');
      if (await _sha256(file) != _sha) {
        try {
          await file.delete();
        } catch (_) {}
        throw Exception('el archivo no coincide');
      }
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
        if (!mounted) return;
        setState(() {
          _installing = false;
          _status = 'No se instaló: Windows no dio el permiso. '
              'Puedes intentarlo de nuevo cuando quieras.';
          _statusIsError = true;
          _progress = null;
        });
        return;
      }
      _setStatus('Instalando… la app se cerrará y se abrirá sola en unos '
          'segundos con la versión nueva.');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _installing = false;
        _status = 'No se pudo descargar la actualización. Revisa tu conexión '
            'o descárgala desde la página.';
        _statusIsError = true;
        _progress = null;
      });
    }
  }

  Future<void> _openPage() async {
    try {
      await launchUrl(Uri.parse(_page), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (!_available || _closed) return const SizedBox.shrink();
    final title = _version.isNotEmpty
        ? 'Nueva versión de $_kNombreApp disponible (versión $_version)'
        : 'Nueva versión de $_kNombreApp disponible';
    final canInstall = _canInstall;
    final children = <Widget>[
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(title,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
          if (!_installing)
            InkWell(
              onTap: () => setState(() => _closed = true),
              child: const Icon(Icons.close, size: 16),
            ),
        ],
      ),
    ];
    if (canInstall && !_installing && _status.isEmpty) {
      children.addAll([
        const SizedBox(height: 6),
        const Text(
            'Se instala sobre la actual y conservas tu ID y tus ajustes. '
            'Si un técnico está conectado, la conexión se cortará unos segundos.',
            style: TextStyle(fontSize: 12)),
      ]);
    }
    if (_status.isNotEmpty) {
      children.addAll([
        const SizedBox(height: 8),
        Text(_status,
            style: TextStyle(
                fontSize: 12,
                color: _statusIsError ? Colors.red : null)),
      ]);
    }
    if (_installing) {
      children.addAll([
        const SizedBox(height: 8),
        LinearProgressIndicator(value: _progress),
      ]);
    } else {
      children.addAll([
        const SizedBox(height: 10),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: _kBlue, foregroundColor: Colors.white),
          onPressed: canInstall ? _install : _openPage,
          child: Text(canInstall ? 'Instalar' : 'Ir a la página de descarga'),
        ),
      ]);
      if (canInstall) {
        children.add(Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _openPage,
            child: const Text('Descargar desde la página'),
          ),
        ));
      }
    }
    return _card(context, children);
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
