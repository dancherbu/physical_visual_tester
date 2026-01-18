import 'dart:io';

import 'package:flutter/material.dart';

import 'shell/desktop_shell.dart';
import 'shell/main_shell.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Physical Visual Tester',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: Platform.isWindows ? const DesktopShell() : const MainShell(),
    );
  }
}
