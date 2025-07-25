library flutter_gpu_shaders;

import 'dart:convert' as convert;
import 'dart:io';

import 'package:native_assets_cli/native_assets_cli.dart';

import 'package:flutter_gpu_shaders/environment.dart';

/// Loads a shader bundle manifest file and builds a shader bundle.
Future<void> _buildShaderBundleJson({
  required Uri packageRoot,
  required Uri inputManifestFilePath,
  required Uri outputBundleFilePath,
}) async {
  /////////////////////////////////////////////////////////////////////////////
  /// 1. Parse the manifest file.
  ///

  final manifest =
      await File(inputManifestFilePath.toFilePath()).readAsString();
  final decodedManifest = convert.json.decode(manifest);
  String reconstitutedManifest = convert.json.encode(decodedManifest);

  //throw Exception(reconstitutedManifest);

  /////////////////////////////////////////////////////////////////////////////
  /// 2. Build the shader bundle.
  ///

  final impellercExec = await findImpellerC();
  final shaderLibPath = impellercExec.resolve('./shader_lib');
  final impellercArgs = [
    '--sl=${outputBundleFilePath.toFilePath()}',
    '--shader-bundle=$reconstitutedManifest',
    '--include=${inputManifestFilePath.resolve('./').toFilePath()}',
    '--include=${shaderLibPath.toFilePath()}',
  ];

  final impellerc = Process.runSync(impellercExec.toFilePath(), impellercArgs,
      workingDirectory: packageRoot.toFilePath());
  if (impellerc.exitCode != 0) {
    throw Exception(
        'Failed to build shader bundle: ${impellerc.stderr}\n${impellerc.stdout}');
  }
}

/// Build a Flutter GPU shader bundle/library from a JSON manifest file.
///
/// The [buildConfig] and [buildOutput] are provided by the build hook system.
///
/// The [manifestFileName] is the path to the JSON manifest file, which is
/// relative to the package root where the build hook resides.
///
/// The [manifestFileName] must end with ".shaderbundle.json".
///
/// The built shader bundle will be written to
/// `build/shaderbundles/[name].shaderbundle`,
/// relative to the package root where the build hook resides.
///
/// Example usage:
///
/// hook/build.dart
/// ```dart
/// void main(List<String> args) async {
///   await build(args, (config, output) async {
///     await buildShaderBundleJson(
///         buildConfig: config,
///         buildOutput: output,
///         manifestFileName: 'my_cool_bundle.shaderbundle.json');
///   });
/// }
/// ```
///
/// my_cool_bundle.shaderbundle.json
/// ```json
/// {
///     "SimpleVertex": {
///         "type": "vertex",
///         "file": "shaders/my_cool_shader.vert"
///     }
/// }
/// ```
///

Future<String> gencontents(BuildConfig config, String filePath) async {
  Uri shaderFilePath = config.packageRoot.resolve(filePath);
  File shaderFile = File(shaderFilePath.path);

  String shaderContents = "";
  await shaderFile.readAsString().then((String contents) async {
    int startOffset = 0, includeOffset = 0;
    while(contents.contains("#include")){
      startOffset = contents.indexOf("#include", startOffset);
      includeOffset = startOffset + 10; // location of include after the space
  
      String includeStr = "", includeSrc = "";
      while(contents[includeOffset] != '\n' && contents[includeOffset] != '\0'){
        if(contents[includeOffset] != '\"' && contents[includeOffset] != '>' && contents[includeOffset] != ';') includeStr += contents[includeOffset];
        includeOffset++;
      }
  
      if(includeStr.substring(includeStr.length - 4) == "glsl"){ // read from file
        includeStr = includeStr.split("/").last.trim().replaceAll("\"", "");
        includeStr = filePath.substring(0, filePath.lastIndexOf('/') + 1) + includeStr;
        File includeFile = File(includeSrc);
        includeSrc = includeFile.readAsStringSync();
      }
  
      contents.replaceRange(startOffset, includeOffset - startOffset, includeSrc);
    }
    return contents;
  });

  return shaderContents;
}

Future<void> parseLine(String lineStr, Uri manifestFilePath, Directory outDir, BuildConfig buildConfig, File manifestFile) async {
  if(lineStr.contains("glsl")){
    int startIdx = lineStr.indexOf("file:") + 9; // starts after "...
    String shaderFilePath = (!Platform.isWindows)? "" : "/";
    while(lineStr[startIdx] != "\n" && startIdx < lineStr.length - 1) {
      if (lineStr[startIdx] != "\"") shaderFilePath = shaderFilePath + lineStr[startIdx];
      startIdx++;
    }
    if(shaderFilePath.isNotEmpty) {
      <String>["%20", " ", "e:"].forEach((entry){ shaderFilePath = shaderFilePath.replaceAll(entry, ''); });
      shaderFilePath = manifestFilePath.path.substring((!Platform.isWindows)? 0 : 1, manifestFile.path.indexOf("lib/")) + shaderFilePath;
      print("Shader file path is $shaderFilePath, subpath is ${shaderFilePath.substring(shaderFilePath.indexOf("lib/"))}");
      await gencontents(buildConfig, shaderFilePath).then((shaderContent) async {
        File shaderOutFile = await File(outDir.path + shaderFilePath.split('/').last).create();
        print("Shader contents are $shaderContent");
        shaderOutFile.writeAsString(shaderContent);
      });
    }
  }
}

Future<void> buildShaderBundleJson(
    {required BuildConfig buildConfig,
    required BuildOutputBuilder buildOutput,
    required String manifestFileName}) async {
  var outDir = Directory.fromUri(buildConfig.packageRoot.resolve('build/shaderbundles/'));
  await outDir.create(recursive: true);

  Uri manifestFilePath = buildConfig.packageRoot.resolve(manifestFileName);
  File manifestFile = File((!Platform.isWindows)? manifestFilePath.path : manifestFilePath.path.substring(1));
  File manifestOutFile = await File(outDir.path + manifestFilePath.path.split('/').last).create();
  Uri manifestOutPath = buildConfig.packageRoot.resolve(manifestOutFile.path);
  print("Manifest file path is ${manifestFile.path}, out path is ${manifestOutFile.path}");

  await manifestFile.readAsString().then((String contents) {
    String manifestOutContents = contents.replaceAll("lib/shaders", "build/shaderbundles");
    manifestOutFile.writeAsString(manifestOutContents);

    contents.split('\n').forEach((lineStr) async {
      await parseLine(lineStr, manifestFilePath, outDir, buildConfig, manifestFile);
    });

    String outputFileName = Uri(path: manifestFileName).pathSegments.last;
    if (!outputFileName.endsWith('.shaderbundle.json')) {
      throw Exception(
          'Shader bundle manifest file names must end with ".shaderbundle.json".');
    }
    if (outputFileName.length <= '.shaderbundle.json'.length) {
      throw Exception(
          'Invalid shader bundle manifest file name: $outputFileName');
    }
    if (outputFileName.endsWith('.json')) {
      outputFileName = outputFileName.substring(0, outputFileName.length - 5);
    }

    // TODO(bdero): Register DataAssets instead of outputting to the project directory once it's possible to do so.
    //final outDir = config.outputDirectory;
    final packageRoot = buildConfig.packageRoot;

    final inFile = packageRoot.resolve(manifestOutPath.path);
    final outFile = outDir.uri.resolve(outputFileName);

    _buildShaderBundleJson(
      packageRoot: packageRoot,
      inputManifestFilePath: inFile,
      outputBundleFilePath: outFile
    );
  });
}
