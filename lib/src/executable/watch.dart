// Copyright 2018 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'dart:collection';

import 'package:path/path.dart' as p;
import 'package:stack_trace/stack_trace.dart';
import 'package:stream_transform/stream_transform.dart';
import 'package:watcher/watcher.dart';

import '../exception.dart';
import '../importer/filesystem.dart';
import '../io.dart';
import '../stylesheet_graph.dart';
import '../util/multi_dir_watcher.dart';
import '../utils.dart';
import 'compile_stylesheet.dart';
import 'options.dart';

/// Watches all the files in [graph] for changes and updates them as necessary.
Future<void> watch(ExecutableOptions options, StylesheetGraph graph) async {
  var directoriesToWatch = [
    ..._sourceDirectoriesToDestinations(options).keys,
    for (var dir in _sourcesToDestinations(options).keys) p.dirname(dir),
    ...options.loadPaths
  ];

  var dirWatcher = MultiDirWatcher(poll: options.poll);
  await Future.wait(directoriesToWatch.map((dir) {
    // If a directory doesn't exist, watch its parent directory so that we're
    // notified once it starts existing.
    while (!dirExists(dir)) {
      dir = p.dirname(dir);
    }
    return dirWatcher.watch(dir);
  }));

  // Before we start paying attention to changes, compile all the stylesheets as
  // they currently exist. This ensures that changes that come in update a
  // known-good state.
  var watcher = _Watcher(options, graph);
  for (var entry in _sourcesToDestinations(options).entries) {
    graph.addCanonical(FilesystemImporter('.'),
        p.toUri(canonicalize(entry.key)), p.toUri(entry.key),
        recanonicalize: false);
    var success =
        await watcher.compile(entry.key, entry.value, ifModified: true);
    if (!success && options.stopOnError) {
      dirWatcher.events.listen(null).cancel();
      return;
    }
  }

  print("Sass is watching for changes. Press Ctrl-C to stop.\n");
  await watcher.watch(dirWatcher);
}

/// Holds state that's shared across functions that react to changes on the
/// filesystem.
class _Watcher {
  /// The options for the Sass executable.
  final ExecutableOptions _options;

  /// The graph of stylesheets being compiled.
  final StylesheetGraph _graph;

  _Watcher(this._options, this._graph);

  /// Compiles the stylesheet at [source] to [destination], and prints any
  /// errors that occur.
  ///
  /// Returns whether or not compilation succeeded.
  Future<bool> compile(String source, String destination,
      {bool ifModified = false}) async {
    try {
      await compileStylesheet(_options, _graph, source, destination,
          ifModified: ifModified);
      return true;
    } on SassException catch (error, stackTrace) {
      if (!_options.emitErrorCss) _delete(destination);
      _printError(
          error.toString(color: _options.color), getTrace(error) ?? stackTrace);
      exitCode = 65;
      return false;
    } on FileSystemException catch (error, stackTrace) {
      var path = error.path;
      _printError(
          path == null
              ? error.message
              : "Error reading ${p.relative(path)}: ${error.message}.",
          getTrace(error) ?? stackTrace);
      exitCode = 66;
      return false;
    }
  }

  /// Deletes the file at [path] and prints a message about it.
  void _delete(String path) {
    try {
      deleteFile(path);
      var buffer = StringBuffer();
      if (_options.color) buffer.write("\u001b[33m");
      buffer.write("Deleted $path.");
      if (_options.color) buffer.write("\u001b[0m");
      print(buffer);
    } on FileSystemException {
      // If the file doesn't exist, that's fine.
    }
  }

  /// Prints [message] to standard error, with [stackTrace] if [_options.trace]
  /// is set.
  void _printError(String message, StackTrace stackTrace) {
    var buffer = StringBuffer(message);

    if (_options.trace) {
      buffer.writeln();
      buffer.writeln();
      buffer.write(Trace.from(stackTrace).terse.toString().trimRight());
    }

    if (!_options.stopOnError) buffer.writeln();
    printError(buffer);
  }

  /// Listens to `watcher.events` and updates the filesystem accordingly.
  ///
  /// Returns a future that will only complete if an unexpected error occurs.
  Future<void> watch(MultiDirWatcher watcher) async {
    await for (var event in _debounceEvents(watcher.events)) {
      var extension = p.extension(event.path);
      if (extension != '.sass' && extension != '.scss' && extension != '.css') {
        continue;
      }

      switch (event.type) {
        case ChangeType.MODIFY:
          var success = await _handleModify(event.path);
          if (!success && _options.stopOnError) return;
          break;

        case ChangeType.ADD:
          var success = await _handleAdd(event.path);
          if (!success && _options.stopOnError) return;
          break;

        case ChangeType.REMOVE:
          var success = await _handleRemove(event.path);
          if (!success && _options.stopOnError) return;
          break;
      }
    }
  }

  /// Handles a modify event for the stylesheet at [path].
  ///
  /// Returns whether all necessary recompilations succeeded.
  Future<bool> _handleModify(String path) async {
    var url = _canonicalize(path);

    // It's important to access the node ahead-of-time because it's possible
    // that `_graph.reload()` notices the file has been deleted and removes it
    // from the graph.
    var node = _graph.nodes[url];
    if (node == null) return _handleAdd(path);

    _graph.reload(url);
    return await _recompileDownstream([node]);
  }

  /// Handles an add event for the stylesheet at [url].
  ///
  /// Returns whether all necessary recompilations succeeded.
  Future<bool> _handleAdd(String path) async {
    var destination = _destinationFor(path);

    var success = destination == null || await compile(path, destination);
    var downstream = _graph.addCanonical(
        FilesystemImporter('.'), _canonicalize(path), p.toUri(path));
    return await _recompileDownstream(downstream) && success;
  }

  /// Handles a remove event for the stylesheet at [url].
  ///
  /// Returns whether all necessary recompilations succeeded.
  Future<bool> _handleRemove(String path) async {
    var url = _canonicalize(path);

    if (_graph.nodes.containsKey(url)) {
      var destination = _destinationFor(path);
      if (destination != null) _delete(destination);
    }

    var downstream = _graph.remove(FilesystemImporter('.'), url);
    return await _recompileDownstream(downstream);
  }

  /// Returns the canonical URL for the stylesheet path [path].
  Uri _canonicalize(String path) => p.toUri(canonicalize(path));

  /// Combine [WatchEvent]s that happen in quick succession.
  ///
  /// Otherwise, if a file is erased and then rewritten, we can end up reading
  /// the intermediate erased version.
  Stream<WatchEvent> _debounceEvents(Stream<WatchEvent> events) {
    return events.debounceBuffer(Duration(milliseconds: 25)).expand((buffer) {
      var typeForPath = p.PathMap<ChangeType>();
      for (var event in buffer) {
        var oldType = typeForPath[event.path];
        if (oldType == null) {
          typeForPath[event.path] = event.type;
        } else if (event.type == ChangeType.REMOVE) {
          typeForPath[event.path] = ChangeType.REMOVE;
        } else if (oldType != ChangeType.ADD) {
          typeForPath[event.path] = ChangeType.MODIFY;
        }
      }

      return [
        for (var entry in typeForPath.entries)
          // PathMap always has nullable keys
          WatchEvent(entry.value, entry.key!)
      ];
    });
  }

  /// Recompiles [nodes] and everything that transitively imports them, if
  /// necessary.
  ///
  /// Returns whether all recompilations succeeded.
  Future<bool> _recompileDownstream(Iterable<StylesheetNode> nodes) async {
    var seen = <StylesheetNode>{};
    var toRecompile = Queue.of(nodes);

    var allSucceeded = true;
    while (toRecompile.isNotEmpty) {
      var node = toRecompile.removeFirst();
      if (!seen.add(node)) continue;

      var success = await _compileIfEntrypoint(node.canonicalUrl);
      allSucceeded = allSucceeded && success;
      if (!success && _options.stopOnError) return false;

      toRecompile.addAll(node.downstream);
    }
    return allSucceeded;
  }

  /// Compiles the stylesheet at [url] to CSS if it's an entrypoint that's being
  /// watched.
  ///
  /// Returns `false` if compilation failed, `true` otherwise.
  Future<bool> _compileIfEntrypoint(Uri url) async {
    if (url.scheme != 'file') return true;

    var source = p.fromUri(url);
    var destination = _destinationFor(source);
    if (destination == null) return true;

    return await compile(source, destination);
  }

  /// If a Sass file at [source] should be compiled to CSS, returns the path to
  /// the CSS file it should be compiled to.
  ///
  /// Otherwise, returns `null`.
  String? _destinationFor(String source) {
    var destination = _sourcesToDestinations(_options)[source];
    if (destination != null) return destination;
    if (p.basename(source).startsWith('_')) return null;

    for (var entry in _sourceDirectoriesToDestinations(_options).entries) {
      if (!p.isWithin(entry.key, source)) continue;

      var destination = p.join(entry.value,
          p.setExtension(p.relative(source, from: entry.key), '.css'));

      // Don't compile ".css" files to their own locations.
      if (!p.equals(destination, source)) return destination;
    }

    return null;
  }
}

/// Exposes [options.sourcesToDestinations] as a non-nullable map, since stdin
/// inputs and stdout outputs aren't allowed in `--watch` mode.
Map<String, String> _sourcesToDestinations(ExecutableOptions options) =>
    options.sourcesToDestinations.cast<String, String>();

/// Exposes [options.sourcesDirectoriesToDestinations] as a non-nullable map,
/// since stdin inputs and stdout outputs aren't allowed in `--watch` mode.
Map<String, String> _sourceDirectoriesToDestinations(
        ExecutableOptions options) =>
    options.sourceDirectoriesToDestinations.cast<String, String>();
