import 'package:flutter/material.dart';

/// Satu set ikon outline untuk permukaan percakapan mobile Wangsa.
/// Bentuknya sengaja sederhana dan familiar seperti aplikasi chat AI modern.
abstract final class ChatIcons {
  static const menu = Icons.menu_rounded;
  static const newChat = Icons.edit_square;
  static const history = Icons.chat_bubble_outline_rounded;
  static const settings = Icons.settings_outlined;
  static const attach = Icons.add_rounded;
  static const microphone = Icons.mic_none_rounded;
  static const send = Icons.arrow_upward_rounded;
  static const stop = Icons.stop_rounded;
  static const search = Icons.search;
  static const web = Icons.language_rounded;
  static const image = Icons.image_outlined;
  static const file = Icons.description_outlined;
  static const terminal = Icons.terminal;
  static const tool = Icons.auto_awesome_outlined;
  static const source = Icons.language_rounded;
  static const copy = Icons.content_copy_rounded;
  static const readAloud = Icons.volume_up_outlined;
  static const share = Icons.ios_share_outlined;
  static const latest = Icons.arrow_downward_rounded;
  static const refresh = Icons.refresh_rounded;
  static const error = Icons.error_outline_rounded;
  static const success = Icons.check_circle_outline_rounded;
  static const expand = Icons.keyboard_arrow_down_rounded;
  static const collapse = Icons.keyboard_arrow_up_rounded;

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
