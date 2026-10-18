// Tarjetas propias de "Soporte JUSTECNO" para la pantalla principal (escritorio).
// El workflow generator-windows.yml copia este archivo a
// flutter/lib/desktop/widgets/justecno_cards.dart y fija kJustecnoBuild.
//
// - JustecnoUpdateCard: consulta app-api/v1/version al iniciar y cada 24 h; si hay un
//   "build" mayor que el propio, muestra un aviso que solo abre la página de
//   descarga (no descarga ni instala nada).
// - JustecnoAliasCard: el cliente escribe su nombre y se guarda en la libreta
//   compartida del servidor (rustdesk.justecno.com/app-api/v1/alias).
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

const String _kVersionUrl =
    'https://rustdesk.justecno.com/app-api/v1/version';
const String _kAliasUrl = 'https://rustdesk.justecno.com/app-api/v1/alias';
const String _kDefaultPage = 'https://soporte.justecno.com/soporte/';
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
  Timer? _first;
  Timer? _daily;
  String _version = '';
  String _page = _kDefaultPage;
  bool _available = false;
  bool _closed = false;

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
      if (!mounted) return;
      setState(() {
        _available = build > kJustecnoBuild;
        _version = version is String ? version : '';
        if (page is String && page.startsWith('https://')) _page = page;
      });
    } catch (_) {
      // Sin red o JSON inválido: no se muestra nada.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_available || _closed) return const SizedBox.shrink();
    final title = _version.isNotEmpty
        ? 'Nueva versión de Soporte JUSTECNO disponible (versión $_version)'
        : 'Nueva versión de Soporte JUSTECNO disponible';
    return _card(context, [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(title,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
          InkWell(
            onTap: () => setState(() => _closed = true),
            child: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
      const SizedBox(height: 10),
      ElevatedButton(
        style: ElevatedButton.styleFrom(
            backgroundColor: _kBlue, foregroundColor: Colors.white),
        onPressed: () async {
          try {
            await launchUrl(Uri.parse(_page),
                mode: LaunchMode.externalApplication);
          } catch (_) {}
        },
        child: const Text('Ir a la página de descarga'),
      ),
    ]);
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
  final _controller = TextEditingController();
  Timer? _retry;
  int _retries = 0;
  String _alias = '';
  bool _loaded = false;
  bool _editing = false;
  bool _saving = false;
  String _message = '';
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _retry?.cancel();
    _controller.dispose();
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
        final alias = data['alias'] is String ? data['alias'] as String : '';
        if (!mounted) return;
        setState(() {
          _alias = alias;
          _loaded = true;
          if (!_editing) _controller.text = alias;
        });
        return;
      }
    } catch (_) {}
    _scheduleRetry();
  }

  Future<void> _save() async {
    final alias = _controller.text.trim();
    if (alias.length < 2 || alias.length > 40) {
      setState(() {
        _message = 'El nombre debe tener entre 2 y 40 caracteres.';
        _messageIsError = true;
      });
      return;
    }
    setState(() {
      _saving = true;
      _message = '';
    });
    final ids = await _ids();
    var message = 'No se pudo guardar. Revisa tu conexión e inténtalo de nuevo.';
    var isError = true;
    if (ids != null) {
      try {
        final resp = await http
            .post(Uri.parse(_kAliasUrl),
                headers: await _headers(json: true),
                body: jsonEncode({...ids, 'alias': alias}))
            .timeout(_kTimeout);
        final data = jsonDecode(utf8.decode(resp.bodyBytes));
        if (resp.statusCode == 200 && data is Map && data['ok'] == true) {
          final saved =
              data['alias'] is String ? data['alias'] as String : alias;
          isError = false;
          message = 'Guardado. El técnico te verá como "$saved".';
          _alias = saved;
          _loaded = true;
          _editing = false;
          _retry?.cancel();
        } else if (data is Map && data['error'] is String) {
          message = data['error'] as String;
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

  @override
  Widget build(BuildContext context) {
    final showForm = _alias.isEmpty || _editing;
    final children = <Widget>[
      const Text('Tu nombre para el técnico',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
      const SizedBox(height: 6),
    ];
    if (showForm) {
      if (_alias.isEmpty) {
        children.add(Text(
            _loaded
                ? 'Escribe tu nombre (por ejemplo "Juan Pérez - Oficina") '
                    'para que el técnico te reconozca. Es opcional.'
                : 'Escribe tu nombre para que el técnico te reconozca. '
                    'Es opcional.',
            style: const TextStyle(fontSize: 12)));
      }
      children.addAll([
        const SizedBox(height: 6),
        TextField(
          controller: _controller,
          maxLength: 40,
          enabled: !_saving,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            isDense: true,
            counterText: '',
            hintText: 'Nombre - Lugar',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 8),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: _kBlue, foregroundColor: Colors.white),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Guardando…' : 'Guardar'),
        ),
      ]);
    } else {
      children.addAll([
        Text(_alias, style: const TextStyle(fontSize: 13)),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => setState(() {
              _editing = true;
              _message = '';
              _controller.text = _alias;
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
