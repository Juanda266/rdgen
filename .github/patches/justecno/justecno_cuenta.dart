// Soporte JUSTECNO: la Cuenta JUSTECNO dentro de la app y la confirmación con el PIN, la huella o la cara.
// justecno_tecnicos.py lo copia a flutter/lib/common/widgets/justecno_cuenta.dart en todas las plataformas (y
// agrega local_auth_windows y local_auth_darwin a pubspec.yaml). Lo usan justecno_cards.dart (PC),
// justecno_android.py (Android) y ServerModel.sendLoginResponse (al aceptar a un técnico).
//
// - JtCuentaDialogo: iniciar sesión sin abrir el navegador. El cliente escribe su correo y le llega un código de
//   6 números; si el correo no tiene cuenta, la crea ahí mismo (nombre completo, «¿Cómo prefieres que te
//   llamemos?» opcional y teléfono opcional).
//   Habla con soporte.justecno.com/wp-json/justecno/v1/app-cuenta/ (justecno-cuenta-app.php) usando el código
//   de un solo uso del equipo (rustdesk.justecno.com/app-api/v1/sesion/iniciar). Queda «Iniciar sesión en el
//   navegador» (la página de antes, con contraseña y la guía por voz).
// - jtVerificarPersona: Windows Hello (PIN, huella o cara), Touch ID o la contraseña del Mac, el PIN, patrón,
//   huella o cara del celular (MainActivity "jt_verificar_persona") o la contraseña del equipo en Linux (pkexec).
//   Si el equipo no tiene nada de eso, un código al correo de la cuenta. Se pide al abrir la app y antes de
//   dejar entrar a un técnico.
// - jtAccesoHasta / jtGuardarAcceso: «Permitir que un técnico entre sin que estés» por unas horas (solo PC):
//   mientras dure, la app acepta sola a los técnicos de JUSTECNO (los técnicos se siguen verificando en el
//   servidor, justecno_tecnicos.rs). Se guarda en un archivo de la app (lo lee también la ventana de conexiones).
// Sin red o si el servidor no responde, nunca deja al cliente sin poder recibir soporte.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart' show gFFI, globalKey;
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:http/http.dart' as http;
import 'package:local_auth_darwin/local_auth_darwin.dart';
import 'package:local_auth_windows/local_auth_windows.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

// 'clientes' (Soporte JUSTECNO) o 'tecnicos' (JUSTECNO Técnico). justecno_tecnicos.py la reemplaza.
const String kJtVariante = 'clientes';

const String _kJtSesion = 'https://rustdesk.justecno.com/app-api/v1/sesion';
const String _kJtCuenta = 'https://soporte.justecno.com/wp-json/justecno/v1/app-cuenta';
const Duration _kJtEspera = Duration(seconds: 20);
const Color _kJtAzul = Color(0xFF2F65BA);
const String _kJtSinRed =
    'No pudimos comunicarnos con JUSTECNO. Revisa tu conexión a internet e inténtalo de nuevo.';

// ------------------------------------------------------------------------------------------- Servidor

class _JtResp {
  final int estado;
  final Map<String, dynamic> d;
  const _JtResp(this.estado, this.d);
  bool get ok => estado == 200 && d['ok'] == true;
  String get error => d['error'] is String ? d['error'] as String : _kJtSinRed;
  String get campo => d['campo'] is String ? d['campo'] as String : '';
  String texto(String k) => d[k] is String ? d[k] as String : '';
}

Map<String, String> _jtCabeceras() => {
      'User-Agent': 'SoporteJUSTECNO/${Platform.operatingSystem}',
      'Accept': 'application/json',
      'Content-Type': 'application/json; charset=utf-8',
      'X-JT-App': '1',
    };

Future<_JtResp> _jtPost(String url, Map<String, dynamic> datos) async {
  try {
    final r = await http
        .post(Uri.parse(url), headers: _jtCabeceras(), body: jsonEncode(datos))
        .timeout(_kJtEspera);
    final d = jsonDecode(utf8.decode(r.bodyBytes));
    if (d is Map<String, dynamic>) return _JtResp(r.statusCode, d);
  } catch (_) {}
  return const _JtResp(0, {});
}

Future<Map<String, String>?> jtIds() async {
  try {
    final id = (await bind.mainGetMyId()).trim();
    final uuid = (await bind.mainGetUuid()).trim();
    if (id.isEmpty || uuid.isEmpty) return null;
    return {'id': id, 'uuid': uuid};
  } catch (_) {
    return null;
  }
}

// Código de un solo uso del equipo (dura 20 minutos; el servidor da el mismo si le quedan más de 5)
String _jtCodigo = '';
String _jtUrlWeb = '';
DateTime _jtCodigoHasta = DateTime(2000);

Future<String?> _jtCodigoEquipo({bool nuevo = false}) async {
  if (!nuevo && _jtCodigo.isNotEmpty && DateTime.now().isBefore(_jtCodigoHasta)) return _jtCodigo;
  final ids = await jtIds();
  if (ids == null) return null;
  final r = await _jtPost('$_kJtSesion/iniciar', ids);
  if (!r.ok || r.texto('codigo').length != 8) return null;
  _jtCodigo = r.texto('codigo');
  _jtUrlWeb = r.texto('url').startsWith('https://soporte.justecno.com/') ? r.texto('url') : '';
  final dura = r.d['vence_en'] is int ? r.d['vence_en'] as int : 600;
  _jtCodigoHasta = DateTime.now().add(Duration(seconds: dura - 60));
  return _jtCodigo;
}

Future<_JtResp> _jtCuenta(String accion, Map<String, dynamic> datos) async {
  final c = await _jtCodigoEquipo();
  if (c == null) return const _JtResp(0, {});
  var r = await _jtPost('$_kJtCuenta/$accion', {'c': c, ...datos});
  if (r.campo == 'vencido' && (accion == 'correo' || accion == 'desbloqueo')) {
    final c2 = await _jtCodigoEquipo(nuevo: true);
    if (c2 != null) r = await _jtPost('$_kJtCuenta/$accion', {'c': c2, ...datos});
  }
  return r;
}

/// El usuario se muestra solo si no es el mismo nombre completo (sin contar tildes ni mayúsculas).
bool jtUsuarioDistinto(String nombre, String usuario) {
  String f(String s) {
    const a = 'áéíóúüñàèìòùÁÉÍÓÚÜÑÀÈÌÒÙ', b = 'aeiouunaeiouAEIOUUNAEIOU';
    final sb = StringBuffer();
    for (final ch in s.trim().split('')) {
      final i = a.indexOf(ch);
      sb.write(i >= 0 ? b[i] : ch);
    }
    return sb.toString().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  return usuario.trim().isNotEmpty && f(nombre) != f(usuario);
}

/// null si no se pudo saber (sin red, el equipo aún no se reporta…)
Future<Map<String, String>?> jtSesionActual() async {
  final ids = await jtIds();
  if (ids == null) return null;
  try {
    final r = await http
        .get(Uri.parse(_kJtSesion).replace(queryParameters: ids), headers: _jtCabeceras())
        .timeout(_kJtEspera);
    final d = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode == 200 && d is Map && d['ok'] == true) {
      if (d['conectado'] != true) return {};
      return {
        'nombre': d['nombre'] is String ? d['nombre'] as String : '',
        'usuario': d['usuario'] is String ? d['usuario'] as String : '',
      };
    }
  } catch (_) {}
  return null;
}

// ------------------------------------------------------------------------------------------- Apoyo visual

const TextStyle _kJtTexto = TextStyle(fontSize: 14, height: 1.4);

Widget _jtBoton(String texto, VoidCallback? onPressed, {bool ocupado = false}) => SizedBox(
      height: 44,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(backgroundColor: _kJtAzul, foregroundColor: Colors.white),
        onPressed: ocupado ? null : onPressed,
        child: ocupado
            ? const SizedBox(
                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Text(texto, style: const TextStyle(fontSize: 15)),
      ),
    );

Widget _jtCampo(TextEditingController c,
        {required String etiqueta,
        String? ayuda,
        String? error,
        TextInputType? teclado,
        bool autofocus = false,
        List<TextInputFormatter>? formato,
        Iterable<String>? autocompletar,
        TextCapitalization mayusculas = TextCapitalization.none,
        ValueChanged<String>? alEnviar}) =>
    Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TextField(
        controller: c,
        autofocus: autofocus,
        keyboardType: teclado,
        inputFormatters: formato,
        autofillHints: autocompletar,
        textCapitalization: mayusculas,
        onSubmitted: alEnviar,
        decoration: InputDecoration(
          labelText: etiqueta,
          helperText: error == null || error.isEmpty ? ayuda : null,
          helperMaxLines: 2,
          errorText: error == null || error.isEmpty ? null : error,
          errorMaxLines: 3,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );

Widget _jtError(String texto) => texto.isEmpty
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(texto, style: const TextStyle(fontSize: 13, color: Colors.red)),
      );

Widget _jtEnlace(String texto, VoidCallback? onPressed) => Align(
      alignment: Alignment.center,
      child: TextButton(onPressed: onPressed, child: Text(texto, textAlign: TextAlign.center)),
    );

// ------------------------------------------------------------------------------------------- Iniciar sesión

enum _JtPaso { correo, codigo, crear, web }

/// Contenido del aviso «Inicia sesión para recibir soporte» (va dentro de un AlertDialog que no se cierra).
/// [alListo] recibe el nombre y el usuario de la cuenta cuando el equipo queda conectado.
class JtCuentaDialogo extends StatefulWidget {
  final void Function(String nombre, String usuario) alListo;
  final bool celular;
  const JtCuentaDialogo({Key? key, required this.alListo, this.celular = false}) : super(key: key);

  @override
  State<JtCuentaDialogo> createState() => _JtCuentaDialogoState();
}

class _JtCuentaDialogoState extends State<JtCuentaDialogo> {
  final _correo = TextEditingController();
  final _codigo = TextEditingController();
  final _nombre = TextEditingController();
  final _usuario = TextEditingController();
  final _telefono = TextEditingController();
  _JtPaso _paso = _JtPaso.correo;
  bool _ocupado = false;
  String _error = '';
  Map<String, String> _errores = {};
  String _aviso = '';
  String _ficha = '';
  DateTime _reenviarDesde = DateTime(2000);
  Timer? _tic;
  Timer? _espera;
  DateTime _esperaHasta = DateTime(2000);

  String get _equipo => widget.celular ? 'celular' : 'equipo';

  @override
  void initState() {
    super.initState();
    _tic = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _paso == _JtPaso.codigo) setState(() {});
    });
  }

  @override
  void dispose() {
    _tic?.cancel();
    _espera?.cancel();
    for (final c in [_correo, _codigo, _nombre, _usuario, _telefono]) {
      c.dispose();
    }
    super.dispose();
  }

  void _set(VoidCallback f) {
    if (mounted) setState(f);
  }

  Future<void> _enviarCorreo() async {
    final correo = _correo.text.trim().toLowerCase();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(correo)) {
      _set(() => _errores = {'correo': 'Escribe un correo válido, por ejemplo nombre@gmail.com.'});
      return;
    }
    _set(() {
      _ocupado = true;
      _error = '';
      _errores = {};
    });
    final r = await _jtCuenta('correo', {'correo': correo});
    _set(() {
      _ocupado = false;
      if (r.ok) {
        _paso = _JtPaso.codigo;
        _codigo.clear();
        _aviso = '';
        _reenviarDesde = DateTime.now().add(const Duration(seconds: 60));
      } else if (r.campo == 'correo') {
        _errores = {'correo': r.error};
      } else {
        _error = r.error;
      }
    });
  }

  Future<void> _verificar() async {
    final codigo = _codigo.text.replaceAll(RegExp(r'\D'), '');
    if (codigo.length != 6) {
      _set(() => _errores = {'codigo': 'El código tiene 6 números.'});
      return;
    }
    _set(() {
      _ocupado = true;
      _error = '';
      _errores = {};
      _aviso = '';
    });
    final r = await _jtCuenta('verificar', {'codigo': codigo});
    if (r.ok && r.d['listo'] == true) {
      widget.alListo(r.texto('nombre'), r.texto('usuario'));
      return;
    }
    _set(() {
      _ocupado = false;
      if (r.ok && r.d['nuevo'] == true) {
        _ficha = r.texto('ficha');
        _paso = _JtPaso.crear;
      } else if (r.campo == 'vencido') {
        _paso = _JtPaso.correo;
        _error = r.error;
      } else if (r.campo == 'codigo') {
        _errores = {'codigo': r.error};
      } else {
        _error = r.error;
      }
    });
  }

  Future<void> _reenviar() async {
    _set(() {
      _ocupado = true;
      _error = '';
      _errores = {};
    });
    final r = await _jtCuenta('correo', {'correo': _correo.text.trim().toLowerCase()});
    _set(() {
      _ocupado = false;
      if (r.ok) {
        _codigo.clear();
        _aviso = 'Te enviamos un código nuevo.';
        _reenviarDesde = DateTime.now().add(const Duration(seconds: 60));
      } else {
        _error = r.error;
      }
    });
  }

  Future<void> _crear() async {
    final nombre = _nombre.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final usuario = _usuario.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final telefono = _telefono.text.replaceAll(RegExp(r'[^\d+]'), '');
    final errores = <String, String>{};
    if (nombre.length < 5 || !nombre.contains(' ')) errores['nombre'] = 'Escribe tu nombre y tu apellido.';
    if (usuario.isNotEmpty && !RegExp(r"^[\p{L}0-9][\p{L}0-9 .'_\-]{2,39}$", unicode: true).hasMatch(usuario)) {
      errores['usuario'] = 'Usa de 3 a 40 letras, números o espacios.';
    }
    if (telefono.isNotEmpty && !RegExp(r'^\+?\d{7,15}$').hasMatch(telefono)) {
      errores['telefono'] = 'Escribe solo números, por ejemplo 3001234567.';
    }
    if (errores.isNotEmpty) {
      _set(() => _errores = errores);
      return;
    }
    _set(() {
      _ocupado = true;
      _error = '';
      _errores = {};
    });
    final r = await _jtCuenta('crear', {'ficha': _ficha, 'nombre': nombre, 'usuario': usuario, 'telefono': telefono});
    if (r.ok && r.d['listo'] == true) {
      widget.alListo(r.texto('nombre'), r.texto('usuario'));
      return;
    }
    _set(() {
      _ocupado = false;
      if (r.campo == 'vencido') {
        _paso = _JtPaso.correo;
        _error = r.error;
      } else if (['nombre', 'usuario', 'telefono'].contains(r.campo)) {
        _errores = {r.campo: r.error};
      } else {
        _error = r.error;
      }
    });
  }

  // La página de antes (entrar con contraseña, guía por voz) en el navegador; la app pregunta cada 5 segundos
  Future<void> _abrirWeb() async {
    _set(() {
      _ocupado = true;
      _error = '';
    });
    final c = await _jtCodigoEquipo();
    if (c == null || _jtUrlWeb.isEmpty) {
      _set(() {
        _ocupado = false;
        _error = _kJtSinRed;
      });
      return;
    }
    try {
      await launchUrl(Uri.parse(_jtUrlWeb), mode: LaunchMode.externalApplication);
    } catch (_) {}
    _esperaHasta = DateTime.now().add(const Duration(minutes: 20));
    _espera?.cancel();
    _espera = Timer.periodic(const Duration(seconds: 5), (t) async {
      if (!mounted || DateTime.now().isAfter(_esperaHasta)) {
        t.cancel();
        _set(() => _paso = _JtPaso.correo);
        return;
      }
      final s = await jtSesionActual();
      if (s != null && s.isNotEmpty && mounted) {
        t.cancel();
        widget.alListo(s['nombre'] ?? '', s['usuario'] ?? '');
      }
    });
    _set(() {
      _ocupado = false;
      _paso = _JtPaso.web;
    });
  }

  List<Widget> _contenido() {
    switch (_paso) {
      case _JtPaso.correo:
        return [
          Text(
              'Así el técnico sabe quién eres antes de conectarse a tu $_equipo. '
              'Si aún no tienes cuenta, la creamos en un momento.',
              style: _kJtTexto),
          _jtCampo(_correo,
              etiqueta: 'Tu correo electrónico',
              ayuda: 'Te enviaremos un código de 6 números.',
              error: _errores['correo'],
              teclado: TextInputType.emailAddress,
              autocompletar: const [AutofillHints.email],
              autofocus: true,
              alEnviar: (_) => _enviarCorreo()),
          const SizedBox(height: 14),
          _jtBoton('Enviarme el código', _enviarCorreo, ocupado: _ocupado),
          _jtError(_error),
          const SizedBox(height: 6),
          _jtEnlace('Iniciar sesión en el navegador (con contraseña)', _ocupado ? null : _abrirWeb),
        ];
      case _JtPaso.codigo:
        final falta = _reenviarDesde.difference(DateTime.now()).inSeconds;
        return [
          Text('Te enviamos un código a ${_correo.text.trim().toLowerCase()}. Escríbelo aquí:', style: _kJtTexto),
          _jtCampo(_codigo,
              etiqueta: 'Código de 6 números',
              ayuda: 'Si no lo ves, revisa la carpeta de spam o «Promociones».',
              error: _errores['codigo'],
              teclado: TextInputType.number,
              autofocus: true,
              autocompletar: const [AutofillHints.oneTimeCode],
              formato: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              alEnviar: (_) => _verificar()),
          const SizedBox(height: 14),
          _jtBoton('Continuar', _verificar, ocupado: _ocupado),
          if (_aviso.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_aviso, style: TextStyle(fontSize: 13, color: Colors.green.shade700)),
            ),
          _jtError(_error),
          const SizedBox(height: 6),
          Wrap(alignment: WrapAlignment.center, children: [
            TextButton(
              onPressed: _ocupado || falta > 0 ? null : _reenviar,
              child: Text(falta > 0 ? 'Reenviar código ($falta s)' : 'Reenviar código'),
            ),
            TextButton(
              onPressed: _ocupado
                  ? null
                  : () => _set(() {
                        _paso = _JtPaso.correo;
                        _error = '';
                        _errores = {};
                      }),
              child: const Text('Cambiar el correo'),
            ),
          ]),
        ];
      case _JtPaso.crear:
        return [
          Text('Tu correo quedó confirmado. Crea tu Cuenta JUSTECNO con estos datos:', style: _kJtTexto),
          _jtCampo(_nombre,
              etiqueta: 'Nombre completo',
              ayuda: 'Tu nombre y tu apellido. Así te verá el técnico.',
              error: _errores['nombre'],
              autofocus: true,
              autocompletar: const [AutofillHints.name],
              mayusculas: TextCapitalization.words),
          _jtCampo(_usuario,
              etiqueta: '¿Cómo prefieres que te llamemos? (opcional)',
              ayuda: 'Si lo dejas vacío, usamos tu nombre completo.',
              error: _errores['usuario'],
              autocompletar: const [AutofillHints.nickname],
              mayusculas: TextCapitalization.words),
          _jtCampo(_telefono,
              etiqueta: 'Celular (opcional)',
              ayuda: 'Para avisarte de tus citas. No lo mostramos a nadie.',
              error: _errores['telefono'],
              teclado: TextInputType.phone,
              autocompletar: const [AutofillHints.telephoneNumber],
              alEnviar: (_) => _crear()),
          const SizedBox(height: 14),
          _jtBoton('Crear mi cuenta', _crear, ocupado: _ocupado),
          _jtError(_error),
        ];
      case _JtPaso.web:
        return [
          const Text('Termina en el navegador: entra a tu Cuenta JUSTECNO o créala y pulsa «Conectar este equipo». '
              'En la página, el botón «Escuchar cómo hacerlo» te explica todo en voz alta.',
              style: _kJtTexto),
          const SizedBox(height: 14),
          const Text('Esperando a que termines en el navegador…',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const LinearProgressIndicator(),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: () => launchUrl(Uri.parse(_jtUrlWeb), mode: LaunchMode.externalApplication),
            child: const Text('Abrir otra vez la página'),
          ),
          _jtEnlace('Volver e iniciar sesión aquí con mi correo', () {
            _espera?.cancel();
            _set(() => _paso = _JtPaso.correo);
          }),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    return AutofillGroup(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _contenido(),
      ),
    );
  }
}

/// Muestra el aviso que no se cierra hasta que el equipo quede conectado a una cuenta.
Future<Map<String, String>?> jtMostrarInicioSesion(BuildContext context,
    {bool celular = false, Color? fondo}) async {
  Map<String, String>? cuenta;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: fondo,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Inicia sesión para recibir soporte'),
        scrollable: true,
        content: SizedBox(
          width: 420,
          child: JtCuentaDialogo(
            celular: celular,
            alListo: (nombre, usuario) {
              cuenta = {'nombre': nombre, 'usuario': usuario};
              jtMarcarVerificado();
              Navigator.of(ctx).pop();
            },
          ),
        ),
      ),
    ),
  );
  return cuenta;
}

// ------------------------------------------------------------------------------------------- Confirmar que es la persona

enum JtNativo { ok, cancelado, noDisponible }

DateTime _jtVerificadoEn = DateTime(2000);

/// Después de iniciar sesión con el código del correo no se vuelve a pedir enseguida.
void jtMarcarVerificado() => _jtVerificadoEn = DateTime.now();

bool jtVerificadoHace(Duration d) => DateTime.now().difference(_jtVerificadoEn) < d;

/// Cómo se llama lo que pide este equipo (para los textos).
String jtNombreMetodo() {
  if (Platform.isWindows) return 'el PIN, la huella o la cara (Windows Hello)';
  if (Platform.isMacOS) return 'Touch ID o la contraseña del Mac';
  if (Platform.isAndroid) return 'el PIN, el patrón, la huella o la cara del celular';
  return 'la contraseña de este equipo';
}

Future<JtNativo> _jtNativo(String motivo) async {
  try {
    if (Platform.isWindows) {
      final la = LocalAuthWindows();
      if (!await la.isDeviceSupported()) return JtNativo.noDisponible;
      return await la.authenticate(localizedReason: motivo, authMessages: const <AuthMessages>[])
          ? JtNativo.ok
          : JtNativo.cancelado;
    }
    if (Platform.isMacOS) {
      final la = LocalAuthDarwin();
      if (!await la.isDeviceSupported()) return JtNativo.noDisponible;
      return await la.authenticate(
              localizedReason: motivo,
              authMessages: const <AuthMessages>[],
              options: const AuthenticationOptions(useErrorDialogs: false))
          ? JtNativo.ok
          : JtNativo.cancelado;
    }
    if (Platform.isAndroid) {
      final r = await gFFI.invokeMethodWithResult<String>('jt_verificar_persona', motivo);
      if (r == 'ok') return JtNativo.ok;
      if (r == 'cancelado') return JtNativo.cancelado;
      return JtNativo.noDisponible;
    }
    if (Platform.isLinux) {
      // La ventana del sistema que pide la contraseña (la misma que al instalar las actualizaciones)
      if (!File('/usr/bin/pkexec').existsSync()) return JtNativo.noDisponible;
      final r = await Process.run('/usr/bin/pkexec', ['/bin/true']);
      if (r.exitCode == 0) return JtNativo.ok;
      if (r.exitCode == 126) return JtNativo.cancelado;
      return JtNativo.noDisponible;
    }
  } on PlatformException catch (e) {
    if (e.code == 'NotAvailable' || e.code == 'NotEnrolled' || e.code == 'PasscodeNotSet') {
      return JtNativo.noDisponible;
    }
    return JtNativo.cancelado;
  } catch (_) {}
  return JtNativo.noDisponible;
}

Future<bool>? _jtVerificando;

/// Pide el PIN, la huella o la cara (o un código al correo si el equipo no tiene). true si es la persona.
/// [obligatorio]: al abrir la app no se puede cancelar.
Future<bool> jtVerificarPersona(BuildContext context,
    {required String titulo, required String motivo, bool obligatorio = false, Color? fondo}) {
  final ya = _jtVerificando;
  if (ya != null) return ya;
  final f = showDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierColor: fondo,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(titulo),
        scrollable: true,
        content: SizedBox(
          width: 360,
          child: _JtVerificar(
            motivo: motivo,
            obligatorio: obligatorio,
            alTerminar: (ok) => Navigator.of(ctx).pop(ok),
          ),
        ),
      ),
    ),
  ).then((ok) {
    if (ok == true) jtMarcarVerificado();
    return ok == true;
  }).whenComplete(() => _jtVerificando = null);
  _jtVerificando = f;
  return f;
}

class _JtVerificar extends StatefulWidget {
  final String motivo;
  final bool obligatorio;
  final void Function(bool ok) alTerminar;
  const _JtVerificar({required this.motivo, required this.obligatorio, required this.alTerminar});

  @override
  State<_JtVerificar> createState() => _JtVerificarState();
}

class _JtVerificarState extends State<_JtVerificar> {
  final _codigo = TextEditingController();
  bool _esperando = true; // la ventana del sistema está abierta
  bool _sinMetodo = false;
  bool _porCorreo = false;
  bool _ocupado = false;
  String _correo = '';
  String _error = '';
  bool _terminado = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _usarEquipo());
  }

  @override
  void dispose() {
    _codigo.dispose();
    super.dispose();
  }

  void _set(VoidCallback f) {
    if (mounted) setState(f);
  }

  void _fin(bool ok) {
    if (_terminado) return;
    _terminado = true;
    widget.alTerminar(ok);
  }

  Future<void> _usarEquipo() async {
    _set(() {
      _esperando = true;
      _error = '';
    });
    final r = await _jtNativo(widget.motivo);
    if (r == JtNativo.ok) return _fin(true);
    if (r == JtNativo.noDisponible) {
      _set(() {
        _sinMetodo = true;
        _esperando = false;
      });
      return _pedirCodigo();
    }
    _set(() => _esperando = false);
  }

  Future<void> _pedirCodigo() async {
    _set(() {
      _porCorreo = true;
      _ocupado = true;
      _error = '';
    });
    final r = await _jtCuenta('desbloqueo', {});
    if (!r.ok && (r.campo == 'sin_cuenta' || r.estado == 0 || r.estado >= 500)) {
      // Sin sesión o sin red no hay a qué correo mandarlo: no se deja al cliente sin soporte
      return _fin(true);
    }
    _set(() {
      _ocupado = false;
      if (r.ok) {
        _correo = r.texto('correo');
      } else {
        _error = r.error;
      }
    });
  }

  Future<void> _verificarCodigo() async {
    final codigo = _codigo.text.replaceAll(RegExp(r'\D'), '');
    if (codigo.length != 6) {
      _set(() => _error = 'El código tiene 6 números.');
      return;
    }
    _set(() {
      _ocupado = true;
      _error = '';
    });
    final r = await _jtCuenta('verificar', {'codigo': codigo});
    if (r.ok && r.d['desbloqueado'] == true) return _fin(true);
    if (r.estado == 0) return _fin(true);
    _set(() {
      _ocupado = false;
      _error = r.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hijos = <Widget>[];
    if (!_porCorreo) {
      hijos.addAll([
        Text('${widget.motivo}. Usa ${jtNombreMetodo()}.', style: _kJtTexto),
        const SizedBox(height: 14),
        if (_esperando) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          const Text('Sigue las instrucciones de la ventana que se abrió.', style: TextStyle(fontSize: 13)),
        ] else
          _jtBoton('Intentar de nuevo', _usarEquipo),
        _jtError(_error),
        const SizedBox(height: 6),
        _jtEnlace('Usar un código por correo', _pedirCodigo),
      ]);
    } else {
      hijos.addAll([
        Text(
            _sinMetodo
                ? 'Este equipo no tiene PIN, huella ni cara configurados, así que te enviamos un código al correo '
                    'de tu cuenta${_correo.isEmpty ? '' : ' ($_correo)'}.'
                : 'Te enviamos un código al correo de tu cuenta${_correo.isEmpty ? '' : ' ($_correo)'}.',
            style: _kJtTexto),
        _jtCampo(_codigo,
            etiqueta: 'Código de 6 números',
            teclado: TextInputType.number,
            autofocus: true,
            autocompletar: const [AutofillHints.oneTimeCode],
            formato: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            alEnviar: (_) => _verificarCodigo()),
        const SizedBox(height: 14),
        _jtBoton('Continuar', _verificarCodigo, ocupado: _ocupado),
        _jtError(_error),
        const SizedBox(height: 6),
        Wrap(alignment: WrapAlignment.center, children: [
          TextButton(onPressed: _ocupado ? null : _pedirCodigo, child: const Text('Enviar otro código')),
          if (!_sinMetodo)
            TextButton(
              onPressed: _ocupado
                  ? null
                  : () {
                      _set(() => _porCorreo = false);
                      _usarEquipo();
                    },
              child: const Text('Usar el PIN, la huella o la cara'),
            ),
        ]),
      ]);
    }
    if (!widget.obligatorio) {
      hijos.add(_jtEnlace('Cancelar', () => _fin(false)));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: hijos,
    );
  }
}

// ------------------------------------------------------------------------------------------- Al aceptar a un técnico

Future<File?> _jtArchivoAcceso() async {
  try {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}jt-acceso.json');
  } catch (_) {
    return null;
  }
}

/// Hasta cuándo puede entrar un técnico sin que el cliente acepte (null: no está permitido).
Future<DateTime?> jtAccesoHasta() async {
  try {
    final f = await _jtArchivoAcceso();
    if (f == null || !await f.exists()) return null;
    final d = jsonDecode(await f.readAsString());
    final hasta = DateTime.fromMillisecondsSinceEpoch((d['hasta'] as num).toInt());
    // como mucho 24 horas desde que se dio el permiso (por si el reloj del equipo cambia)
    final desde = DateTime.fromMillisecondsSinceEpoch((d['desde'] as num).toInt());
    if (hasta.difference(desde) > const Duration(hours: 24, minutes: 1)) return null;
    return DateTime.now().isBefore(hasta) ? hasta : null;
  } catch (_) {
    return null;
  }
}

Future<void> jtGuardarAcceso(Duration? cuanto) async {
  final f = await _jtArchivoAcceso();
  if (f == null) return;
  try {
    if (cuanto == null) {
      if (await f.exists()) await f.delete();
      return;
    }
    final ahora = DateTime.now();
    await f.writeAsString(jsonEncode(
        {'desde': ahora.millisecondsSinceEpoch, 'hasta': ahora.add(cuanto).millisecondsSinceEpoch}));
  } catch (_) {}
}

Future<bool> jtAccesoVigente() async => kJtVariante == 'clientes' && await jtAccesoHasta() != null;

/// ServerModel.sendLoginResponse: antes de dejar entrar al técnico, el cliente confirma que es él.
Future<bool> jtAutorizarConexion() async {
  if (kJtVariante != 'clientes') return true;
  if (await jtAccesoHasta() != null) return true;
  if (jtVerificadoHace(const Duration(minutes: 2))) return true;
  final ctx = globalKey.currentContext;
  if (ctx == null) return true;
  return jtVerificarPersona(ctx,
      titulo: 'Confirma que eres tú', motivo: 'Confirma que eres tú para dejar entrar al técnico');
}
