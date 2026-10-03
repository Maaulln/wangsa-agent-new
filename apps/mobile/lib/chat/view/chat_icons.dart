import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Ikon permukaan chat, satu tempat. Memakai Lucide bobot 300 (garis
/// tipis, tanpa isian) supaya selaras dengan arah "soft minimalism" —
/// ikon Material bawaan terlalu tebal/padat di atas kaca gelap. Halaman
/// chat tidak memanggil `Icons.*` langsung; ganti di sini saja.
abstract final class ChatIcons {
  static const menu = LucideIcons.textAlignStart300;
  static const newChat = LucideIcons.squarePen300;
  static const history = LucideIcons.messageCircle300;
  static const settings = LucideIcons.settings300;
  static const attach = LucideIcons.plus300;
  static const microphone = LucideIcons.mic300;
  static const voice = LucideIcons.audioLines300;
  static const send = LucideIcons.arrowUp300;
  static const stop = LucideIcons.square300;
  static const search = LucideIcons.search300;
  static const web = LucideIcons.globe300;
  static const image = LucideIcons.image300;
  static const camera = LucideIcons.camera300;
  static const gallery = LucideIcons.images300;
  static const brokenImage = LucideIcons.imageOff300;
  static const file = LucideIcons.fileText300;
  static const terminal = LucideIcons.terminal300;
  static const tool = LucideIcons.sparkles300;
  static const agent = LucideIcons.sparkles300;
  static const model = LucideIcons.cpu300;
  static const source = LucideIcons.globe300;
  static const copy = LucideIcons.copy300;
  static const readAloud = LucideIcons.volume2300;
  static const share = LucideIcons.share300;
  static const latest = LucideIcons.arrowDown300;
  static const refresh = LucideIcons.rotateCw300;
  static const error = LucideIcons.circleAlert300;
  static const info = LucideIcons.info300;
  static const success = LucideIcons.circleCheck300;
  static const check = LucideIcons.check300;
  static const expand = LucideIcons.chevronDown300;
  static const collapse = LucideIcons.chevronUp300;
  static const chevronRight = LucideIcons.chevronRight300;
  static const back = LucideIcons.arrowLeft300;
  static const close = LucideIcons.x300;
  static const delete = LucideIcons.trash2300;
  static const profile = LucideIcons.user300;
  static const edit = LucideIcons.pencil300;
  static const reasoning = LucideIcons.brain300;
  static const bot = LucideIcons.bot300;
  static const play = LucideIcons.play300;
  static const pause = LucideIcons.pause300;
  static const signOut = LucideIcons.logOut300;
  static const signIn = LucideIcons.logIn300;
  static const key = LucideIcons.keyRound300;
  static const usage = LucideIcons.gauge300;
  static const tune = LucideIcons.slidersHorizontal300;
  static const offline = LucideIcons.cloudOff300;

  static IconData forTool(String name) {
    final tool = name.toLowerCase();
    if (tool.contains('search') ||
        tool.contains('web') ||
        tool.contains('browser')) {
      return web;
    }
    if (tool.contains('file') ||
        tool.contains('read') ||
        tool.contains('write')) {
      return file;
    }
    if (tool.contains('terminal') ||
        tool.contains('command') ||
        tool.contains('exec')) {
      return terminal;
    }
    if (tool.contains('image') || tool.contains('photo')) return image;
    return tool.contains('extract') || tool.contains('navigate')
        ? web
        : ChatIcons.tool;
  }
}
